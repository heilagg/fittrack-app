//  Сборка конкретной тренировки (SPEC §7.3): пул → жадный отбор → ремонт
//  паттернов → локальное улучшение → целые подходы → порядок и числа
//  упражнения. Композиции §10 вызываются из Readiness, а не пишутся заново.
//
//  Состав подбирается по цели БЕЗ равномерного планового среза (фаза,
//  разгрузочная неделя), подходы раскладываются по цели С ним — так фаза меняет
//  только target_sets (сценарий 31a). Утомление неравномерно и входит в обе.

/// Вход сборки одного дня. Утомление уже с распадом до момента оценки дня
/// (§7.1: 12:00), готовность — уже посчитанная `Readiness.value` для этого дня.
public struct SessionInput: Sendable {
    public var week: [PlannedDay]
    public var dayIndex: Int
    public var library: [ExerciseCandidate]
    public var availability: EquipmentAvailability
    public var equipment: EquipmentProfile
    public var safety: SafetyProfile
    public var goal: Goal
    /// `nil` — сборка без бюджета (`факт_без_бюджета`, §7.1).
    public var sessionMinutes: Int?
    public var fatigue: [MuscleSlug: Double]
    public var weekDone: [MuscleSlug: Double]
    public var previousWorkoutSlugs: Set<String>
    public var exerciseStates: [String: ExerciseState]
    public var cycleState: CycleState
    public var readiness: Double
    public var isDeloadWeek: Bool
    public var seed: UInt64
    public var weights: PlannerWeights

    public init(
        week: [PlannedDay],
        dayIndex: Int,
        library: [ExerciseCandidate],
        availability: EquipmentAvailability,
        equipment: EquipmentProfile,
        safety: SafetyProfile,
        goal: Goal,
        sessionMinutes: Int?,
        fatigue: [MuscleSlug: Double] = [:],
        weekDone: [MuscleSlug: Double] = [:],
        previousWorkoutSlugs: Set<String> = [],
        exerciseStates: [String: ExerciseState] = [:],
        cycleState: CycleState,
        readiness: Double = 1.0,
        isDeloadWeek: Bool = false,
        seed: UInt64,
        weights: PlannerWeights = .spec
    ) {
        self.week = week
        self.dayIndex = dayIndex
        self.library = library
        self.availability = availability
        self.equipment = equipment
        self.safety = safety
        self.goal = goal
        self.sessionMinutes = sessionMinutes
        self.fatigue = fatigue
        self.weekDone = weekDone
        self.previousWorkoutSlugs = previousWorkoutSlugs
        self.exerciseStates = exerciseStates
        self.cycleState = cycleState
        self.readiness = readiness
        self.isDeloadWeek = isDeloadWeek
        self.seed = seed
        self.weights = weights
    }
}

/// Строка `workout_exercises` (§3.1) до старта тренировки.
public struct PrescribedExercise: Sendable, Equatable {
    public var slug: String
    public var orderIndex: Int
    public var targetSets: Int
    public var targetRepMin: Int
    public var targetRepMax: Int
    public var targetRIR: Int
    /// `nil` у упражнения без веса или без базовой линии (калибровка).
    public var prescribedKg: Double?
    /// §7.6: пишется всегда, в том числе без веса.
    public var weightReadiness: Double
}

public struct BuiltSession: Sendable, Equatable {
    public var dayID: String
    public var exercises: [PrescribedExercise]
    public var estimatedSeconds: Double
    public var effectiveVolume: [MuscleSlug: Double]
    public var leadingMuscle: MuscleSlug?
    public var scale: Double
    public var reasons: [ReasonCode]
    /// Диагностика для тестов: упражнения, снятые шагом 3 (§7.3) против цели
    /// без равномерного среза. Наружу не публикуется.
    var removedAtMinimum: [String] = []

    /// Состав и объём — то, по чему §7.1 решает, печатать ли «План обновлён».
    public var composition: [String: Int] {
        Dictionary(uniqueKeysWithValues: exercises.map { ($0.slug, $0.targetSets) })
    }
}

/// Веса целевой функции §7.3. w10 («на поддержании») всегда 0: флаг не
/// хранится, «более сложный вариант» не определён (§9.5, пп.3–4; §19.2 п.14).
/// Значения SPEC — `.spec`; другие веса нужны только прогону и тестам,
/// сравнивающим сборку «без слагаемого» (сценарии 27c, 27d).
public struct PlannerWeights: Sendable, Equatable {
    public var w1 = 1.0
    public var w2 = 2.0
    public var w3 = 0.5
    public var w4 = 0.5
    public var w5 = 2.0
    public var w6 = 0.5
    public var w7 = 3.0
    public var w8 = 0.5
    public var w9 = 0.5
    public var w10 = 0.0
    public var w11 = 5.0

    public init() {}

    public static let spec = PlannerWeights()
}

extension Planner {
    public static let scoreTolerance = 1e-9
    public static let maxExercises = 7
    public static let minSetsPerExercise = 2
    public static let maxSetsPerExercise = 5
    public static let maxImprovementPasses = 20
    /// Порог «низкой готовности» для w9 — не свой, а тот же, за которым §10
    /// поднимает RIR (§7.3, «нового порога не вводим»).
    public static let lowReadinessThreshold = Readiness.Thresholds.lowReadiness

    public static func buildSession(_ input: SessionInput) -> BuiltSession? {
        let day = input.week[input.dayIndex]
        guard day.isStrength else { return nil }
        // Порядок дней — забота сборки, а не вызывающей стороны: `remaining[m]`
        // слагаемого w11 («сессий недели от текущей включительно», §7.3) читает
        // неделю по датам, и массив в другом порядке молча менял бы вес
        // покрытия. Неделя сортируется здесь, день находится по `id`.
        var input = input
        if !input.week.indices.dropFirst().allSatisfy({ input.week[$0 - 1].date <= input.week[$0].date }) {
            let sorted = input.week.sorted { $0.date < $1.date }
            guard let index = sorted.firstIndex(where: { $0.id == day.id }) else { return nil }
            input.week = sorted
            input.dayIndex = index
        }
        // §14.3: при беременности генератор выключен — тренировки нет вовсе.
        // Пустая `BuiltSession` здесь была бы хуже `nil`: в плане недели она
        // выглядит как обычный день, у которого ничего не подобралось, а причина
        // видна только тому, кто заглянет в `reasons`. Причину несёт итог дня
        // (`DayOutcome.generatorDisabled`) и строка статуса недели.
        if input.cycleState.noPhaseReason == .pregnancy { return nil }
        guard let (lead, scale) = sessionScale(dayIndex: input.dayIndex, week: input.week, level: input.safety.level)
        else { return nil }
        var builder = Builder(input: input, day: day, scale: scale)
        var session = builder.build()
        session.leadingMuscle = lead
        return session
    }

    /// Куда ложится +1 подход готовности (§10): выбор делает
    /// `Readiness.exerciseForSessionSetIncrease`; упражнение, которое подход не
    /// приняло (`tryAdd` вернул false — потолок или бюджет), исключается, и
    /// выбор повторяется. Возвращает индекс, получивший подход, или nil.
    static func placeSessionSetIncrease(hasFatiguedMuscle: [Bool], tryAdd: (Int) -> Bool) -> Int? {
        var excluded = hasFatiguedMuscle
        while let k = Readiness.exerciseForSessionSetIncrease(hasFatiguedMuscle: excluded) {
            if tryAdd(k) { return k }
            excluded[k] = true
        }
        return nil
    }

    /// Состояние прогрессии на день сессии: детренированность §9.7 применяется
    /// «перед первой сессией после перерыва», а свёртка `rebuildStates` —
    /// только когда эта сессия записана, поэтому срез несёт предписание.
    /// Правило и числа — `Progression.detrainingAdjustment` и его свойства.
    /// Как и свёртка, срез действует только на весовые упражнения
    /// (`ladder != .none`): у упражнения без веса свёртка его не применяет, и
    /// предписание не расходится с тем, что запишется после сессии.
    static func stateForSession(_ state: ExerciseState, ladder: WeightLadder, on day: CalendarDay) -> ExerciseState {
        guard ladder != .none, let last = state.lastPerformedAt, state.baselineKg != nil else { return state }
        let decay = Progression.detrainingAdjustment(daysSinceLastPerformed: last.days(until: day))
        guard decay != .none else { return state }
        var adjusted = state
        adjusted.baselineKg = state.baselineKg.map { $0 * decay.baselineMultiplier }
        if decay.resetsProgressionCounters {
            adjusted.repExtension = 0
            adjusted.extraSetsAdded = 0
        }
        if decay.restartsCalibration { adjusted.isInCalibration = true }
        return adjusted
    }

    // MARK: - Упражнение: классы для w8/w9 и порядка

    static let compoundPatterns: Set<Pattern> = [.squat, .hinge, .lunge, .pushH, .pushV, .pullH, .pullV]

    /// «Технически сложная база» (§7.3): многосуставный паттерн и skill_level выше
    /// novice. Тренажёры и блок (`machine`, `cable`) сюда не входят —
    /// задокументированный выбор, не буква SPEC: таблица `block_mismatch` штрафует
    /// только базу, а §7.5 держит `load_type` в срезе ровно затем, чтобы отличить
    /// тренажёры от свободного веса в этом слагаемом. Без исключения жим ногами в
    /// тренажёре штрафовался бы в разгрузочном блоке, который тренажёры и просит.
    static func isTechnicalBase(_ c: ExerciseCandidate) -> Bool {
        compoundPatterns.contains(c.pattern) && c.skillLevel > .novice && c.loadType != .machine && c.loadType != .cable
    }

    static func blockMismatch(_ c: ExerciseCandidate, block: BlockType) -> Double {
        switch block {
        case .recovery, .deload: return isTechnicalBase(c) ? 1 : 0
        case .strength: return c.pattern == .isolation ? 1 : 0
        case .peak, .volumeAccumulation, .neutral: return 0
        }
    }

    /// Повторы и базовый RIR цели (§9.1).
    static func goalTable(_ goal: Goal) -> (reps: ClosedRange<Int>, rir: ClosedRange<Int>) {
        switch goal {
        case .strength: return (4...6, 1...2)
        case .hypertrophy: return (8...12, 1...2)
        case .toning, .general: return (10...15, 2...3)
        case .endurance: return (15...20, 2...3)
        }
    }

    /// Числа одного упражнения (§7.3 «Повторы и RIR», §7.6): целевой RIR,
    /// готовность к весу, предписанный вес и действующий диапазон повторов.
    ///
    /// Вынесено из тела сборки не ради краткости, а затем, чтобы у `prescribe`
    /// (§20.3) не появилось второй реализации этих формул. Разойдясь, две копии
    /// дали бы пользовательнице разные веса на карточке дня и на экране
    /// тренировки, причём ни один тест §18 этого не увидел бы: он сверяет
    /// сборку саму с собой.
    ///
    /// `state` — состояние ПОСЛЕ сбросов §9.7 (`stateForSession`), а
    /// `storedBaseline` — сырая хранимая базовая линия: направление округления
    /// сравнивается именно с ней, иначе срез детренированности сам себя
    /// округлял бы вверх.
    static func exerciseNumbers(
        _ c: ExerciseCandidate,
        state: ExerciseState?,
        storedBaseline: Double?,
        input: SessionInput
    ) -> (rir: Int, weightReadiness: Double, prescribedKg: Double?, reps: ClosedRange<Int>) {
        let table = goalTable(input.goal)
        let baseRIR = input.safety.level == .novice ? table.rir.upperBound : table.rir.lowerBound
        let adjustments = c.loadedMuscles.map { Recovery.adjustment(forFatigue: input.fatigue[$0] ?? 0) }
        let fatigueBump = adjustments.map(\.targetRIRDelta).max() ?? 0
        let rir = Readiness.targetRIR(baseRIR: baseRIR, readiness: input.readiness,
                                      cycleState: input.cycleState, fatigueRIRBump: fatigueBump)
            + (input.safety.isConservative ? 1 : 0)
        let wr = Readiness.weightReadiness(readiness: input.readiness, contributingMuscleAdjustments: adjustments)
        var kg: Double?
        if let state, !state.isInCalibration, let baseline = state.baselineKg {
            // Направление округления SPEC не задаёт — задокументированный выбор
            // по прецеденту SetReaction: вниз, если итог ниже хранимой базовой
            // линии (срез готовности или детренированности), вверх — если выше.
            // Калибровка веса не предписывает (§9.8).
            let ladder = WeightLadder.build(loadType: c.loadType, profile: input.equipment)
            let raw = baseline * wr
            kg = ladder.roundToAchievable(raw, direction: raw < (storedBaseline ?? baseline) ? .down : .up)
        }
        // Диапазон — через repRange, а не по месту: та же функция заполняет
        // exercise_states.current_rep_* и строит дерево §20.9 (SPEC §9.1,
        // §20.15 тест 20c). Инлайн той же формулы означал бы, что «один
        // источник на три места» верно только пока три копии совпадают.
        return (rir, wr, kg, repRange(goal: input.goal, state: state))
    }

    /// Диапазон цели без расширения — то, что функции Progression принимают как
    /// `baseRange` (SPEC §9.1). Именно он идёт в `rebuildStates`: расширение —
    /// результат свёртки, и подавать его на вход значило бы учесть дважды.
    public static func baseRepRange(goal: Goal) -> ClosedRange<Int> {
        goalTable(goal).reps
    }

    /// Целевой диапазон повторов упражнения: таблица цели (§9.1) с наложенным
    /// `rep_extension` (§9.5).
    ///
    /// **Один источник на три места** (SPEC §9.1): запись
    /// `workout_exercises.target_rep_min`/`target_rep_max`, построение дерева
    /// решений §20.9 и заполнение
    /// `exercise_states.current_rep_min`/`current_rep_max`. Второй реализации
    /// формулы нет ни на сервере, ни во фронтенде — расхождение дерева с
    /// предписанием тест 20c по построению не поймал бы: он сверяет дерево с
    /// `nextSet` на ОДНОМ И ТОМ ЖЕ диапазоне и потому слеп к его выбору.
    ///
    /// **`state` — то состояние, которое реально использует сборка**, то есть
    /// уже после `stateForSession` (детренированность §9.7 обнуляет
    /// `repExtension` на перерыве от 22 дней). Сырое хранимое `exercise_states`
    /// подавать сюда нельзя: после 30 дней перерыва оно даёт `8...15` там, где
    /// сессия предписывает `8...12`, и в колонки легло бы число, которого
    /// пользовательница не видела.
    ///
    /// `nil` — упражнение без состояния (журнала ещё нет): расширения тоже нет,
    /// результат равен `baseRepRange`.
    public static func repRange(goal: Goal, state: ExerciseState?) -> ClosedRange<Int> {
        let base = goalTable(goal).reps
        return base.lowerBound...(base.upperBound + (state?.repExtension ?? 0))
    }

    // MARK: - Перестановка по seed

    /// SplitMix64 — детерминированный и без Foundation.
    struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Ранг слага для ничьих — hash(seed, slug), у каждого упражнения свой и
    /// независимый от остальной библиотеки: добавление или удаление чужого
    /// упражнения не перерешивает ничьи между оставшимися (иначе обновление
    /// контента давало бы «План обновлён» без причины, §7.1). От порядка
    /// входного среза ранг тоже не зависит (сценарий 33a). Совпадение хешей
    /// разрешается слагом при сравнении (`rankLess`).
    static func ranks(for slugs: [String], seed: UInt64) -> [String: UInt64] {
        Dictionary(Set(slugs).map { ($0, rank(slug: $0, seed: seed)) }, uniquingKeysWith: { first, _ in first })
    }

    static func rank(slug: String, seed: UInt64) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325          // FNV-1a 64
        for byte in slug.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        var rng = SplitMix64(state: seed ^ hash)
        return rng.next()
    }
}

// MARK: - Сборщик

private let muscles = MuscleSlug.allCases
private let muscleCount = muscles.count
private let muscleIndex: [MuscleSlug: Int] = Dictionary(uniqueKeysWithValues: muscles.enumerated().map { ($1, $0) })

private struct PoolItem {
    let candidate: ExerciseCandidate
    let rank: UInt64
    /// Эффективный вклад по индексу мышцы.
    let effective: [Double]
    /// w4 + w6 + w7 + (w8, w9 с потолком) — не зависит от подходов.
    let staticPenalty: Double
    /// Σ вклад × fatigue_cost × утомление[m] на один подход (без w5).
    let fatiguePerSet: Double
    let serving: Bool
    let hasFatiguedMuscle: Bool
    let worstVolumeMultiplier: Double
}

private struct Builder {
    let input: SessionInput
    let day: PlannedDay
    let scale: Double
    let pool: [PoolItem]
    let vectorIdx: [(Int, Double)]
    let maxShare: Double
    let weekDone: [Double]
    let ceilings: [Double]
    let remaining: [Double]
    let restFactor: Double
    let budget: Double?
    let compositionTarget: [Double]
    let setTarget: [Double]
    let w: PlannerWeights
    /// Состояния прогрессии на дату дня — с детренированностью (§9.7).
    let states: [String: ExerciseState]

    init(input: SessionInput, day: PlannedDay, scale: Double) {
        self.input = input
        self.day = day
        self.scale = scale
        self.w = input.weights
        let w = input.weights
        let level = input.safety.level

        var vm = [Double](repeating: 1, count: muscleCount)
        var severity = [Double](repeating: 0, count: muscleCount)
        for (m, f) in input.fatigue {
            let adj = Recovery.adjustment(forFatigue: f)
            vm[muscleIndex[m]!] = adj.volumeMultiplier
            severity[muscleIndex[m]!] = (1 - adj.volumeMultiplier) / Recovery.maxVolumeCut
        }

        var done = [Double](repeating: 0, count: muscleCount)
        for (m, v) in input.weekDone { done[muscleIndex[m]!] = v }
        weekDone = done
        ceilings = muscles.map { Planner.ceiling($0, in: day, level: level) }
        vectorIdx = muscles.enumerated().compactMap { i, m in
            guard let s = day.vector[m], s > 0 else { return nil }
            return (i, s)
        }
        maxShare = day.vector.values.max() ?? 1
        remaining = muscles.map { m in
            Double(input.week[input.dayIndex...].filter { $0.isStrength && ($0.vector[m] ?? 0) > 0 }.count)
        }
        restFactor = Planner.restFactor(readiness: input.readiness)
        budget = input.sessionMinutes.map { Double($0) * 60 }

        let planned = Readiness.plannedVolumeFactor(cycleState: input.cycleState, isDeloadWeek: input.isDeloadWeek)
        compositionTarget = Builder.targets(day: day, scale: scale, planned: 1.0, vm: vm, weekDone: done, ceilings: ceilings)
        setTarget = Builder.targets(day: day, scale: scale, planned: planned, vm: vm, weekDone: done, ceilings: ceilings)

        var dayStates: [String: ExerciseState] = [:]
        for c in input.library {
            guard let state = input.exerciseStates[c.slug] else { continue }
            dayStates[c.slug] = Planner.stateForSession(
                state, ladder: WeightLadder.build(loadType: c.loadType, profile: input.equipment), on: day.date)
        }
        states = dayStates

        let slugRanks = Planner.ranks(for: input.library.map(\.slug), seed: input.seed)
        let block = input.cycleState.periodization?.blockType ?? .neutral
        let vectorSet = Set(day.vector.filter { $0.value > 0 }.keys)
        var items: [PoolItem] = []
        var seen = Set<String>()
        for c in input.library where seen.insert(c.slug).inserted {
            guard Planner.passesHardConstraints(c, safety: input.safety, availability: input.availability,
                                                equipment: input.equipment, on: day.date) else { continue }
            var eff = [Double](repeating: 0, count: muscleCount)
            for (m, v) in c.effectiveContributions { eff[muscleIndex[m]!] = v }

            let state = dayStates[c.slug]
            let noBaseline = state == nil || state!.isInCalibration
            var bias = 0.0
            if let phase = input.cycleState.phase, let confidence = input.cycleState.cycleConfidence {
                bias = abs(Cycle.exerciseBias(phase: phase, cycleConfidence: confidence, impact: c.impact).value)
            }
            let complexity = Planner.isTechnicalBase(c) && input.readiness < Planner.lowReadinessThreshold ? 1.0 : 0.0
            let preference = min(w.w8 * Planner.blockMismatch(c, block: block) + w.w9 * complexity,
                                 max(w.w8, w.w9))
            let staticPenalty = w.w4 * (noBaseline ? 1 : 0)
                + w.w6 * (input.previousWorkoutSlugs.contains(c.slug) ? 1 : 0)
                + w.w7 * bias
                + preference

            var fatiguePerSet = 0.0
            var worst = 1.0
            for (m, share) in c.muscleContributions where share > 0 {
                let i = muscleIndex[m]!
                fatiguePerSet += share * c.fatigueCost * severity[i]
                worst = min(worst, vm[i])
            }
            items.append(PoolItem(
                candidate: c, rank: slugRanks[c.slug]!, effective: eff,
                staticPenalty: staticPenalty, fatiguePerSet: fatiguePerSet,
                serving: c.muscleContributions.contains { vectorSet.contains($0.key) && $0.value > 0 },
                hasFatiguedMuscle: worst < 1.0, worstVolumeMultiplier: worst
            ))
        }
        pool = items.sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.candidate.slug < $1.candidate.slug }
    }

    /// Цель сессии по мышцам (§7.3, «Объём сессии» и «Освободившийся объём»):
    /// `S_эфф × доля × volumeFactor`, не выше остатка до потолка; срезанное
    /// утомлением и потолком раскладывается по свежим мышцам вектора
    /// пропорционально долям и не выше их остатка. Один проход, без повторного
    /// распределения того, что упёрлось в потолок у получателя, —
    /// задокументированный выбор: SPEC порядка не задаёт, а второй проход
    /// раздал бы объём мышцам, которые вектор дня не просит.
    static func targets(day: PlannedDay, scale: Double, planned: Double, vm: [Double],
                        weekDone: [Double], ceilings: [Double]) -> [Double] {
        var target = [Double](repeating: 0, count: muscleCount)
        var freed = 0.0
        var freshShare = 0.0
        for (i, m) in muscles.enumerated() {
            guard let share = day.vector[m], share > 0 else { continue }
            let reference = scale * share * planned
            let factor = Readiness.volumeFactor(plannedFactor: planned, fatigueFactor: vm[i])
            let room = max(0, ceilings[i] - weekDone[i])
            let t = min(scale * share * factor, room)
            target[i] = t
            freed += max(0, reference - t)
            if vm[i] >= 1 { freshShare += share }
        }
        guard freed > 0, freshShare > 0 else { return target }
        for (i, m) in muscles.enumerated() {
            guard let share = day.vector[m], share > 0, vm[i] >= 1 else { continue }
            let room = max(0, ceilings[i] - weekDone[i]) - target[i]
            target[i] += max(0, min(freed * share / freshShare, room))
        }
        return target
    }

    // MARK: Score

    func score(_ sel: [Int], _ sets: [Int], target: [Double]) -> Double {
        var fact = [Double](repeating: 0, count: muscleCount)
        var penalty = 0.0
        var patternCount: [Pattern: Int] = [:]
        for (k, p) in sel.enumerated() {
            let item = pool[p]
            let n = Double(sets[k])
            for i in 0..<muscleCount where item.effective[i] > 0 { fact[i] += n * item.effective[i] }
            penalty += item.staticPenalty + w.w5 * n * item.fatiguePerSet
            patternCount[item.candidate.pattern, default: 0] += 1
        }
        var distance = 0.0
        var over = 0.0
        for i in 0..<muscleCount {
            distance += abs(fact[i] - target[i])
            if fact[i] > 0 { over += max(0, weekDone[i] + fact[i] - ceilings[i]) }
        }
        let crowding = patternCount.values.reduce(0.0) { $0 + Double(max(0, $1 - 2)) }
        var coverage = 0.0
        for (i, share) in vectorIdx {
            let ratio = share / maxShare
            coverage += ratio * ratio * ratio * max(0, 1 - weekDone[i] - fact[i]) / max(1, remaining[i])
        }
        return -(w.w1 * distance + w.w2 * over + w.w3 * crowding
                 + penalty + w.w11 * coverage)
    }

    // MARK: Порядок и время

    /// Порядок сессии (§7.3): многосуставные по убыванию fatigue_cost, потом
    /// изоляция и кор; ничьи — по рангу seed. Акцентная мышца получает
    /// упражнение в первой половине: если ни одно из первых ⌈n/2⌉ не ведёт
    /// акцентную мышцу, первое такое переносится на последнее место первой
    /// половины — задокументированный выбор, SPEC способ не задаёт.
    func order(_ sel: [Int]) -> [Int] {
        var ordered = sel.sorted { a, b in
            let ca = pool[a].candidate, cb = pool[b].candidate
            let ta = Planner.compoundPatterns.contains(ca.pattern) || ca.pattern == .carry ? 0 : 1
            let tb = Planner.compoundPatterns.contains(cb.pattern) || cb.pattern == .carry ? 0 : 1
            if ta != tb { return ta < tb }
            if ca.fatigueCost != cb.fatigueCost { return ca.fatigueCost > cb.fatigueCost }
            return rankLess(a, b)
        }
        if let accent = day.accent, ordered.count > 1 {
            let half = (ordered.count + 1) / 2
            let leads = { (p: Int) in self.pool[p].candidate.leadingMuscle == accent }
            if !ordered[..<half].contains(where: leads), let j = ordered.firstIndex(where: leads) {
                let moved = ordered.remove(at: j)
                ordered.insert(moved, at: half - 1)
            }
        }
        return ordered
    }

    func seconds(_ sel: [Int], _ sets: [Int]) -> Double {
        TimeModel(builder: self, sel: sel).seconds(sets)
    }

    func fits(_ sel: [Int], _ sets: [Int]) -> Bool {
        guard budget != nil else { return true }
        return TimeModel(builder: self, sel: sel).fits(sets)
    }

    /// Время набора — линейная функция подходов при фиксированном составе:
    /// порядок (а с ним «последнее упражнение») зависит только от состава, и в
    /// раскладке подходов он считается один раз, а не на каждой пробе.
    struct TimeModel {
        let constant: Double
        let perSet: [Double]
        let budget: Double?

        init(builder: Builder, sel: [Int]) {
            budget = builder.budget
            var perSet = [Double](repeating: 0, count: sel.count)
            var constant = 0.0
            for (k, p) in sel.enumerated() {
                let c = builder.pool[p].candidate
                constant += Double(c.setupSeconds)
                perSet[k] = Planner.workSecondsPerSet * (c.unilateral ? 2 : 1)
                    + Double(c.defaultRestSeconds) * builder.restFactor
            }
            if let last = builder.order(sel).last {
                constant -= Double(builder.pool[last].candidate.defaultRestSeconds) * builder.restFactor
            }
            self.constant = constant
            self.perSet = perSet
        }

        func seconds(_ sets: [Int]) -> Double {
            guard !perSet.isEmpty else { return 0 }
            var total = constant
            for k in perSet.indices { total += Double(sets[k]) * perSet[k] }
            return total
        }

        func fits(_ sets: [Int]) -> Bool {
            guard let budget else { return true }
            return seconds(sets) <= budget + 1e-9
        }
    }

    // MARK: Раскладка подходов (§7.3, шаги 1–3)

    func allocate(_ sel: [Int], target: [Double], requiredPatterns: Int?) -> (sel: [Int], sets: [Int], score: Double)? {
        var sel = sel
        var sets = [Int](repeating: Planner.minSetsPerExercise, count: sel.count)
        let time = TimeModel(builder: self, sel: sel)
        guard time.fits(sets) else { return nil }
        var current = score(sel, sets, target: target)
        while true {
            var best: (score: Double, k: Int)?
            for k in sel.indices where sets[k] < Planner.maxSetsPerExercise {
                sets[k] += 1
                if time.fits(sets) {
                    let s = score(sel, sets, target: target)
                    if best == nil || s > best!.score + Planner.scoreTolerance
                        || (abs(s - best!.score) <= Planner.scoreTolerance && rankLess(sel[k], sel[best!.k])) {
                        best = (s, k)
                    }
                }
                sets[k] -= 1
            }
            guard let b = best, b.score > current + Planner.scoreTolerance else { break }
            sets[b.k] += 1
            current = b.score
        }
        if let required = requiredPatterns {
            // Шаг 3: объём не принимает минимум — снимается упражнение на
            // минимуме, снятие которого улучшает score; пока их больше трёх и
            // держится минимум паттернов.
            while sel.count > 3 {
                var best: (score: Double, k: Int)?
                for k in sel.indices where sets[k] == Planner.minSetsPerExercise {
                    var s2 = sel, n2 = sets
                    s2.remove(at: k); n2.remove(at: k)
                    guard servingPatterns(s2) >= required else { continue }
                    let s = score(s2, n2, target: target)
                    if best == nil || s > best!.score + Planner.scoreTolerance
                        || (abs(s - best!.score) <= Planner.scoreTolerance && rankLess(sel[k], sel[best!.k])) {
                        best = (s, k)
                    }
                }
                guard let b = best, b.score > current + Planner.scoreTolerance else { break }
                sel.remove(at: b.k); sets.remove(at: b.k)
                current = b.score
            }
        }
        return (sel, sets, current)
    }

    func servingPatterns(_ sel: [Int]) -> Int {
        Set(sel.filter { pool[$0].serving }.map { pool[$0].candidate.pattern }).count
    }

    func familyAllows(_ sel: [Int], adding p: Int) -> Bool {
        let family = pool[p].candidate.progressionFamily
        return sel.filter { pool[$0].candidate.progressionFamily == family }.count < 2
    }

    /// Порядок ничьих: ранг, при совпадении хешей — слаг.
    func rankLess(_ a: Int, _ b: Int) -> Bool {
        let ra = pool[a].rank, rb = pool[b].rank
        return ra != rb ? ra < rb : pool[a].candidate.slug < pool[b].candidate.slug
    }

    /// Почему ремонт не добрал паттерны. Время — если хоть один кандидат нового
    /// паттерна проходит семейный лимит, но не влезает в бюджет: тогда тап по
    /// session_minutes помогает. Иначе — семь упражнений, иначе — семьи.
    func patternShortfallReason(_ sel: [Int], fitted: Int) -> ReasonCode {
        let have = Set(sel.filter { pool[$0].serving }.map { pool[$0].candidate.pattern })
        let fresh = pool.indices.filter { !sel.contains($0) && pool[$0].serving && !have.contains(pool[$0].candidate.pattern) }
        if sel.count < Planner.maxExercises, fresh.contains(where: { familyAllows(sel, adding: $0) }) {
            return .patternMinimumRelaxedByTime(fitted: fitted)
        }
        if sel.count >= Planner.maxExercises {
            return .patternMinimumRelaxedByLimit(fitted: fitted, limit: .exerciseCount)
        }
        return .patternMinimumRelaxedByLimit(fitted: fitted, limit: .family)
    }

    func better(_ s: Double, candidate p: Int, than best: (score: Double, p: Int)?) -> Bool {
        guard let best else { return true }
        if s > best.score + Planner.scoreTolerance { return true }
        return abs(s - best.score) <= Planner.scoreTolerance && rankLess(p, best.p)
    }

    // MARK: Сборка

    mutating func build() -> BuiltSession {
        var sel: [Int] = []
        var current = score([], [], target: compositionTarget)
        var reasons: [ReasonCode] = []

        // Жадный шаг.
        while sel.count < Planner.maxExercises {
            var best: (score: Double, p: Int)?
            for p in pool.indices where !sel.contains(p) && familyAllows(sel, adding: p) {
                guard let a = allocate(sel + [p], target: compositionTarget, requiredPatterns: nil) else { continue }
                if better(a.score, candidate: p, than: best.map { ($0.score, $0.p) }) {
                    best = (a.score, p)
                }
            }
            guard let b = best, b.score > current + Planner.scoreTolerance else { break }
            sel.append(b.p)
            current = b.score
        }

        // Ремонт паттернов. Кандидат обязан влезать в бюджет: если три паттерна
        // помещаются, ослабления нет. Расхождение со SPEC §7.3 и §18 (29a), не
        // исправленное в спеке: «14 минут → два упражнения и два паттерна, 8 →
        // одно» дал прототип без этой проверки; на той же библиотеке при 14
        // минутах три паттерна занимают 12.8 минуты, при 8 собираются два
        // упражнения одного паттерна (см. test_scenario29a).
        let available = Set(pool.filter(\.serving).map(\.candidate.pattern)).count
        let required = min(3, available)
        while servingPatterns(sel) < required, sel.count < Planner.maxExercises {
            let have = Set(sel.filter { pool[$0].serving }.map { pool[$0].candidate.pattern })
            var best: (score: Double, p: Int)?
            for p in pool.indices where !sel.contains(p) && pool[p].serving
                && !have.contains(pool[p].candidate.pattern) && familyAllows(sel, adding: p) {
                guard let a = allocate(sel + [p], target: compositionTarget, requiredPatterns: nil) else { continue }
                if better(a.score, candidate: p, than: best.map { ($0.score, $0.p) }) {
                    best = (a.score, p)
                }
            }
            guard let b = best else { break }
            sel.append(b.p)
            current = b.score
        }
        let achieved = servingPatterns(sel)
        if available == 0 {
            // Пул пуст: жёсткие ограничения §7.3 не пропустили ничего. Это и есть
            // причина, а «ослаблен минимум паттернов до нуля» — её следствие.
            reasons.append(.noFeasibleExercises)
        } else {
            if available < 3 { reasons.append(.patternMinimumRelaxedUnavailable(available: available)) }
            if achieved < required { reasons.append(patternShortfallReason(sel, fitted: achieved)) }
        }

        // Локальное улучшение: замена на упражнение того же паттерна из среза.
        for _ in 0..<Planner.maxImprovementPasses {
            var best: (score: Double, k: Int, p: Int)?
            for k in sel.indices {
                let rest = sel.enumerated().filter { $0.offset != k }.map(\.element)
                for p in pool.indices where !sel.contains(p)
                    && pool[p].candidate.pattern == pool[sel[k]].candidate.pattern
                    && familyAllows(rest, adding: p) {
                    var trial = sel
                    trial[k] = p
                    guard servingPatterns(trial) >= achieved,
                          let a = allocate(trial, target: compositionTarget, requiredPatterns: nil),
                          a.score > current + Planner.scoreTolerance else { continue }
                    if better(a.score, candidate: p, than: best.map { ($0.score, $0.p) }) {
                        best = (a.score, k, p)
                    }
                }
            }
            guard let b = best else { break }
            sel[b.k] = b.p
            current = b.score
        }

        // Шаг 3 — снятие упражнений на минимуме — против цели БЕЗ равномерного
        // среза (фаза, разгрузочная неделя), как и весь подбор состава. Утомление
        // в этой цели есть, и глубокий неравномерный срез упражнение снять
        // вправе (§8.3, п.3); равномерный — нет: он уже режет подходы ниже, и
        // снятие упражнения учло бы тот же срез второй раз (сценарий 31a).
        // SPEC §7.3 не называет, против какой цели работает шаг 3, —
        // задокументированный выбор.
        var removedAtMinimum: [String] = []
        if let pruned = allocate(sel, target: compositionTarget, requiredPatterns: achieved) {
            removedAtMinimum = sel.filter { !pruned.sel.contains($0) }.map { pool[$0].candidate.slug }
            sel = pruned.sel
        }

        // Целые подходы по цели С плановым срезом (шаги 1–2), состав уже зафиксирован.
        var sets: [Int] = []
        if let a = allocate(sel, target: setTarget, requiredPatterns: nil) {
            sets = a.sets
        } else {
            sel = []
        }

        // Шаг 4: добавленные подходы §9.5 — потолок пяти и бюджет действуют и на них.
        var ordered = order(sel)
        var setsBy = Dictionary(uniqueKeysWithValues: zip(sel, sets))
        func orderedSets() -> [Int] { ordered.map { setsBy[$0]! } }
        for p in ordered {
            let extra = states[pool[p].candidate.slug]?.extraSetsAdded ?? 0
            for _ in 0..<max(0, extra) {
                guard setsBy[p]! < Planner.maxSetsPerExercise else { break }
                setsBy[p]! += 1
                if !fits(ordered, orderedSets()) { setsBy[p]! -= 1; break }
            }
        }

        // Шаг 5: ±1 подход на сессию по дневной готовности (§10).
        switch Readiness.sessionSetDelta(readiness: input.readiness) {
        case 1:
            // Подходящие упражнения перебираются тем же выбором Readiness: не
            // принявшее подход (потолок пяти или бюджет) маскируется, и выбор
            // повторяется. +1 пропадает, только если подходящих не осталось (§10).
            // Потолок пяти подходов держится и здесь — задокументированный
            // выбор: шаг 5 SPEC называет только бюджет, но потолок §7.3
            // сформулирован для упражнения, а не для шагов 2 и 4.
            _ = Planner.placeSessionSetIncrease(hasFatiguedMuscle: ordered.map { pool[$0].hasFatiguedMuscle }) { k in
                let p = ordered[k]
                guard setsBy[p]! < Planner.maxSetsPerExercise else { return false }
                setsBy[p]! += 1
                if fits(ordered, orderedSets()) { return true }
                setsBy[p]! -= 1
                return false
            }
        case -1:
            if let k = Readiness.exerciseForSessionSetDecrease(worstVolumeMultiplier: ordered.map { pool[$0].worstVolumeMultiplier }) {
                let p = ordered[k]
                if setsBy[p]! > 1 { setsBy[p]! -= 1 }   // до нуля не сокращается — поправка пропускается
            }
        default:
            break
        }

        ordered = order(ordered)
        let finalSets = orderedSets()

        // Числа упражнения (§7.3 «Повторы и RIR», §7.6) — одной функцией на
        // сборку и на пересчёт §20.3, состояние берётся после stateForSession.
        var exercises: [PrescribedExercise] = []
        var volumeItems: [(ExerciseCandidate, Int)] = []
        for (index, p) in ordered.enumerated() {
            let c = pool[p].candidate
            let n = Planner.exerciseNumbers(c, state: states[c.slug],
                                            storedBaseline: input.exerciseStates[c.slug]?.baselineKg,
                                            input: input)
            exercises.append(PrescribedExercise(
                slug: c.slug, orderIndex: index, targetSets: finalSets[index],
                targetRepMin: n.reps.lowerBound,
                targetRepMax: n.reps.upperBound,
                targetRIR: n.rir, prescribedKg: n.prescribedKg, weightReadiness: n.weightReadiness
            ))
            volumeItems.append((c, finalSets[index]))
        }

        let planned = Readiness.plannedVolumeFactor(cycleState: input.cycleState, isDeloadWeek: input.isDeloadWeek)
        if planned != 1.0, let reason = input.cycleState.periodization?.reason { reasons.append(reason) }
        if let phase = input.cycleState.phase, let confidence = input.cycleState.cycleConfidence,
           ordered.contains(where: { Cycle.exerciseBias(phase: phase, cycleConfidence: confidence, impact: pool[$0].candidate.impact).value != 0 }),
           let reason = Cycle.exerciseBias(phase: phase, cycleConfidence: confidence, impact: .high).reason {
            reasons.append(reason)
        }

        return BuiltSession(
            dayID: day.id,
            exercises: exercises,
            estimatedSeconds: Planner.estimatedSeconds(volumeItems, restFactor: restFactor),
            effectiveVolume: Planner.effectiveVolume(volumeItems),
            leadingMuscle: nil,
            scale: scale,
            reasons: reasons,
            removedAtMinimum: removedAtMinimum
        )
    }
}
