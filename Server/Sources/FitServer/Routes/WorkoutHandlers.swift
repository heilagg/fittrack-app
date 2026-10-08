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
import Vapor

extension WorkoutRoutes {

    static func start(_ request: Request, database: Database,
                      library: ContentLibrary) async throws -> Response {
        let input = RawInput(request)
        return try await database.withUserTransaction(authorization: input.authorization) { tx in
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

            // План недели целиком: `S_эфф` считается по неделе (§7.3), и день в
            // отрыве от неё собирается не тем объёмом.
            let inputs = try await WeekPlanRoutes.inputs(tx, on: day)
            let days = try await Mapping.readPlannedDays(tx, weekPlanID: location.weekPlanID)
            let context = WeekPlanRoutes.context(
                inputs, weekStart: location.weekStart, today: day.date, days: days,
                isDeload: location.isDeload, library: library,
                userSeed: Mapping.userSeed(canonicalUUID: tx.token.subject))
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

            guard let plannedDay = Mapping.plannedDays(from: days, vectors: library.vectors)
                .first(where: { $0.id == location.day.id })
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
}
