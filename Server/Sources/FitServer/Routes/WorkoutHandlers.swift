//  `POST /v1/workouts` — начало тренировки (SPEC §7.1, §7.3, §9.8, §20.3, §20.6).
//
//  ── Два момента, а не один ────────────────────────────────────────────────
//
//  §20.3 разводит момент оценки по РОЛИ числа. Состав, порядок и `target_sets`
//  берутся из плана на 12:00 — ровно те, что показала карточка дня, потому что
//  §7.1 запрещает молчаливое изменение между карточкой и нажатием «Начать».
//  `target_rir`, `weight_readiness` и `prescribed_kg` пересчитываются на
//  ФАКТИЧЕСКИЙ момент старта: по 12:00 вечерняя тренировка считала бы утомление
//  на часы старее и занижала веса.
//
//  Делает это `Planner.prescribe` поверх готовой сессии, а не второй
//  `buildSession`: утомление входит в ПОДБОР четырьмя путями, и второй полный
//  вызов сменил бы и состав, и раскладку подходов.
//
//  ── Идемпотентность ───────────────────────────────────────────────────────
//
//  Ключ — `planned_day_id` (§20.3), и держит его схема (частичный индекс
//  `workouts_one_per_planned_day`, миграция `0011`). Повтор отдаёт ту же
//  тренировку и 200; первый старт — 201.
//
//  Собрать состав второй раз нельзя даже теоретически: день с незавершённой
//  тренировкой `classify` объявляет `not_built` с причиной `started` (§7.1), и
//  сессии для него планировщик не отдаёт. Поэтому ветка повтора читает
//  сохранённое, а не строит.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import FitAPI
import FitContent
import FitCore
import PostgresNIO
import Vapor

extension WorkoutRoutes {

    static func start(_ request: Request, database: Database,
                      library: ContentLibrary) async throws -> Response {
        let input = RawInput(request)
        return try await database.withUserTransaction(authorization: input.authorization) { tx in
            // Гейт линковки (§20.5): «Начать» защищает историю тренировок, и
            // правило живёт здесь, а не в кнопке — запросом мимо интерфейса
            // создалась бы ровно та история, ради которой гейт введён. Стоит
            // первым, до разбора тела: анонимному аккаунту отвечать про
            // ошибки запроса незачем. Профиль, инвентарь и генерация недели
            // ему доступны (§20.5): защищается история, а не план.
            try tx.token.requireLinkedAccount()
            // Всё, что ниже, — уже после проверки токена (§20.5).
            let request = try input.decode(StartWorkoutRequest.self)
            let day = try RequestDay.validated(date: request.date, tz: request.tz)
            let plannedDayID = try WeekPlanRoutes.uuid(request.plannedDayID, "planned_day_id")
            let askedEquipment = try request.equipmentProfileID.map {
                try WeekPlanRoutes.uuid($0, "equipment_profile_id")
            }

            // §20.3: повтор после таймаута — это второе нажатие «Начать».
            if let existing = try await Mapping.readWorkout(tx, plannedDayID: plannedDayID) {
                if let askedEquipment,
                   existing.equipmentProfileID != askedEquipment.uuidString.lowercased() {
                    // Не повтор, а просьба пересобрать начатую тренировку на
                    // другом инвентаре. §7.1 запрещает; `workout_id` в
                    // `details`, чтобы клиент доехал до идущей.
                    throw APIError(.dayNotPlanned, details: [
                        "planned_day_id": .string(plannedDayID.uuidString),
                        "workout_id": .string(existing.id),
                        "reason": .string("equipment_profile_changed")
                    ])
                }
                return try WeekPlanRoutes.json(
                    await body(tx, workout: existing, library: library))
            }

            guard let location = try await Mapping.readPlannedDay(tx, id: plannedDayID) else {
                throw APIError(.notFound, details: [
                    "planned_day_id": .string(plannedDayID.uuidString)
                ])
            }
            guard location.day.status == PlannedDayStatus.planned.rawValue else {
                throw APIError(.dayNotPlanned, details: [
                    "planned_day_id": .string(plannedDayID.uuidString),
                    "status": .string(location.day.status)
                ])
            }
            // §7.1 (2026-10-22): начать можно любой день ТЕКУЩЕЙ недели — другой
            // недели нет на ленте, и догон через её границу запрещён.
            guard location.weekStart == Mapping.LocalTime.mondayOfWeek(day.date) else {
                throw APIError(.dayNotPlanned, details: [
                    "planned_day_id": .string(plannedDayID.uuidString),
                    "reason": .string("other_week")
                ])
            }
            // Одна идущая тренировка за раз (§7.1): две перемешали бы подходы во
            // времени. `workout_id` — чтобы клиент довёл до идущей.
            if let running = try await Mapping.readRunningWorkout(tx) {
                throw APIError(.dayNotPlanned, details: [
                    "planned_day_id": .string(plannedDayID.uuidString),
                    "workout_id": .string(running.id),
                    "reason": .string("workout_running")
                ])
            }

            // План недели целиком: `S_эфф` считается по неделе (§7.3), и день в
            // отрыве от неё собирается не тем объёмом. День, который начинают,
            // ставится на сегодня (§7.1): тренировка идёт в день старта, и
            // утомление, check-in, оверрайд, цикл и «прошедший ли» берутся от
            // него. Сегодняшний день и сам на сегодня — для него это тождество.
            let inputs = try await WeekPlanRoutes.inputs(tx, on: day)
            let days = try await Mapping.readPlannedDays(tx, weekPlanID: location.weekPlanID)
            let context = Planner.startingToday(WeekPlanRoutes.context(
                inputs, weekStart: location.weekStart, today: day.date, days: days,
                isDeload: location.isDeload, library: library,
                userSeed: Mapping.userSeed(canonicalUUID: tx.token.subject)), dayID: location.day.id)
            let plan = Planner.planRemainingDays(context)

            guard let outcome = plan.days[location.day.id] else { throw APIError(.internal) }
            if outcome.kind == .generatorDisabled {
                throw APIError(.generatorDisabled)
            }
            guard let session = outcome.session else {
                // Растяжка, дыра в разметке, прошедший день — начинать нечего, и
                // причина у клиента та же: показывать не экран старта.
                throw APIError(.dayNotPlanned, details: [
                    "planned_day_id": .string(plannedDayID.uuidString),
                    "kind": .string(ReasonDTO.code(for: outcome.kind))
                ])
            }

            // Тот же день из контекста — уже на дате старта: по ней считаются
            // готовность, цикл и веса момента старта.
            guard let plannedDay = context.week.first(where: { $0.id == location.day.id })
            else { throw APIError(.internal) }

            // Инвентарь момента (§20.3). Разрешённый `id` пишется в строку, а не
            // `null`: иначе тренировка не помнит, на чём шла.
            let equipmentID: UUID?
            let equipment: Mapping.EquipmentSlice
            if let askedEquipment {
                equipmentID = askedEquipment
                equipment = try await Mapping.readEquipment(tx, id: askedEquipment)
            } else {
                equipmentID = try await Mapping.defaultEquipmentProfileID(tx)
                equipment = inputs.equipment
            }

            let prescribed = Planner.prescribe(session, on: Mapping.prescriptionInput(
                day: plannedDay, startMoment: day.now, library: library.candidates,
                profile: inputs.complete, equipment: equipment, safety: inputs.safety,
                cycle: inputs.cycle, checkin: inputs.checkin, override: inputs.override,
                fatigue: inputs.fatigue, journal: inputs.journal))
            // `nil` значит «сессия собрана не на этом входе». Молча отдать
            // сессию как есть нельзя: это веса по 12:00 там, где контракт
            // обещает веса момента старта, и ни один тест этого не поймал бы.
            guard let prescribed else { throw APIError(.internal) }

            let cycleState = Cycle.state(events: inputs.cycle.events, profile: inputs.cycle.profile,
                                         responseProfiles: inputs.cycle.responseProfiles,
                                         asOf: plannedDay.date)
            let readiness = Readiness.value(cycleState: cycleState, override: inputs.override,
                                            checkin: inputs.checkin)
            let flags = try await Mapping.readCalibrationFlags(tx)

            guard let userID = UUID(uuidString: tx.token.subject) else { throw APIError(.internal) }
            let workoutID = try await Mapping.insertWorkout(
                tx, userID: userID, plannedDayID: plannedDayID, sessionKind: plannedDay.kind,
                accent: plannedDay.accent, equipmentProfileID: equipmentID, readiness: readiness,
                // Фаза и уверенность — СЫРЫЕ, без порога называемости §11.3:
                // колонка под разбор «почему мне это дали», то есть хранит то,
                // чем пользовался алгоритм.
                cyclePhase: cycleState.phase, cycleConfidence: cycleState.cycleConfidence,
                // Флаг тренировки — баннер §9.8: хотя бы одно упражнение в
                // калибровке. В расчёт он не идёт, фильтрует флаг УПРАЖНЕНИЯ.
                isCalibration: prescribed.exercises.contains { flags[$0.slug] ?? true })
            _ = try await Mapping.insertWorkoutExercises(
                tx, workoutID: workoutID, exercises: prescribed.exercises, calibration: flags)
            // Диапазоны — из `PrescribedExercise`, то есть из того же вызова
            // `repRange`, что дал `target_rep_*` и диапазон дерева (§20.6).
            try await Mapping.writeSessionRepRanges(
                tx, userID: userID, ranges: Mapping.repRangeUpdates(for: prescribed))

            guard let stored = try await Mapping.readWorkout(tx, id: workoutID) else {
                throw APIError(.internal)
            }
            return try WeekPlanRoutes.json(
                await body(tx, workout: stored, library: library),
                status: .created)
        }
    }

    // MARK: - GET /v1/workouts/{id}

    /// Тренировка целиком (§20.3): состав, подходы и дерево каждого упражнения.
    ///
    /// Путь читающий и ничего не пишет — ни строк, ни снимка плана. Тело то же,
    /// что у старта, и собирается тем же `body`: два источника одного
    /// `WorkoutDTO` разъехались бы не падением, а полем.
    ///
    /// **`date` и `tz` он не принимает, и это не пропуск.** §20.3 не даёт их
    /// этому пути по тому же доводу, по которому их нет у `PATCH /v1/profile`:
    /// день здесь не участвует ни в одной величине. Настоящие моменты
    /// (`started_at`, `completed_at`) едут в UTC и от зоны не зависят, а дерево
    /// §20.9 выводится из журнала по индексам подходов, а не по датам.
    ///
    /// **Дерево у начатого упражнения непустое**, и это ровно то, что §20.9
    /// называет вторым потребителем вывода корня из журнала: «То же самое верно
    /// для `GET /v1/workouts/{id}`, если упражнение начато». Считается он здесь
    /// тем же `Mapping.treeRoot`, что и в `POST …/sets`, — одной реализацией на
    /// два пути, иначе один экран показывал бы одно, а другой другое.
    static func show(_ request: Request, database: Database,
                     library: ContentLibrary) async throws -> Response {
        let input = RawInput(request)
        let rawID = request.parameters.get("id")
        return try await database.withUserTransaction(authorization: input.authorization) { tx in
            let id = try WeekPlanRoutes.uuid(rawID, "id")
            // RLS §3.2 отдаёт только свои строки, поэтому чужая тренировка здесь
            // не «запрещена», а не существует — 404, а не 403.
            guard let workout = try await Mapping.readWorkout(tx, id: id) else {
                throw APIError(.notFound, details: ["id": .string(id.uuidString)])
            }
            return try WeekPlanRoutes.json(await body(tx, workout: workout, library: library))
        }
    }

    /// Отказ RLS на строке, которую политика не показывает: `42501` С признаком
    /// политики в сообщении. Один код без сообщения не годится — тот же `42501`
    /// значит «permission denied» у роли без прав, то есть поломку среды (20k),
    /// и выдавать её за 404 нельзя.
    static func isForeignRow(_ error: PSQLError) -> Bool {
        error.serverInfo?[.sqlState] == "42501"
            && (error.serverInfo?[.message] ?? "").contains("row-level security policy")
    }

    // MARK: - POST /v1/workouts/{id}/exercises/{we_id}/sets

    /// Тело запроса до полного разбора — только вопрос «есть ли `id`».
    ///
    /// §20.6 и тест 20e требуют отдельного кода на его отсутствие:
    /// сгенерированный сервером ключ снял бы саму возможность отличить ретрай
    /// от нового подхода, поэтому «без `id`» — это не «поле не прошло схему», а
    /// своё различимое поведение клиента. Полный разбор `LogSetRequest` на
    /// отсутствующем `id` дал бы `validation_failed`, то есть ответ не о том.
    private struct SetIdentityProbe: Decodable {
        let id: String?
    }

    /// Логирование подхода и новое дерево §20.9 в ответ.
    ///
    /// Порядок здесь несущий и весь продиктован §20.6:
    ///
    ///   1. сверить тренировку и упражнение — `we_id` приходит из пути отдельно
    ///      от `id`, и без сверки подход лёг бы в чужую тренировку ТОЙ ЖЕ
    ///      пользовательницы, чего RLS не ловит;
    ///   2. проверить иммутабельность завершённого подхода (§4.3, тест 20f) —
    ///      ДО записи, иначе отказ не отказ;
    ///   3. upsert по клиентскому `id` (тест 20e);
    ///   4. пересчитать `exercise_states` — на каждом подходе, потому что их
    ///      читает следующий же запрос;
    ///   5. **`muscle_fatigue` НЕ трогать** — она считается один раз, на
    ///      `/finish` (§20.6). В пределах тренировки её не читает никто, а
    ///      пересчёт на каждом подходе положил бы свёртку §8.1 на горячий путь
    ///      §13.2 без единого читателя.
    static func logSet(_ request: Request, database: Database,
                       library: ContentLibrary) async throws -> Response {
        let input = RawInput(request)
        let rawWorkout = request.parameters.get("id")
        let rawExercise = request.parameters.get("we_id")
        return try await database.withUserTransaction(authorization: input.authorization) { tx in
            let workoutID = try WeekPlanRoutes.uuid(rawWorkout, "id")
            let exerciseID = try WeekPlanRoutes.uuid(rawExercise, "we_id")

            // Проба отдельно от разбора: негодный JSON обязан дать
            // `validation_failed`, а не `set_id_required`, поэтому бросает
            // только явно отсутствующий ключ при разобранном теле.
            if let probe = try? input.decode(SetIdentityProbe.self), probe.id == nil {
                throw APIError(.setIDRequired)
            }
            var body = try input.decode(LogSetRequest.self)
            let day = try RequestDay.validated(date: body.date, tz: body.tz)
            let setID = try WeekPlanRoutes.uuid(body.id, "id")

            guard let workout = try await Mapping.readWorkout(tx, id: workoutID) else {
                throw APIError(.workoutNotStarted, details: ["id": .string(workoutID.uuidString)])
            }
            guard workout.finishedAt == nil else {
                throw APIError(.workoutFinished, details: ["id": .string(workoutID.uuidString)])
            }
            guard let location = try await Mapping.readWorkoutExercise(tx, id: exerciseID),
                  location.workoutID == workout.id
            else { throw APIError(.notFound, details: ["we_id": .string(exerciseID.uuidString)]) }
            let exercise = location.row

            let profile = try await Mapping.readProfile(tx)
            guard let complete = profile.complete else {
                throw APIError(.profileIncomplete, details: [
                    "missing": .string(Mapping.missingProfileFields(profile).joined(separator: ","))
                ])
            }
            // Инвентарь ТРЕНИРОВКИ: лестница принадлежит тому, на чём она идёт.
            let equipment = try await Mapping.readEquipment(
                tx, id: workout.equipmentProfileID.flatMap(UUID.init(uuidString:)))
            let candidate = library.candidates.first { $0.slug == exercise.slug }
            let ladder = candidate.map {
                WeightLadder.build(loadType: $0.loadType, profile: equipment.profile)
            } ?? .none

            // Проверки и округление — ДО сверки с записанным: ретрай присылает то
            // же число, и сравниваться оно обязано в той же форме, в какой легло.
            try Self.validateSet(body, targetSets: exercise.targetSets, weighted: ladder != .none)
            // Вес — числом, сервер кладёт ближайшую ступень (§20.3, §19.2 п.23).
            body.actualKg = body.actualKg.map { ladder.roundToAchievable($0, direction: .nearest) }

            if let stored = try await Mapping.inspectSet(tx, id: setID, against: body) {
                guard stored.workoutExerciseID == exercise.id else {
                    // Тот же `id` на другом упражнении — не ретрай, а коллизия
                    // ключа. Молча перенести подход нельзя: журнал обоих
                    // упражнений стал бы неверным.
                    throw APIError(.validationFailed, details: [
                        "field": .string("id"),
                        "reason": .string("belongs_to_another_exercise")
                    ])
                }
                // Ретрай с ТЕМИ ЖЕ значениями отказом не является (§20.6):
                // иначе клиент, потерявший ответ, не доедет никогда.
                if stored.isCompleted, stored.differs {
                    throw APIError(.setImmutable, details: ["id": .string(setID.uuidString)])
                }
            }

            // Номер подхода уникален в паре (упражнение, слаг) (§20.3). Чтение до
            // записи даёт ответ с `id` занявшего; уникальный индекс — последняя
            // линия против гонки двух запросов, и его нарушение — тот же код.
            if let owner = try await Mapping.setIndexOwner(
                tx, workoutExerciseID: exerciseID, slug: exercise.slug, setIndex: body.setIndex),
               owner != setID.uuidString.lowercased() {
                throw APIError(.setIndexTaken, details: ["set_id": .string(owner)])
            }

            // §20.6: суставы кладёт сервер, из `joint_stress` упражнения и на
            // момент события — переразметка контента уже случившееся не меняет.
            // Второй реализации «максимума» не заводится: правило §8.4 п.5
            // живёт в `Recovery.painJoints`.
            let joints = body.painFlag
                ? Recovery.painJoints(from: candidate?.jointStress ?? [:])
                    .map(\.rawValue).sorted()
                : []

            // `prescribed_reps` — верх ДЕЙСТВУЮЩЕГО диапазона, и берётся он из
            // `workout_exercises.target_rep_max` (§20.3), а не вторым вызовом
            // `repRange`: тот дал бы диапазон на состояние ПОСЛЕ подхода.
            do {
                try await Mapping.upsertSet(tx, id: setID, workoutExerciseID: exerciseID, body: body,
                                            prescribedReps: exercise.targetRepMax, painJoints: joints,
                                            timeZone: day.timeZone)
            } catch let error as PSQLError where error.serverInfo?[.sqlState] == "23505"
                        && (error.serverInfo?[.constraintName] ?? "") == "sets_index_per_exercise" {
                throw APIError(.setIndexTaken, details: ["set_index": .int(body.setIndex)])
            } catch let error as PSQLError where Self.isForeignRow(error) {
                // `id` занят подходом другого пользователя (§20.6): RLS строку не
                // показывает, и upsert на неё натыкается. Для запроса её нет — 404,
                // как на любую несуществующую строку; особый код выдал бы, что
                // чужой подход с таким `id` есть.
                throw APIError(.notFound, details: ["field": .string("id")])
            }

            guard let userID = UUID(uuidString: tx.token.subject) else { throw APIError(.internal) }
            let journal = try await Mapping.readSets(tx, since: nil, timeZone: day.timeZone)
            // Свёртка та же, что у планировщика: `Planner.exerciseStates` зовёт
            // `rebuildStates` с диапазоном от цели и лестницей инвентаря.
            // Своей свёртки слой не делает (§20.6).
            let states = Planner.exerciseStates(history: Mapping.exerciseHistory(from: journal),
                                                library: library.candidates, goal: complete.goal,
                                                equipment: equipment.profile)
            if let state = states[exercise.slug] {
                guard try await Mapping.writeExerciseState(tx, userID: userID,
                                                           slug: exercise.slug, state: state)
                else {
                    // Строку завёл старт тренировки; её отсутствие означает, что
                    // состав и журнал разошлись, и молча пройти мимо нельзя.
                    throw APIError(.internal)
                }
            }
            // Состояния может не быть законно: журнал, состоящий из одних
            // пропусков, свёртка не читает вовсе (§9.3), и сворачивать нечего.

            let after = try await Mapping.readWorkoutSets(tx, workoutID: workoutID)
            let root = Mapping.treeRoot(
                // Подходы прежнего упражнения (до замены, §20.3) корень не строят.
                sets: (after.journal[exercise.id] ?? []).filter { $0.exerciseSlug == exercise.slug },
                startWeightKg: exercise.prescribedKg,
                range: exercise.range, isCalibration: exercise.isCalibration, ladder: ladder)
            let remaining = max(0, exercise.targetSets - (after.body[exercise.id]?.count ?? 0))
            let tree = root.terminated
                ? DecisionTree.terminated
                : DecisionTree.build(
                    weightKg: root.weightKg, remainingSets: remaining, range: exercise.range,
                    isCalibration: exercise.isCalibration,
                    previousWasFailed: root.previousWasFailed,
                    calibrationIncreasesUsed: root.calibrationIncreasesUsed, ladder: ladder)
            // Только дерево, без готового следующего подхода (§20.3): клиент уже
            // применил ветку, и второй источник того же числа разошёлся бы с
            // показанным после того, как она его увидела.
            guard let recorded = after.body[exercise.id]?.first(where: { $0.id == setID.uuidString.lowercased() })
            else { throw APIError(.internal) }
            return try WeekPlanRoutes.json(LogSetResponseDTO(decisionTree: tree, set: recorded))
        }
    }

    /// Диапазоны тела подхода (§20.3, миграция 0016): тот же check стоит в
    /// схеме, но сообщение с полем даёт сервер, и до записи.
    static func validateSet(_ body: LogSetRequest, targetSets: Int, weighted: Bool) throws {
        func field(_ name: String) -> APIError { APIError(.validationFailed, details: ["field": .string(name)]) }
        guard (1...(targetSets + 2)).contains(body.setIndex) else { throw field("set_index") }
        if let reps = body.actualReps, !(0...100).contains(reps) { throw field("actual_reps") }
        if let kg = body.actualKg, !(0...500).contains(kg) { throw field("actual_kg") }
        if let kg = body.prescribedKg, !(0...500).contains(kg) { throw field("prescribed_kg") }
        // Весовой подход без веса не принимается (§9.8): подменять его нулём
        // значило записать нижнюю ступень как сделанный вес. Пропуск веса не
        // несёт законно, а о боли сообщают сразу — требовать перед этим вес
        // нельзя (§8.4).
        if weighted, !body.skipped, !body.painFlag, body.actualKg == nil { throw field("actual_kg") }
    }
}
