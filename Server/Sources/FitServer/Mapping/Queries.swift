//  Чтение срезов из схемы §3.1 (SPEC §20.4, §20.6, §20.7).
//
//  Вторая половина каждого среза: `select`, и ничего кроме. Всё, что считается,
//  живёт в чистых функциях рядом — так правила §20.6 проверяются без живого
//  Postgres, а здесь остаётся то, что без него не проверить.
//
//  ── Фильтра по пользователю здесь нет, и это не забывчивость ──────────────
//
//  Его ставит RLS (§3.2), и §20.4 объявляет это единственной моделью доступа:
//  после подстановки claims `auth.uid()` возвращает того же пользователя, что и
//  для запроса из браузера. Дописать `where user_id = auth.uid()` значило бы
//  завести вторую модель рядом с первой — и создать впечатление, что изоляция
//  держится на ней. Она держится на политике и на бесправной роли `fitserver`.
//
//  ── Числа приводятся к float8 в SQL, а не при разборе ─────────────────────
//
//  Половина весовых колонок — `numeric` (§3.1), и у него своё проволочное
//  представление. Приведение стоит в списке выборки, чтобы тип на границе был
//  назван один раз и явно: молчаливый разбор `numeric` как `Double` работал бы
//  ровно до первого значения, которое в него не влезет.
//
//  ── Время переводится в SQL, и каждая колонка по своему правилу (§20.7) ───
//
//    date                 → text, дальше `LocalTime.day(iso:)`
//    timestamp без зоны   → `extract(epoch …)`: колонка УЖЕ на шкале FitCore
//                           (местное время), и «как будто UTC» даёт ровно её
//    timestamptz на день  → `at time zone $tz`, затем `::date`
//    timestamptz на поря-  → `extract(epoch …)` без зоны: значение служит только
//    док (finished_at)      упорядочиванию, и общий сдвиг его не меняет (§20.6)

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import FitAPI
import FitCore
import PostgresNIO

extension Mapping {

    /// Отказ чтения среза. Отдельно от `DatabaseFailure`: там про соединение,
    /// здесь про содержимое.
    public enum ReadFailure: Error, Equatable, Sendable {
        /// Строка обязана быть и её нет. Для `profiles` это значит, что
        /// онбординг не начинали вовсе.
        case missingRow(String)
        /// Колонка `date` не разобралась. Означает рассогласование схемы с
        /// кодом, а не плохие данные: Postgres не хранит невалидных дат.
        case malformedDate(String)

        /// Код §20.3. Без него оба случая доезжали до клиента как `internal`:
        /// «профиля ещё нет» — это ответ, а не поломка, и `GET /v1/profile` у
        /// не начавшей онбординг обязан говорить `not_found`.
        ///
        /// `malformedDate` остаётся `internal` намеренно: невалидной даты в
        /// колонке `date` быть не может, значит разошлись схема и код — наша
        /// поломка, и клиенту по ней делать нечего.
        public var code: APIErrorCode {
            switch self {
            case .missingRow: return .notFound
            case .malformedDate: return .internal
            }
        }
    }

    static func day(_ iso: String, column: String) throws -> CalendarDay {
        guard let day = LocalTime.day(iso: iso) else { throw ReadFailure.malformedDate(column) }
        return day
    }

    // MARK: - profiles

    public static func readProfile(_ tx: UserTransaction) async throws -> ProfileSlice {
        let rows = try await tx.query("""
            select experience_level, goal, training_weekdays, session_minutes,
                   cycle_tracking, sex_at_birth
              from profiles
            """)
        for try await row in rows {
            let (level, goal, weekdays, minutes, tracking, sex) =
                try row.decode((String?, String?, [Int16]?, Int, String, String?).self)
            return profile(from: ProfileRow(
                experienceLevel: level, goal: goal, trainingWeekdays: weekdays?.map(Int.init),
                sessionMinutes: minutes, cycleTracking: tracking, sexAtBirth: sex))
        }
        throw ReadFailure.missingRow("profiles")
    }

    // MARK: - equipment_profiles

    /// `id` — из тела `POST /v1/workouts`; `nil` берёт профиль с `is_default`
    /// (§20.3).
    ///
    /// Касты `::uuid` у параметра обязательны и лишними не являются: в
    /// `$1 is null` Postgres тип вывести не может и отвечает `42P18`
    /// («could not determine data type of parameter»). Проверка `EXPLAIN` этого
    /// не ловит, если писать литерал `null::uuid` руками — каст тогда стоит в
    /// проверке, а не в коде.
    public static func readEquipment(_ tx: UserTransaction, id: UUID?) async throws -> EquipmentSlice {
        let rows = try await tx.query("""
            select dumbbells_kg::float8[], plates_kg::float8[], barbell_kg::float8,
                   machine_step_kg::float8, has_kettlebells, kettlebells_kg::float8[],
                   bands, pullup_bar, bench, cable_machine, machines, step_platform, plyo_box
              from equipment_profiles
             where (\(id)::uuid is null and is_default) or id = \(id)::uuid
             limit 1
            """)
        for try await row in rows {
            let (dumbbells, plates, barbell, step, hasKb, kettlebells,
                 bands, bar, bench, cable, machines, platform, box) =
                try row.decode(([Double], [Double], Double?, Double?, Bool, [Double],
                                Bool, Bool, String?, Bool, [String], Bool, Bool).self)
            return equipment(from: EquipmentRow(
                dumbbellsKg: dumbbells, platesKg: plates, barbellKg: barbell, machineStepKg: step,
                hasKettlebells: hasKb, kettlebellsKg: kettlebells, bands: bands, pullupBar: bar,
                bench: bench, cableMachine: cable, machines: machines,
                stepPlatform: platform, plyoBox: box))
        }
        throw ReadFailure.missingRow("equipment_profiles")
    }

    // MARK: - Безопасность

    public static func readSafety(_ tx: UserTransaction, level: ExperienceLevel,
                                  timeZone: TimeZone) async throws -> SafetyProfile {
        var restrictionRows: [RestrictionRow] = []
        // `resolved_at is null` — §20.6, обязанность 10. Условие стоит и здесь,
        // и в чистой функции: снятое ограничение, доехавшее до подбора, ничем
        // себя не обнаруживает.
        let restrictions = try await tx.query("""
            select joint, severity from user_restrictions where resolved_at is null
            """)
        for try await row in restrictions {
            let (joint, severity) = try row.decode((String, String).self)
            restrictionRows.append(RestrictionRow(joint: joint, severity: severity))
        }

        var painRows: [PainRow] = []
        let pain = try await tx.query("""
            select s.exercise_slug, s.pain_joints,
                   -- День СЕССИИ события, зафиксированный при записи (§20.7), а
                   -- не `completed_at` в зоне читающего запроса.
                   to_char(s.performed_on, 'YYYY-MM-DD')
              from sets s
              join workout_exercises we on we.id = s.workout_exercise_id
             where s.pain_flag and s.completed_at is not null
            """)
        for try await row in pain {
            let (slug, joints, date) = try row.decode((String, [String], String).self)
            painRows.append(PainRow(exerciseSlug: slug, joints: joints,
                                    occurredOn: try day(date, column: "sets.performed_on")))
        }

        var hasRedFlag = false
        let parq = try await tx.query("select has_red_flag from parq_responses")
        for try await row in parq { hasRedFlag = try row.decode(Bool.self) }

        return safety(level: level, restrictions: restrictionRows,
                      painRows: painRows, hasRedFlag: hasRedFlag)
    }

    // MARK: - Цикл

    /// Состояние цикла после применения закрытых циклов (§11.5, §20.6).
    ///
    /// `persist` — пишущий ли это путь. `/today` и `/preview` по §20.6 не пишут
    /// ничего и считают применённый профиль в памяти; остальные сохраняют
    /// изменившиеся колонки счётчика. `updated_at` не трогается намеренно
    /// (`persistCycleCounters`).
    public static func readCycle(_ tx: UserTransaction, tracking: CycleTracking,
                                 asOf today: CalendarDay, persist: Bool) async throws -> CycleRead {
        var events: [CycleEventRow] = []
        let eventRows = try await tx.query("""
            select kind, to_char(occurred_on, 'YYYY-MM-DD') from cycle_events order by occurred_on
            """)
        for try await row in eventRows {
            let (kind, date) = try row.decode((String, String).self)
            events.append(CycleEventRow(kind: kind,
                                        occurredOn: try day(date, column: "cycle_events.occurred_on")))
        }

        var profileRow: CycleProfileRow?
        let profiles = try await tx.query("""
            select typical_cycle_length_days, typical_period_length_days, declared_regularity,
                   phase_mode, no_phase_reason, low_confidence_streak,
                   to_char(low_confidence_counted_through, 'YYYY-MM-DD')
              from cycle_profiles
            """)
        for try await row in profiles {
            let (length, period, regularity, mode, reason, streak, through) =
                try row.decode((Int?, Int?, String?, String, String?, Int, String?).self)
            profileRow = CycleProfileRow(
                typicalCycleLengthDays: length, typicalPeriodLengthDays: period,
                declaredRegularity: regularity, phaseMode: mode, noPhaseReason: reason,
                lowConfidenceStreak: streak,
                lowConfidenceCountedThrough: try through.map {
                    try day($0, column: "cycle_profiles.low_confidence_counted_through")
                })
        }

        var responses: [PhaseResponseRow] = []
        let responseRows = try await tx.query("""
            select phase, adjustment::float8, sample_size, notified_at::text
              from phase_response_profile
            """)
        for try await row in responseRows {
            let (phase, adjustment, size, notified) =
                try row.decode((String, Double, Int, String?).self)
            responses.append(PhaseResponseRow(phase: phase, adjustment: adjustment,
                                              sampleSize: size, notifiedAt: notified))
        }

        let raw = cycleInputs(events: events, profile: profileRow,
                              responses: responses, tracking: tracking)
        let applies = profileRow != nil && tracking != .off
        let applied = applyingClosedCycles(to: raw, applies: applies, asOf: today)
        if persist, applied.profile != raw.profile {
            guard let userID = UUID(uuidString: tx.token.subject) else {
                throw ReadFailure.missingRow("cycle_profiles")
            }
            try await persistCycleCounters(tx, userID: userID, applied.profile)
        }
        return CycleRead(inputs: applied, stored: raw.profile, applies: applies)
    }

    /// Сохранённый профиль цикла как есть, без подстановки режима по
    /// `cycle_tracking` (§20.6): нужен переключению режима в `PATCH`, которому
    /// важно, что лежит в строке, а не что увидит планировщик.
    public static func readStoredCycleProfile(_ tx: UserTransaction) async throws -> CycleProfile? {
        let rows = try await tx.query("""
            select typical_cycle_length_days, typical_period_length_days, declared_regularity,
                   phase_mode, no_phase_reason, low_confidence_streak,
                   to_char(low_confidence_counted_through, 'YYYY-MM-DD')
              from cycle_profiles
            """)
        for try await row in rows {
            let (length, period, regularity, mode, reason, streak, through) =
                try row.decode((Int?, Int?, String?, String, String?, Int, String?).self)
            return cycleProfile(from: CycleProfileRow(
                typicalCycleLengthDays: length, typicalPeriodLengthDays: period,
                declaredRegularity: regularity, phaseMode: mode, noPhaseReason: reason,
                lowConfidenceStreak: streak,
                lowConfidenceCountedThrough: try through.map {
                    try day($0, column: "cycle_profiles.low_confidence_counted_through")
                }), tracking: .manual)
        }
        return nil
    }

    /// Наибольшая `period_start`, не позже `cutoff`.
    public static func readLatestPeriodStart(_ tx: UserTransaction,
                                             notAfter cutoff: CalendarDay) async throws -> CalendarDay? {
        let rows = try await tx.query("""
            select to_char(max(occurred_on), 'YYYY-MM-DD') from cycle_events
             where kind = 'period_start' and occurred_on <= \(LocalTime.iso(cutoff))::date
            """)
        for try await row in rows {
            if let value = try row.decode(String?.self) {
                return try day(value, column: "cycle_events.occurred_on")
            }
        }
        return nil
    }

    // MARK: - Чек-ин

    public static func readCheckin(_ tx: UserTransaction,
                                   on date: CalendarDay) async throws -> (DailyCheckin, Override?) {
        let rows = try await tx.query("""
            select energy, soreness, sleep_quality, stress, override
              from daily_checkins
             where checkin_date = \(LocalTime.iso(date))::date
            """)
        for try await row in rows {
            let (energy, soreness, sleep, stress, override) =
                try row.decode((Int?, Int?, Int?, Int?, String?).self)
            return checkin(from: CheckinRow(energy: energy, soreness: soreness,
                                            sleepQuality: sleep, stress: stress, override: override))
        }
        return checkin(from: nil)
    }

    // MARK: - Утомление

    public static func readFatigue(_ tx: UserTransaction) async throws -> [MuscleSlug: FatigueState] {
        // Колонка `timestamp` БЕЗ зоны и уже на шкале FitCore (§20.7), поэтому
        // `extract(epoch …)` даёт ровно её значение: перевод здесь был бы
        // вторым применением зоны к тому, к чему она уже применена при записи.
        let rows = try await tx.query("""
            select muscle, value::float8, extract(epoch from updated_at)::float8 / 3600
              from muscle_fatigue
            """)
        var result: [FatigueRow] = []
        for try await row in rows {
            let (muscle, value, hours) = try row.decode((String, Double, Double).self)
            result.append(FatigueRow(muscle: muscle, value: value,
                                     updatedAt: Timestamp(hoursSinceEpoch: hours)))
        }
        return fatigue(from: result)
    }

    // MARK: - Неделя

    /// `id` недели и признак разгрузки. `nil` — недели нет, и это законное
    /// состояние: `/today` отдаёт день с `kind = not_built` (§20.3).
    public static func readWeekPlan(_ tx: UserTransaction,
                                    weekStart: CalendarDay) async throws -> (id: UUID, isDeload: Bool)? {
        let rows = try await tx.query("""
            select id, is_deload from week_plans where week_start = \(LocalTime.iso(weekStart))::date
            """)
        for try await row in rows { return try row.decode((UUID, Bool).self) }
        return nil
    }

    public static func readPlannedDays(_ tx: UserTransaction,
                                       weekPlanID: UUID) async throws -> [PlannedDayRow] {
        let rows = try await tx.query("""
            select id::text, to_char(planned_date, 'YYYY-MM-DD'), session_kind, accent_muscle, status
              from planned_days
             where week_plan_id = \(weekPlanID)
             order by planned_date
            """)
        var result: [PlannedDayRow] = []
        for try await row in rows {
            let (id, date, kind, accent, status) =
                try row.decode((String, String, String, String?, String).self)
            result.append(PlannedDayRow(id: id,
                                        date: try day(date, column: "planned_days.planned_date"),
                                        sessionKind: kind, accentMuscle: accent, status: status))
        }
        return result
    }

    /// `planned_day_id` тренировок, которые начаты и не закрыты.
    ///
    /// `WeekContext.startedDayIDs` — правило неприкосновенности §7.1: начатую
    /// тренировку пересборка не трогает. Завершённые сюда не входят: их день
    /// уже несёт `status = done`, и `classify` разбирает его раньше.
    public static func readStartedDayIDs(_ tx: UserTransaction) async throws -> Set<String> {
        let rows = try await tx.query("""
            select planned_day_id::text from workouts
             where finished_at is null and deleted_at is null and planned_day_id is not null
            """)
        var result: Set<String> = []
        for try await row in rows { result.insert(try row.decode(String.self)) }
        return result
    }

    // MARK: - Состояния упражнений

    /// Снимок `exercise_states.in_calibration` по слагам (§20.6).
    ///
    /// Нужен ровно на старте тренировки: `workout_exercises.is_calibration`
    /// ставится СНИМКОМ этой колонки, а не join'ом на чтении — по тому же
    /// доводу, по которому §19.2 п.8 зафиксировал `pain_joints` на момент
    /// события. Калибровка кончается по упражнению (§9.8), и тренировка,
    /// начатая в калибровке, обязана остаться такой в журнале, даже когда
    /// упражнение из неё вышло.
    ///
    /// Отсутствующая строка — `true` у вызывающей стороны: упражнение, которое
    /// ни разу не делали, находится в калибровке по определению (§9.8), и
    /// схема говорит то же самое (`in_calibration boolean not null default
    /// true`). Подставлять умолчание здесь нельзя — словарь не знает, о каких
    /// слагах его спросят.
    public static func readCalibrationFlags(_ tx: UserTransaction) async throws -> [String: Bool] {
        var flags: [String: Bool] = [:]
        let rows = try await tx.query("select exercise_slug, in_calibration from exercise_states")
        for try await row in rows {
            let (slug, flag) = try row.decode((String, Bool).self)
            flags[slug] = flag
        }
        return flags
    }

    // MARK: - Журнал подходов

    /// Все подходы пользователя с их упражнением и тренировкой.
    ///
    /// Один `select` кормит четверых потребителей сразу — журнал упражнений,
    /// утомление, `неделя[m]` и корень дерева §20.9, — и это не экономия
    /// запроса, а следствие того, что все четверо читают одну и ту же строку
    /// разными правилами (§20.6).
    ///
    /// `since` ограничивает выборку, и `nil` означает «вся история».
    ///
    /// Умолчания у границы нет намеренно. `Progression.rebuildStates` — свёртка
    /// ПО ВСЕМУ журналу: базовая линия строится с нуля, поэтому усечение меняет
    /// её, а не ускоряет тот же ответ. Правило, какую историю достаточно
    /// прочитать, SPEC не задаёт, и придумывать его здесь значило бы менять
    /// веса незаметно. Пока граница не назначена, вызывающая сторона передаёт
    /// `nil`.
    public static func readSets(_ tx: UserTransaction, since: CalendarDay?,
                                timeZone: TimeZone) async throws -> [SetRow] {
        let zone = timeZone.identifier
        let from = since.map(LocalTime.iso) ?? "0001-01-01"
        let rows = try await tx.query("""
            select s.exercise_slug, s.set_index, s.prescribed_kg::float8, s.actual_kg::float8,
                   s.actual_reps, s.feedback, s.skipped, s.pain_flag, s.is_calibration,
                   s.weight_readiness::float8,
                   to_char(s.performed_on, 'YYYY-MM-DD')
              from sets s
              join workout_exercises we on we.id = s.workout_exercise_id
              join workouts w on w.id = we.workout_id
             where s.performed_on >= \(from)::date
               and w.deleted_at is null
             order by w.started_at, we.order_index, s.set_index
            """)
        var result: [SetRow] = []
        for try await row in rows {
            let (slug, index, prescribed, actual, reps, feedback, skipped, pain,
                 calibration, readiness, date) =
                try row.decode((String, Int, Double?, Double?, Int?, String?, Bool, Bool,
                                Bool, Double, String).self)
            result.append(SetRow(exerciseSlug: slug, setIndex: index, prescribedKg: prescribed,
                                 actualKg: actual, actualReps: reps, feedback: feedback,
                                 skipped: skipped, painFlag: pain, isCalibration: calibration,
                                 weightReadiness: readiness,
                                 performedOn: try day(date, column: "sets.performed_on")))
        }
        return result
    }

    /// Выполненные тренировки и их подходы — вход `неделя[m]` (§7.3).
    ///
    /// Двумя запросами, а не одним: ключ у них разный — там день, здесь
    /// `workouts.id`, — и складывать оба в один `select` значило бы завести
    /// правило «какая колонка чья» там, где его сейчас нет.
    public static func readCompleted(_ tx: UserTransaction, since: CalendarDay?,
                                     timeZone: TimeZone) async throws
        -> (rows: [CompletedWorkoutRow], sets: [String: [SetRow]]) {
        let zone = timeZone.identifier
        let from = since.map(LocalTime.iso) ?? "0001-01-01"

        var workouts: [CompletedWorkoutRow] = []
        // День тренировки — самый ранний `performed_on` её подходов (§20.7): он
        // зафиксирован при записи. У тренировки без подходов дня на подходе
        // нет, и берётся `started_at` в зоне запроса — объёма она не несёт.
        let workoutRows = try await tx.query("""
            select w.id::text, w.planned_day_id::text, to_char(d.day, 'YYYY-MM-DD'),
                   extract(epoch from w.finished_at)::float8 / 3600
              from workouts w
              cross join lateral (
                select coalesce(
                         (select min(s.performed_on) from sets s
                            join workout_exercises we on we.id = s.workout_exercise_id
                           where we.workout_id = w.id),
                         (w.started_at at time zone \(zone))::date) as day) d
             where w.finished_at is not null and w.deleted_at is null
               and d.day >= \(from)::date
             order by w.finished_at
            """)
        for try await row in workoutRows {
            let (id, plannedDay, date, hours) =
                try row.decode((String, String?, String, Double).self)
            workouts.append(CompletedWorkoutRow(
                id: id, plannedDayID: plannedDay,
                date: try day(date, column: "sets.performed_on"),
                // §20.6, обязанность 12: из `finished_at`, и без зоны —
                // значение служит только порядку.
                performedAt: Timestamp(hoursSinceEpoch: hours)))
        }

        var sets: [String: [SetRow]] = [:]
        let setRows = try await tx.query("""
            select w.id::text, s.exercise_slug, s.set_index, s.actual_reps, s.feedback,
                   s.skipped, s.pain_flag, s.is_calibration
              from sets s
              join workout_exercises we on we.id = s.workout_exercise_id
              join workouts w on w.id = we.workout_id
             where w.finished_at is not null and w.deleted_at is null
               and coalesce((select min(s2.performed_on) from sets s2
                               join workout_exercises we2 on we2.id = s2.workout_exercise_id
                              where we2.workout_id = w.id),
                            (w.started_at at time zone \(zone))::date) >= \(from)::date
            """)
        for try await row in setRows {
            let (workoutID, slug, index, reps, feedback, skipped, pain, calibration) =
                try row.decode((String, String, Int, Int?, String?, Bool, Bool, Bool).self)
            sets[workoutID, default: []].append(
                SetRow(exerciseSlug: slug, setIndex: index, actualReps: reps, feedback: feedback,
                       skipped: skipped, painFlag: pain, isCalibration: calibration,
                       // День здесь не читается: `completedWorkouts` считает по
                       // этим строкам только количество (§7.3).
                       performedOn: CalendarDay(dayNumber: 0)))
        }
        return (workouts, sets)
    }
}
