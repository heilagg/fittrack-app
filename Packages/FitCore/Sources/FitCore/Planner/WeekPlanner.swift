//  Пересборка недели (SPEC §7.1). Собираются только не начатые дни с датой не
//  раньше сегодняшней; начатая тренировка и прошедшие дни не трогаются
//  (сценарий 33). Каждый такой день — от замороженного состояния: утомление
//  только от выполненных подходов с распадом до 12:00 дня, `неделя[m]` и
//  предыдущая тренировка — по выполненным, готовность — §10 по состоянию цикла
//  на дату дня, без check-in и оверрайда (сегодня — со своими).
//
//  Модуль не хранит ничего: пересборка с неизменившимся входом возвращает тот
//  же план по построению (сценарий 32e).

/// Вход `Cycle.state` — планировщик сам считает состояние цикла на дату
/// каждого дня (§7.1, «Будущие дни»).
public struct CycleInputs: Sendable, Equatable {
    public var events: [CycleEvent]
    public var profile: CycleProfile
    public var responseProfiles: [Phase: PhaseResponseProfile]

    public init(events: [CycleEvent], profile: CycleProfile, responseProfiles: [Phase: PhaseResponseProfile] = [:]) {
        self.events = events
        self.profile = profile
        self.responseProfiles = responseProfiles
    }
}

public struct WeekContext: Sendable {
    public var weekStart: CalendarDay
    /// Все строки `planned_days` недели, в любом статусе.
    public var week: [PlannedDay]
    public var today: CalendarDay
    public var startedDayIDs: Set<String>
    /// Выполненные тренировки — этой недели и, для w6, раньше.
    public var completed: [CompletedWorkout]
    /// Состояние утомления после всех выполненных подходов (Recovery).
    public var fatigue: [MuscleSlug: FatigueState]
    public var library: [ExerciseCandidate]
    public var availability: EquipmentAvailability
    public var equipment: EquipmentProfile
    public var safety: SafetyProfile
    public var goal: Goal
    public var sessionMinutes: Int
    public var exerciseStates: [String: ExerciseState]
    public var cycle: CycleInputs
    public var todayCheckin: DailyCheckin
    public var todayOverride: Override?
    public var isDeloadWeek: Bool
    /// Seed пользователя; seed дня выводится из пары (пользователь, дата) —
    /// §7.3 требует стабильности ровно для этой пары.
    public var userSeed: UInt64
    public var weights: PlannerWeights

    public init(
        weekStart: CalendarDay,
        week: [PlannedDay],
        today: CalendarDay,
        startedDayIDs: Set<String> = [],
        completed: [CompletedWorkout] = [],
        fatigue: [MuscleSlug: FatigueState] = [:],
        library: [ExerciseCandidate],
        availability: EquipmentAvailability,
        equipment: EquipmentProfile,
        safety: SafetyProfile,
        goal: Goal,
        sessionMinutes: Int,
        exerciseStates: [String: ExerciseState] = [:],
        cycle: CycleInputs,
        todayCheckin: DailyCheckin = DailyCheckin(),
        todayOverride: Override? = nil,
        isDeloadWeek: Bool = false,
        userSeed: UInt64,
        weights: PlannerWeights = .spec
    ) {
        self.weekStart = weekStart
        self.week = week
        self.today = today
        self.startedDayIDs = startedDayIDs
        self.completed = completed
        self.fatigue = fatigue
        self.library = library
        self.availability = availability
        self.equipment = equipment
        self.safety = safety
        self.goal = goal
        self.sessionMinutes = sessionMinutes
        self.exerciseStates = exerciseStates
        self.cycle = cycle
        self.todayCheckin = todayCheckin
        self.todayOverride = todayOverride
        self.isDeloadWeek = isDeloadWeek
        self.userSeed = userSeed
        self.weights = weights
    }
}

public struct WeekPlan: Sendable, Equatable {
    /// Собранные не начатые дни по `PlannedDay.id`.
    public var sessions: [String: BuiltSession]
    /// Строки статуса недели (§7.1): потеря от пропусков, недобор по времени.
    public var statusLines: [ReasonCode]
}

extension Planner {
    /// Момент оценки утомления дня — 12:00 (§7.1). Контракт: `Timestamp` и
    /// `CalendarDay` отсчитываются от одной эпохи в местном времени, то есть
    /// полночь дня `d` — `d.dayNumber × 24` часов.
    public static func evaluationMoment(for day: CalendarDay) -> Timestamp {
        Timestamp(hoursSinceEpoch: Double(day.dayNumber) * 24 + 12)
    }

    public static func daySeed(userSeed: UInt64, day: CalendarDay) -> UInt64 {
        var rng = SplitMix64(state: userSeed ^ (UInt64(bitPattern: Int64(day.dayNumber)) &* 0xD6E8_FEB8_6659_FD93))
        return rng.next()
    }

    public static func planRemainingDays(_ ctx: WeekContext) -> WeekPlan {
        let week = ctx.week.sorted { $0.date < $1.date }
        let libraryBySlug = Dictionary(ctx.library.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        let weekDone = weekDoneVolume(completed: ctx.completed, weekStart: ctx.weekStart, library: libraryBySlug)
        let previous = ctx.completed.max { $0.performedAt < $1.performedAt }.map { Set($0.setsBySlug.keys) } ?? []

        var sessions: [String: BuiltSession] = [:]
        var shortfall: [MuscleSlug: Double] = [:]
        for (i, day) in week.enumerated()
        where day.isStrength && day.status == .planned && day.date >= ctx.today && !ctx.startedDayIDs.contains(day.id) {
            let cycleState = Cycle.state(events: ctx.cycle.events, profile: ctx.cycle.profile,
                                         responseProfiles: ctx.cycle.responseProfiles, asOf: day.date)
            let isToday = day.date == ctx.today
            let readiness = Readiness.value(cycleState: cycleState,
                                            override: isToday ? ctx.todayOverride : nil,
                                            checkin: isToday ? ctx.todayCheckin : DailyCheckin())
            let moment = evaluationMoment(for: day.date)
            let fatigue = Dictionary(uniqueKeysWithValues: ctx.fatigue.map { m, state in
                (m, Recovery.decayed(state, to: moment, muscle: m))
            })
            var input = SessionInput(
                week: week, dayIndex: i, library: ctx.library,
                availability: ctx.availability, equipment: ctx.equipment, safety: ctx.safety,
                goal: ctx.goal, sessionMinutes: ctx.sessionMinutes,
                fatigue: fatigue, weekDone: weekDone, previousWorkoutSlugs: previous,
                exerciseStates: ctx.exerciseStates, cycleState: cycleState, readiness: readiness,
                isDeloadWeek: ctx.isDeloadWeek, seed: daySeed(userSeed: ctx.userSeed, day: day.date),
                weights: ctx.weights
            )
            guard let built = buildSession(input) else { continue }
            sessions[day.id] = built

            input.sessionMinutes = nil
            if let unbounded = buildSession(input) {
                for (m, v) in unbounded.effectiveVolume {
                    shortfall[m, default: 0] += max(0, v - (built.effectiveVolume[m] ?? 0))
                }
            }
        }

        var lines = weekLossFromSkips(week: week, level: ctx.safety.level)
        for m in MuscleSlug.allCases {
            let sets = Int((shortfall[m] ?? 0).rounded())
            if sets > 0 { lines.append(.weekShortfallByTime(muscle: m, sets: sets)) }
        }
        return WeekPlan(sessions: sessions, statusLines: lines)
    }

    /// «План обновлён» (§7.1) — только если у дней, которые были в прошлом
    /// показе и остались в этом, изменился состав или объём. Пересборка, которая
    /// ничего не изменила, строки не печатает.
    public static func rebuildNotice(previous: WeekPlan, current: WeekPlan, cause: RebuildCause) -> ReasonCode? {
        let changed = current.sessions.contains { id, session in
            guard let before = previous.sessions[id] else { return false }
            return before.composition != session.composition
        }
        return changed ? .planRebuilt(cause: cause) : nil
    }
}
