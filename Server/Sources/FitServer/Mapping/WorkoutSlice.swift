//  Тренировка на проводе: строки `workouts`, `workout_exercises` и `sets`
//  (SPEC §3.1, §20.3, §20.6).
//
//  Этот срез отличается от остальных в `Mapping/` направлением. Прочие ведут
//  схему §3.1 в типы FitCore — здесь же читается ТЕЛО ОТВЕТА: `WorkoutDTO`
//  собирается из тех же трёх таблиц, но ни одного типа ядра в нём нет. Так же
//  устроен `readProfileBody`, и по той же причине: вопрос другой. Планировщику
//  нужен вход, клиенту — тренировка, и общий `select` на оба заставил бы один
//  из них таскать колонки, которые он не читает.
//
//  ── Моменты отдаются в UTC и с `Z` ────────────────────────────────────────
//
//  `started_at`, `finished_at` и `sets.completed_at` — НАСТОЯЩИЕ моменты
//  (§20.7), то есть `timestamptz`, и в шкалу FitCore они не переводятся.
//  Наружу они едут в UTC: зона клиента к ним не применяется, потому что момент
//  от зоны не зависит, а два ответа на один и тот же запрос из разных поясов
//  обязаны быть побайтово одинаковыми. Формат складывает Postgres — не ради
//  экономии, а чтобы формат не зависел от локали процесса.
//
//  ── Чего здесь нет ────────────────────────────────────────────────────────
//
//  Дерева §20.9. Оно строится от журнала подходов (`Mapping.treeRoot`) и от
//  лестницы текущего инвентаря, то есть требует библиотеки и профиля
//  инвентаря — входов, которых у чтения строк нет и быть не должно. Собирает
//  его вызывающая сторона, поверх этих рядов.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import FitAPI
import FitCore

extension Mapping {

    /// Формат настоящих моментов наружу: UTC, ISO 8601, с `Z`.
    static let instantFormat = "YYYY-MM-DD\"T\"HH24:MI:SS\"Z\""

    public struct WorkoutRow: Sendable, Equatable {
        public var id: String
        public var plannedDayID: String?
        public var sessionKind: String
        public var accentMuscle: String?
        public var startedAt: String
        public var finishedAt: String?
        public var readiness: Double
        public var cyclePhase: String?
        public var cycleConfidence: Double?
        public var isCalibration: Bool
        public var equipmentProfileID: String?
    }

    public struct WorkoutExerciseRow: Sendable, Equatable {
        public var id: String
        public var slug: String
        public var orderIndex: Int
        public var targetSets: Int
        public var targetRepMin: Int
        public var targetRepMax: Int
        public var targetRIR: Int
        public var prescribedKg: Double?
        public var weightReadiness: Double
        public var isCalibration: Bool
        public var substitutedFrom: String?
        public var substitutionReason: String?

        /// Диапазон, с которым упражнение было предписано. Дерево §20.9
        /// строится по нему, а не по свежему вызову `Planner.repRange`: §20.15
        /// (20c) требует, чтобы границы дерева совпадали с
        /// `workout_exercises.target_rep_*`, и единственный способ этого
        /// добиться — читать их, а не считать заново.
        public var range: ClosedRange<Int> { targetRepMin...targetRepMax }
    }

    // MARK: - Чтение

    /// Тренировка по `id`.
    public static func readWorkout(_ tx: UserTransaction, id: UUID) async throws -> WorkoutRow? {
        try await readWorkout(tx, column: "id", equals: id)
    }

    /// Тренировка по `planned_day_id` — ключ идемпотентности старта (§20.3):
    /// повтор `POST /v1/workouts` приходит с днём, а `id` клиент не знает.
    public static func readWorkout(_ tx: UserTransaction,
                                   plannedDayID: UUID) async throws -> WorkoutRow? {
        try await readWorkout(tx, column: "planned_day_id", equals: plannedDayID)
    }

    /// Общая реализация двух чтений выше.
    ///
    /// Колонка подставляется в SQL как есть, и это безопасно по построению:
    /// значений у неё ровно два, оба записаны строками выше, и из запроса сюда
    /// не приходит ничего.
    ///
    /// Одним запросом с двумя необязательными ключами (`$1 is null or id = $1`)
    /// это сначала и было — и падало на `42P18`: у `NULL`-параметра Postgres тип
    /// не выводит, а запрос, собранный «на оба вопроса сразу», и не обязан его
    /// подсказывать. Два вопроса — два запроса.
    ///
    /// Мягко удалённые (§4.3) не отдаются ни по одному ключу: для клиента их
    /// нет, и частичный индекс `workouts_one_per_planned_day` устроен так же.
    private static func readWorkout(_ tx: UserTransaction, column: String,
                                    equals key: UUID) async throws -> WorkoutRow? {
        let rows = try await tx.query("""
            select id::text, planned_day_id::text, session_kind, accent_muscle,
                   to_char(started_at at time zone 'UTC', \(instantFormat)),
                   to_char(finished_at at time zone 'UTC', \(instantFormat)),
                   readiness::float8, cycle_phase, cycle_confidence::float8,
                   is_calibration, equipment_profile_id::text
              from workouts
             where deleted_at is null and \(unescaped: column) = \(key)
             limit 1
            """)
        for try await row in rows {
            let (id, dayID, kind, accent, started, finished, readiness, phase, confidence,
                 calibration, equipment) =
                try row.decode((String, String?, String, String?, String, String?, Double,
                                String?, Double?, Bool, String?).self)
            return WorkoutRow(id: id, plannedDayID: dayID, sessionKind: kind, accentMuscle: accent,
                              startedAt: started, finishedAt: finished, readiness: readiness,
                              cyclePhase: phase, cycleConfidence: confidence,
                              isCalibration: calibration, equipmentProfileID: equipment)
        }
        return nil
    }

    /// Состав тренировки, по `order_index`.
    public static func readWorkoutExercises(_ tx: UserTransaction,
                                            workoutID: UUID) async throws -> [WorkoutExerciseRow] {
        var result: [WorkoutExerciseRow] = []
        let rows = try await tx.query("""
            select id::text, exercise_slug, order_index, target_sets, target_rep_min,
                   target_rep_max, target_rir, prescribed_kg::float8, weight_readiness::float8,
                   is_calibration, substituted_from, substitution_reason
              from workout_exercises
             where workout_id = \(workoutID)
             order by order_index
            """)
        for try await row in rows {
            let (id, slug, order, sets, repMin, repMax, rir, kg, readiness, calibration,
                 from, reason) =
                try row.decode((String, String, Int, Int, Int, Int, Int, Double?, Double, Bool,
                                String?, String?).self)
            result.append(WorkoutExerciseRow(
                id: id, slug: slug, orderIndex: order, targetSets: sets, targetRepMin: repMin,
                targetRepMax: repMax, targetRIR: rir, prescribedKg: kg, weightReadiness: readiness,
                isCalibration: calibration, substitutedFrom: from, substitutionReason: reason))
        }
        return result
    }

    /// Подходы тренировки в ДВУХ проекциях одного `select`.
    ///
    /// `body` — готовые `SetDTO` тела ответа. `journal` — те же строки как
    /// `SetRow`, то есть вход `Mapping.treeRoot` (§20.9).
    ///
    /// Два чтения вместо одного завели бы два источника одной строки внутри
    /// одной транзакции — ровно тот класс ошибки, от которого §20.4 требует
    /// согласованного среза. Одна выборка, два правила разбора: тот же приём,
    /// которым `readSets` кормит четверых потребителей сразу (§20.6).
    ///
    /// **`performedOn` здесь считается в UTC, и зона не принимается нарочно.**
    /// Единственный потребитель журнальной проекции — `Mapping.treeRoot`
    /// (§20.9), и он читает шесть полей: `set_index`, фидбэк, повторы,
    /// фактический вес, пропуск и флаг боли. Даты среди них нет — порядок он
    /// берёт по индексу подхода, а не по дню.
    ///
    /// Параметр зоны тут был и снят: `GET /v1/workouts/{id}` его взять негде —
    /// §20.3 намеренно не даёт этому пути `date`/`tz`, по тому же доводу, по
    /// которому их нет у `PATCH /v1/profile` («требовать пару там, где день не
    /// участвует, значило бы завести поле, ошибку в котором ничем не
    /// обнаружить»). Оставленный параметр заставлял бы один путь передавать
    /// зону запроса, а другой — UTC, то есть делал бы поле верным на одном
    /// пути и неверным на другом. Единообразный UTC честнее.
    ///
    /// Если дата этой проекции однажды понадобится — её нельзя доставать
    /// отсюда: зону обязан дать запрос, а функция, которая это уже делает, есть
    /// и называется `readSets` (§20.6).
    public static func readWorkoutSets(
        _ tx: UserTransaction, workoutID: UUID
    ) async throws -> (body: [String: [SetDTO]], journal: [String: [SetRow]]) {
        var body: [String: [SetDTO]] = [:]
        var journal: [String: [SetRow]] = [:]
        let rows = try await tx.query("""
            select s.workout_exercise_id::text, s.id::text, s.set_index,
                   s.prescribed_kg::float8, s.prescribed_reps, s.actual_kg::float8,
                   s.actual_reps, s.feedback, s.pain_flag, s.pain_joints, s.rest_seconds,
                   to_char(s.completed_at at time zone 'UTC', \(instantFormat)), s.skipped,
                   s.exercise_slug, s.is_calibration, s.weight_readiness::float8,
                   to_char((w.started_at at time zone 'UTC')::date, 'YYYY-MM-DD')
              from sets s
              join workout_exercises we on we.id = s.workout_exercise_id
              join workouts w on w.id = we.workout_id
             where we.workout_id = \(workoutID)
             order by s.set_index
            """)
        for try await row in rows {
            let (weID, id, index, prescribedKg, prescribedReps, actualKg, actualReps, feedback,
                 painFlag, joints, rest, completed, skipped, slug, calibration, readiness, day) =
                try row.decode((String, String, Int, Double?, Int, Double?, Int?, String?, Bool,
                                [String], Int?, String?, Bool, String, Bool, Double, String).self)
            body[weID, default: []].append(SetDTO(
                id: id, exerciseSlug: slug, setIndex: index, prescribedKg: prescribedKg, prescribedReps: prescribedReps,
                actualKg: actualKg, actualReps: actualReps,
                feedback: feedback.flatMap(Feedback.init(rawValue:)),
                painFlag: painFlag, painJoints: joints.compactMap(Joint.init(rawValue:)),
                restSeconds: rest, completedAt: completed, skipped: skipped))
            journal[weID, default: []].append(SetRow(
                exerciseSlug: slug, setIndex: index, prescribedKg: prescribedKg,
                actualKg: actualKg, actualReps: actualReps, feedback: feedback, skipped: skipped,
                painFlag: painFlag, isCalibration: calibration, weightReadiness: readiness,
                performedOn: try self.day(day, column: "workouts.started_at")))
        }
        return (body, journal)
    }

    /// `id` профиля инвентаря по умолчанию.
    ///
    /// `POST /v1/workouts` без `equipment_profile_id` берёт умолчание (§20.3),
    /// и в `workouts.equipment_profile_id` ложится РАЗРЕШЁННЫЙ id, а не `null`.
    /// Иначе тренировка не помнит, на каком инвентаре шла: умолчание аккаунта
    /// сменится, и дерево §20.9 у старой тренировки перестроится на чужой
    /// лестнице — молча и задним числом.
    public static func defaultEquipmentProfileID(_ tx: UserTransaction) async throws -> UUID? {
        let rows = try await tx.query("""
            select id from equipment_profiles where is_default order by id limit 1
            """)
        for try await row in rows { return try row.decode(UUID.self) }
        return nil
    }

    /// Одна строка `workout_exercises` вместе с тренировкой, которой она
    /// принадлежит.
    ///
    /// `workoutID` возвращается не для удобства: `we_id` приходит из пути
    /// отдельно от `id` тренировки, и без сверки подход лёг бы в упражнение
    /// ЧУЖОЙ тренировки той же пользовательницы — RLS этого не ловит, строки обе
    /// её.
    public struct WorkoutExerciseLocation: Sendable, Equatable {
        public var row: WorkoutExerciseRow
        public var workoutID: String
    }

    public static func readWorkoutExercise(_ tx: UserTransaction,
                                           id: UUID) async throws -> WorkoutExerciseLocation? {
        let rows = try await tx.query("""
            select id::text, exercise_slug, order_index, target_sets, target_rep_min,
                   target_rep_max, target_rir, prescribed_kg::float8, weight_readiness::float8,
                   is_calibration, substituted_from, substitution_reason, workout_id::text
              from workout_exercises
             where id = \(id)
            """)
        for try await row in rows {
            let (rowID, slug, order, sets, repMin, repMax, rir, kg, readiness, calibration,
                 from, reason, workoutID) =
                try row.decode((String, String, Int, Int, Int, Int, Int, Double?, Double, Bool,
                                String?, String?, String).self)
            return WorkoutExerciseLocation(
                row: WorkoutExerciseRow(
                    id: rowID, slug: slug, orderIndex: order, targetSets: sets,
                    targetRepMin: repMin, targetRepMax: repMax, targetRIR: rir, prescribedKg: kg,
                    weightReadiness: readiness, isCalibration: calibration,
                    substitutedFrom: from, substitutionReason: reason),
                workoutID: workoutID)
        }
        return nil
    }

    // MARK: - Иммутабельность подхода (§4.3, тест 20f)

    /// Что известно про уже лежащую строку `sets` с этим `id`.
    public struct StoredSet: Sendable, Equatable {
        /// Чьё это упражнение — сверяется с тем, что назвал путь.
        public var workoutExerciseID: String
        /// `completed_at` непуст, то есть подход завершён (§4.3).
        public var isCompleted: Bool
        /// Присланное отличается от лежащего хотя бы одним полем клиента.
        public var differs: Bool
    }

    /// Строка по `id` вместе с ответом «отличается ли она от присланного».
    ///
    /// **Сравнение делает Postgres, а не Swift**, и это не оптимизация.
    /// `completed_at` приезжает строкой ISO 8601 с произвольным смещением, а
    /// лежит `timestamptz`; сравнение строк объявило бы идемпотентный ретрай
    /// (§20.6, тест 20e) ИЗМЕНЕНИЕМ, если клиент повторил тот же момент в другой
    /// зоне, — и 20f отказал бы там, где отказывать нельзя. `is distinct from`
    /// по колонке сравнивает моменты и масштабы `numeric` по значению.
    ///
    /// `prescribed_reps` и `pain_joints` в сравнение не входят: их пишет сервер
    /// (§20.6), клиент их не присылает, и расхождение в них означало бы, что
    /// сервер посчитал иначе, а не что подход изменили.
    public static func inspectSet(_ tx: UserTransaction, id: UUID,
                                  against body: LogSetRequest) async throws -> StoredSet? {
        let rows = try await tx.query("""
            select workout_exercise_id::text, completed_at is not null,
                   (set_index, prescribed_kg, actual_kg, actual_reps, feedback, pain_flag,
                    rest_seconds, completed_at, skipped)
                     is distinct from
                   (\(body.setIndex), \(body.prescribedKg)::numeric(6,2),
                    \(body.actualKg)::numeric(6,2), \(body.actualReps),
                    \(body.feedback?.rawValue), \(body.painFlag), \(body.restSeconds),
                    \(body.completedAt)::timestamptz, \(body.skipped))
              from sets
             where id = \(id)
            """)
        for try await row in rows {
            let (exerciseID, completed, differs) = try row.decode((String, Bool, Bool).self)
            return StoredSet(workoutExerciseID: exerciseID, isCompleted: completed,
                             differs: differs)
        }
        return nil
    }

    // MARK: - День плана по идентификатору

    /// Строка `planned_days` вместе с неделей, которой она принадлежит.
    ///
    /// Нужна `POST /v1/workouts`: тело называет `planned_day_id`, а
    /// `planRemainingDays` требует ВСЮ неделю — и `week_start`, и признак
    /// разгрузки, и остальные дни (знаменатель `S_эфф` считается по неделе,
    /// §7.3). Одним join'ом, а не тремя чтениями: срез обязан быть
    /// согласованным (§20.4).
    public struct PlannedDayLocation: Sendable, Equatable {
        public var day: PlannedDayRow
        public var weekPlanID: UUID
        public var weekStart: CalendarDay
        public var isDeload: Bool
    }

    public static func readPlannedDay(_ tx: UserTransaction,
                                      id: UUID) async throws -> PlannedDayLocation? {
        let rows = try await tx.query("""
            select pd.id::text, to_char(pd.planned_date, 'YYYY-MM-DD'), pd.session_kind,
                   pd.accent_muscle, pd.status,
                   wp.id, to_char(wp.week_start, 'YYYY-MM-DD'), wp.is_deload
              from planned_days pd
              join week_plans wp on wp.id = pd.week_plan_id
             where pd.id = \(id)
            """)
        for try await row in rows {
            let (dayID, date, kind, accent, status, planID, weekStart, deload) =
                try row.decode((String, String, String, String?, String, UUID, String, Bool).self)
            return PlannedDayLocation(
                day: PlannedDayRow(id: dayID, date: try day(date, column: "planned_days.planned_date"),
                                   sessionKind: kind, accentMuscle: accent, status: status),
                weekPlanID: planID,
                weekStart: try day(weekStart, column: "week_plans.week_start"),
                isDeload: deload)
        }
        return nil
    }
}
