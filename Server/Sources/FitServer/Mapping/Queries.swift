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
    public static func readEquipment(_ tx: UserTransaction, id: UUID?) async throws -> EquipmentSlice {
        let rows = try await tx.query("""
            select dumbbells_kg::float8[], plates_kg::float8[], barbell_kg::float8,
                   machine_step_kg::float8, has_kettlebells, kettlebells_kg::float8[],
                   bands, pullup_bar, bench, cable_machine, machines, step_platform, plyo_box
              from equipment_profiles
             where (\(id) is null and is_default) or id = \(id)
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
            select we.exercise_slug, s.pain_joints,
                   to_char((s.completed_at at time zone \(timeZone.identifier))::date, 'YYYY-MM-DD')
              from sets s
              join workout_exercises we on we.id = s.workout_exercise_id
             where s.pain_flag and s.completed_at is not null
            """)
        for try await row in pain {
            let (slug, joints, date) = try row.decode((String, [String], String).self)
            painRows.append(PainRow(exerciseSlug: slug, joints: joints,
                                    occurredOn: try day(date, column: "sets.completed_at")))
        }

        var hasRedFlag = false
        let parq = try await tx.query("select has_red_flag from parq_responses")
        for try await row in parq { hasRedFlag = try row.decode(Bool.self) }

        return safety(level: level, restrictions: restrictionRows,
                      painRows: painRows, hasRedFlag: hasRedFlag)
    }

    // MARK: - Цикл

    public static func readCycle(_ tx: UserTransaction,
                                 tracking: CycleTracking) async throws -> CycleInputs {
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

        return cycleInputs(events: events, profile: profileRow,
                           responses: responses, tracking: tracking)
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

    // MARK: - Журнал подходов

    /// Все подходы пользователя с их упражнением и тренировкой.
    ///
    /// Один `select` кормит четверых потребителей сразу — журнал упражнений,
    /// утомление, `неделя[m]` и корень дерева §20.9, — и это не экономия
    /// запроса, а следствие того, что все четверо читают одну и ту же строку
    /// разными правилами (§20.6).
    ///
    /// `since` ограничивает выборку: свёртке §9 нужна история упражнения, а не
    /// вся жизнь аккаунта. Границу выбирает вызывающая сторона — у недельного
    /// плана и у старта тренировки она разная.
    public static func readSets(_ tx: UserTransaction, since: CalendarDay,
                                timeZone: TimeZone) async throws -> [SetRow] {
        let zone = timeZone.identifier
        let from = LocalTime.iso(since)
        let rows = try await tx.query("""
            select we.exercise_slug, s.set_index, s.prescribed_kg::float8, s.actual_kg::float8,
                   s.actual_reps, s.feedback, s.skipped, s.pain_flag, we.is_calibration,
                   we.weight_readiness::float8,
                   to_char((w.started_at at time zone \(zone))::date, 'YYYY-MM-DD')
              from sets s
              join workout_exercises we on we.id = s.workout_exercise_id
              join workouts w on w.id = we.workout_id
             where (w.started_at at time zone \(zone))::date >= \(from)::date
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
                                 performedOn: try day(date, column: "workouts.started_at")))
        }
        return result
    }

    /// Выполненные тренировки и их подходы — вход `неделя[m]` (§7.3).
    ///
    /// Двумя запросами, а не одним: ключ у них разный — там день, здесь
    /// `workouts.id`, — и складывать оба в один `select` значило бы завести
    /// правило «какая колонка чья» там, где его сейчас нет.
    public static func readCompleted(_ tx: UserTransaction, since: CalendarDay,
                                     timeZone: TimeZone) async throws
        -> (rows: [CompletedWorkoutRow], sets: [String: [SetRow]]) {
        let zone = timeZone.identifier
        let from = LocalTime.iso(since)

        var workouts: [CompletedWorkoutRow] = []
        let workoutRows = try await tx.query("""
            select w.id::text, w.planned_day_id::text,
                   to_char((w.started_at at time zone \(zone))::date, 'YYYY-MM-DD'),
                   extract(epoch from w.finished_at)::float8 / 3600
              from workouts w
             where w.finished_at is not null and w.deleted_at is null
               and (w.started_at at time zone \(zone))::date >= \(from)::date
             order by w.finished_at
            """)
        for try await row in workoutRows {
            let (id, plannedDay, date, hours) =
                try row.decode((String, String?, String, Double).self)
            workouts.append(CompletedWorkoutRow(
                id: id, plannedDayID: plannedDay,
                date: try day(date, column: "workouts.started_at"),
                // §20.6, обязанность 12: из `finished_at`, и без зоны —
                // значение служит только порядку.
                performedAt: Timestamp(hoursSinceEpoch: hours)))
        }

        var sets: [String: [SetRow]] = [:]
        let setRows = try await tx.query("""
            select w.id::text, we.exercise_slug, s.set_index, s.actual_reps, s.feedback,
                   s.skipped, s.pain_flag, we.is_calibration
              from sets s
              join workout_exercises we on we.id = s.workout_exercise_id
              join workouts w on w.id = we.workout_id
             where w.finished_at is not null and w.deleted_at is null
               and (w.started_at at time zone \(zone))::date >= \(from)::date
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
