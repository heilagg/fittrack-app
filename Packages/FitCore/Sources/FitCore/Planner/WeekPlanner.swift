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
    /// Журнал подходов по упражнениям (§4.3); порядок значения не имеет —
    /// свёртка сортирует его сама. Состояние
    /// прогрессии планировщик сворачивает сам — `Progression.rebuildStates` с
    /// лестницей ТЕКУЩЕГО инвентаря и диапазоном цели: готовое состояние от
    /// вызывающей стороны могло быть посчитано с другой лестницей (триггер
    /// «изменение инвентаря», §7.1), и предписание разошлось бы с ним.
    public var exerciseHistory: [String: [ExerciseSession]]
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
        exerciseHistory: [String: [ExerciseSession]] = [:],
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
        self.exerciseHistory = exerciseHistory
        self.cycle = cycle
        self.todayCheckin = todayCheckin
        self.todayOverride = todayOverride
        self.isDeloadWeek = isDeloadWeek
        self.userSeed = userSeed
        self.weights = weights
    }
}

public struct WeekPlan: Sendable, Equatable {
    /// Итог каждого дня недели по `PlannedDay.id` — один источник статуса для
    /// потерь, «Плана обновлён» и показа (DayOutcome.swift).
    public var days: [String: DayOutcome]
    /// Строки статуса недели (§7.1): потеря объёма, недобор по времени.
    public var statusLines: [ReasonCode]

    /// Собранные тренировки — срез `days` для тех, кому нужен только план.
    public var sessions: [String: BuiltSession] {
        days.compactMapValues(\.session)
    }

    /// Дни, которые идут растяжкой: сетка §7.2 либо оверрайд `rest` (§11.4).
    public var stretchDayIDs: [String] {
        days.values.filter { $0.kind == .stretching }.map(\.dayID).sorted()
    }
}

extension Planner {
    /// Момент оценки утомления дня — 12:00 (§7.1). Контракт: `Timestamp` и
    /// `CalendarDay` отсчитываются от одной эпохи в местном времени, то есть
    /// полночь дня `d` — `d.dayNumber × 24` часов.
    ///
    /// Контракт местного времени определяет и хранение (SPEC §20.7): величины
    /// этой шкалы лежат в колонках без зоны (`muscle_fatigue.updated_at` —
    /// `timestamp`, `exercise_states.last_performed_at` — `date`), а настоящие
    /// моменты (`workouts.started_at`, `sets.completed_at`) остаются
    /// `timestamptz` и в расчёт не подставляются. Перевод делается один раз,
    /// при записи, в зоне запроса — не при каждом чтении.
    public static func evaluationMoment(for day: CalendarDay) -> Timestamp {
        Timestamp(hoursSinceEpoch: Double(day.dayNumber) * 24 + 12)
    }

    public static func daySeed(userSeed: UInt64, day: CalendarDay) -> UInt64 {
        var rng = SplitMix64(state: userSeed ^ (UInt64(bitPattern: Int64(day.dayNumber)) &* 0xD6E8_FEB8_6659_FD93))
        return rng.next()
    }

    public static func planRemainingDays(_ ctx: WeekContext) -> WeekPlan {
        // Двух строк недели с одним `id` не бывает: `planned_days.id` —
        // первичный ключ, а пара (неделя, дата) уникальна (§3.1). Это ошибка
        // вызывающей стороны или синхронизации, и в отладке она обязана быть
        // громкой. `assert`, а не `precondition`: в релизе планировщик остаётся
        // рабочим — план недели не то, ради чего стоит ронять приложение.
        assert(Set(ctx.week.map(\.id)).count == ctx.week.count,
               "planned_days с одинаковым id: \(ctx.week.map(\.id).sorted())")
        // В релизе поведение обязано быть определённым и ОДИНАКОВЫМ у всех
        // потребителей: раньше словарь итогов схлопывал дубликат, а знаменатель
        // S_эфф и сумма потерь считали его дважды. Дальше по коду идёт один
        // массив — первая строка на каждый id.
        let week = normalizedWeek(ctx.week)
        let libraryBySlug = Dictionary(ctx.library.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        let weekDone = weekDoneVolume(completed: ctx.completed, weekStart: ctx.weekStart, library: libraryBySlug)
        let previous = ctx.completed.max { $0.performedAt < $1.performedAt }.map { Set($0.setsBySlug.keys) } ?? []
        let states = exerciseStates(history: ctx.exerciseHistory, library: ctx.library, goal: ctx.goal, equipment: ctx.equipment)

        var outcomes: [String: DayOutcome] = [:]
        var shortfall: [MuscleSlug: Double] = [:]
        for (i, day) in week.enumerated() {
            var outcome = classify(day: day, ctx: ctx)
            defer { outcomes[day.id] = outcome }
            guard outcome.kind == .session else { continue }

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
                exerciseStates: states, cycleState: cycleState, readiness: readiness,
                isDeloadWeek: ctx.isDeloadWeek, seed: daySeed(userSeed: ctx.userSeed, day: day.date),
                weights: ctx.weights
            )
            guard let built = buildSession(input) else { continue }
            outcome.session = built

            input.sessionMinutes = nil
            if let unbounded = buildSession(input) {
                // Только мышцы вектора дня: побочные вклады вне него (разгибатели
                // в тяге) день не просил, и недобором они не являются (§7.1).
                for (m, share) in day.vector where share > 0 {
                    shortfall[m, default: 0] += max(0, (unbounded.effectiveVolume[m] ?? 0) - (built.effectiveVolume[m] ?? 0))
                }
            }
        }

        var lines = weekLostVolume(outcomes: outcomes, week: week, level: ctx.safety.level)
        for day in week where outcomes[day.id]?.kind == .vectorMissing {
            lines.append(.dayVectorMissing(kind: day.kind, accent: day.accent))
        }
        if outcomes.values.contains(where: { $0.kind == .generatorDisabled }) {
            lines.append(.workoutGenerationDisabled)
        }
        if outcomes.values.contains(where: { $0.session?.reasons.contains(.noFeasibleExercises) ?? false }) {
            lines.append(.noFeasibleExercises)
        }
        for m in MuscleSlug.allCases {
            let sets = Int((shortfall[m] ?? 0).rounded())
            if sets > 0 { lines.append(.weekShortfallByTime(muscle: m, sets: sets)) }
        }
        return WeekPlan(days: outcomes, statusLines: lines)
    }

    /// Неделя в том виде, в каком её читают все правила: по датам и по одной
    /// строке на `id`. Дедупликация — не поддержка дубликатов, а требование
    /// одинакового поведения у всех потребителей в релизе (см. `assert` в
    /// `planRemainingDays`): иначе словарь итогов схлопывает день, а знаменатель
    /// `S_эфф` и сумма потерь считают его дважды. Выигрывает первая строка.
    static func normalizedWeek(_ days: [PlannedDay]) -> [PlannedDay] {
        var seen = Set<String>()
        return days.sorted { $0.date < $1.date }.filter { seen.insert($0.id).inserted }
    }

    /// Журнал в хронологическом порядке: `rebuildStates` его не сортирует (так
    /// сказано в её doc-комментарии), а приходит он из слияния локальных и
    /// серверных записей (§4.3), где порядок не гарантирован. Нормализует вход
    /// тот, кто его потребляет, — как `buildSession` сортирует неделю, а
    /// `normalizedWeek` её дедуплицирует. Две сессии одного дня сохраняют
    /// порядок, в котором пришли: сортировка по паре (дата, позиция).
    static func chronological(_ sessions: [ExerciseSession]) -> [ExerciseSession] {
        sessions.enumerated()
            .sorted { ($0.element.performedAt, $0.offset) < ($1.element.performedAt, $1.offset) }
            .map(\.element)
    }

    /// Изменение плана — то, что пользователь видит на экране «Сегодня»:
    /// другой состав собранной тренировки либо смена судьбы дня по РЕШЕНИЮ
    /// планировщика (оверрайд `rest` заменил тренировку растяжкой и обратно).
    ///
    /// Уход дня из плана по ФАКТУ исполнения — пропуск, старт, выполнение,
    /// наступление следующего дня — изменением не считается: пересобирать там
    /// нечего, и §7.1 прямо требует молчания (сценарий 32b, пропущен последний
    /// день недели). То же правило, что делит §7.3 плановые решения и факты
    /// исполнения, только здесь оно решает, печатать ли строку.
    static func isPlanChange(before: DayOutcome, after: DayOutcome) -> Bool {
        func factOfExecution(_ outcome: DayOutcome) -> Bool {
            outcome.kind == .notBuilt
                && (outcome.cause == .skipped || outcome.cause == .started
                    || outcome.cause == .done || outcome.cause == .past)
        }
        if factOfExecution(after) { return false }
        if before.kind != after.kind || before.cause != after.cause { return true }
        return before.session?.composition != after.session?.composition
    }

    /// Состояние прогрессии каждого упражнения среза — свёртка журнала
    /// `Progression.rebuildStates` (§9, §4.3) с диапазоном повторов цели (§9.1)
    /// и лестницей текущего инвентаря. `planProgression` отдельно не вызывается:
    /// свёртка уже применяет её к каждой сессии, и второй вызов сдвинул бы
    /// базовую линию дважды. Детренированность на дату дня накладывает сборка
    /// (`Planner.stateForSession`). Упражнение без журнала состояния не имеет.
    public static func exerciseStates(
        history: [String: [ExerciseSession]],
        library: [ExerciseCandidate],
        goal: Goal,
        equipment: EquipmentProfile
    ) -> [String: ExerciseState] {
        var states: [String: ExerciseState] = [:]
        for candidate in library {
            guard let sessions = history[candidate.slug], !sessions.isEmpty, states[candidate.slug] == nil else { continue }
            states[candidate.slug] = Progression.rebuildStates(
                from: chronological(sessions),
                baseRange: baseRepRange(goal: goal),
                ladder: WeightLadder.build(loadType: candidate.loadType, profile: equipment)
            )
        }
        return states
    }

    /// «План обновлён» (§7.1) — только если у дней, которые были в прошлом
    /// показе и остались в этом, изменился состав или объём. Пересборка, которая
    /// ничего не изменила, строки не печатает.
    public static func rebuildNotice(previous: WeekPlan, current: WeekPlan, cause: RebuildCause) -> ReasonCode? {
        let changed = Set(previous.days.keys).union(current.days.keys).contains { id in
            guard let before = previous.days[id], let now = current.days[id] else { return true }
            return isPlanChange(before: before, after: now)
        }
        return changed ? .planRebuilt(cause: cause) : nil
    }
}
