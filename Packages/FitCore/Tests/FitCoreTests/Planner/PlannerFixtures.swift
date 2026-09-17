//  Синтетические фикстуры планировщика (planner-domain §4). Не копия будущего
//  контента FitContent: каждое упражнение собрано, чтобы задеть конкретное
//  ограничение или сценарий, и тест проверяет алгоритм, а не разметку.
//
//  Лежат в FitCoreTests, а не в FitTestSupport: через FitTestSupport в граф
//  FitCore попал бы FitContent (planner-domain §4).
//
//  Зачем какое упражнение:
//  - резинки и собственный вес на низ — сценарий 28 (инвентарь «только резинки»);
//  - goblet/band squat, step-up, box jump — квадрицепс с нагрузкой на колено,
//    сценарий 30 (травма колена оставляет шарнирные и изоляцию);
//  - три упражнения семьи `hip_thrust` — «не более 2 из одной семьи»;
//  - box jump — `impact = high` (фазовый штраф w7) и skill intermediate;
//  - step-up — односторонний (сценарий 29b);
//  - hip thrust со штангой — большой `setup_seconds` и технически сложная база;
//  - верх и кор — плоский full body (27b) и упражнение «мимо цели» дня низа.

@testable import FitCore

enum PlannerFixtures {

    static let hipThrustBarbell = ExerciseCandidate(
        slug: "hip_thrust_barbell", pattern: .hinge,
        muscleContributions: [.gluteMax: 0.60, .hamstrings: 0.20, .quads: 0.10, .erectors: 0.10],
        equipment: [.benchFlat], jointStress: [.knee: .low, .lowerBack: .medium, .hip: .medium],
        skillLevel: .intermediate, progressionFamily: "hip_thrust", familyLoadRatio: 1.0,
        fatigueCost: 1.0, setupSeconds: 90, defaultRestSeconds: 120, loadType: .barbell)
    static let hipThrustBand = ExerciseCandidate(
        slug: "hip_thrust_band", pattern: .hinge,
        muscleContributions: [.gluteMax: 0.60, .hamstrings: 0.25, .erectors: 0.15],
        equipment: [.bands], jointStress: [.knee: .low, .hip: .low],
        progressionFamily: "hip_thrust", familyLoadRatio: 0.4,
        fatigueCost: 0.7, setupSeconds: 30, loadType: .band)
    static let gluteBridge = ExerciseCandidate(
        slug: "glute_bridge_bw", pattern: .hinge,
        muscleContributions: [.gluteMax: 0.65, .hamstrings: 0.25, .erectors: 0.10],
        jointStress: [.knee: .low],
        progressionFamily: "hip_thrust", familyLoadRatio: 0.3,
        fatigueCost: 0.6, setupSeconds: 20, loadType: .bodyweight)
    static let rdlBand = ExerciseCandidate(
        slug: "rdl_band", pattern: .hinge,
        muscleContributions: [.hamstrings: 0.50, .gluteMax: 0.40, .erectors: 0.10],
        equipment: [.bands], jointStress: [.lowerBack: .medium],
        progressionFamily: "rdl", fatigueCost: 0.8, setupSeconds: 30, loadType: .band)
    static let gobletSquat = ExerciseCandidate(
        slug: "goblet_squat", pattern: .squat,
        muscleContributions: [.quads: 0.50, .gluteMax: 0.30, .adductors: 0.10, .abs: 0.10],
        jointStress: [.knee: .medium],
        progressionFamily: "squat", familyLoadRatio: 1.0,
        fatigueCost: 1.0, setupSeconds: 45, loadType: .dumbbell)
    static let bandSquat = ExerciseCandidate(
        slug: "band_squat", pattern: .squat,
        muscleContributions: [.quads: 0.45, .gluteMax: 0.35, .adductors: 0.20],
        equipment: [.bands], jointStress: [.knee: .medium],
        progressionFamily: "squat", familyLoadRatio: 0.5,
        fatigueCost: 0.9, setupSeconds: 30, loadType: .band)
    static let stepUp = ExerciseCandidate(
        slug: "step_up", pattern: .lunge,
        muscleContributions: [.quads: 0.40, .gluteMax: 0.40, .gluteMed: 0.15, .hamstrings: 0.05],
        jointStress: [.knee: .medium], impact: .low,
        progressionFamily: "lunge", fatigueCost: 0.9, setupSeconds: 40, unilateral: true, loadType: .bodyweight)
    static let boxJump = ExerciseCandidate(
        slug: "box_jump", pattern: .squat,
        muscleContributions: [.quads: 0.40, .gluteMax: 0.30, .calves: 0.20, .hamstrings: 0.10],
        jointStress: [.knee: .high, .ankle: .medium], impact: .high, skillLevel: .intermediate,
        progressionFamily: "jump", fatigueCost: 1.1, setupSeconds: 20, loadType: .bodyweight)
    static let bandAbduction = ExerciseCandidate(
        slug: "band_abduction", pattern: .isolation,
        muscleContributions: [.gluteMed: 0.80, .gluteMax: 0.20],
        equipment: [.bands], jointStress: [.knee: .low],
        progressionFamily: "abduction", fatigueCost: 0.6, setupSeconds: 20, defaultRestSeconds: 60, loadType: .band)
    static let legCurlBand = ExerciseCandidate(
        slug: "leg_curl_band", pattern: .isolation,
        muscleContributions: [.hamstrings: 1.0],
        equipment: [.bands], jointStress: [.knee: .low],
        progressionFamily: "leg_curl", fatigueCost: 0.6, setupSeconds: 20, defaultRestSeconds: 60, loadType: .band)
    static let calfRaise = ExerciseCandidate(
        slug: "calf_raise_bw", pattern: .isolation,
        muscleContributions: [.calves: 1.0], jointStress: [.ankle: .low],
        progressionFamily: "calf", fatigueCost: 0.5, setupSeconds: 15, defaultRestSeconds: 60, loadType: .bodyweight)

    static let dbRow = ExerciseCandidate(
        slug: "db_row", pattern: .pullH,
        muscleContributions: [.lats: 0.45, .trapsMid: 0.25, .rearDelts: 0.15, .biceps: 0.15],
        jointStress: [.shoulder: .low],
        progressionFamily: "row", fatigueCost: 1.0, setupSeconds: 30, loadType: .dumbbell)
    static let dbBench = ExerciseCandidate(
        slug: "db_bench", pattern: .pushH,
        muscleContributions: [.pecs: 0.55, .triceps: 0.25, .frontDelts: 0.20],
        equipment: [.benchFlat], jointStress: [.shoulder: .medium],
        progressionFamily: "bench", fatigueCost: 1.0, setupSeconds: 40, loadType: .dumbbell)
    static let pushup = ExerciseCandidate(
        slug: "pushup", pattern: .pushH,
        muscleContributions: [.pecs: 0.50, .triceps: 0.20, .frontDelts: 0.20, .abs: 0.10],
        jointStress: [.wrist: .medium],
        progressionFamily: "pushup", fatigueCost: 0.8, setupSeconds: 20, loadType: .bodyweight)
    static let bandPulldown = ExerciseCandidate(
        slug: "band_pulldown", pattern: .pullV,
        muscleContributions: [.lats: 0.60, .biceps: 0.25, .rearDelts: 0.15],
        equipment: [.bands, .pullupBar], jointStress: [.shoulder: .low],
        progressionFamily: "pulldown", fatigueCost: 0.8, setupSeconds: 30, loadType: .band)
    static let facePull = ExerciseCandidate(
        slug: "band_face_pull", pattern: .isolation,
        muscleContributions: [.trapsMid: 0.50, .rearDelts: 0.40, .biceps: 0.10],
        equipment: [.bands], jointStress: [.shoulder: .low],
        progressionFamily: "face_pull", fatigueCost: 0.4, setupSeconds: 20, defaultRestSeconds: 60, loadType: .band)
    static let lateralRaise = ExerciseCandidate(
        slug: "db_lateral_raise", pattern: .isolation,
        muscleContributions: [.sideDelts: 0.85, .trapsUpper: 0.15],
        jointStress: [.shoulder: .medium],
        progressionFamily: "lateral_raise", fatigueCost: 0.4, setupSeconds: 20, defaultRestSeconds: 60, loadType: .dumbbell)
    static let plank = ExerciseCandidate(
        slug: "plank", pattern: .core,
        muscleContributions: [.abs: 0.60, .obliques: 0.30, .erectors: 0.10],
        progressionFamily: "plank", fatigueCost: 0.3, setupSeconds: 15, defaultRestSeconds: 60, loadType: .bodyweight)

    static let lowerLibrary: [ExerciseCandidate] = [
        hipThrustBarbell, hipThrustBand, gluteBridge, rdlBand, gobletSquat, bandSquat,
        stepUp, boxJump, bandAbduction, legCurlBand, calfRaise,
    ]
    static let library: [ExerciseCandidate] = lowerLibrary + [dbRow, dbBench, pushup, bandPulldown, facePull, lateralRaise, plank]

    // MARK: - Векторы (примеры формы §7.3 и плоский full body)

    static let lowerGlutes: [MuscleSlug: Double] = [
        .gluteMax: 0.40, .hamstrings: 0.20, .quads: 0.18, .gluteMed: 0.10, .adductors: 0.06, .calves: 0.06,
    ]
    static let lower: [MuscleSlug: Double] = [
        .quads: 0.30, .gluteMax: 0.25, .hamstrings: 0.25, .gluteMed: 0.08, .adductors: 0.06, .calves: 0.06,
    ]
    static let upper: [MuscleSlug: Double] = [
        .pecs: 0.25, .lats: 0.25, .sideDelts: 0.12, .trapsMid: 0.10, .triceps: 0.08, .biceps: 0.08,
        .frontDelts: 0.06, .rearDelts: 0.06,
    ]
    static let flatFullBody: [MuscleSlug: Double] = Dictionary(uniqueKeysWithValues:
        [MuscleSlug.quads, .gluteMax, .hamstrings, .gluteMed, .pecs, .lats, .trapsMid, .sideDelts, .triceps, .abs]
            .map { ($0, 0.10) })

    // MARK: - Инвентарь и состояния

    static let fullAvailability = EquipmentAvailability(bench: .flat, pullupBar: true, bands: true)
    static let fullEquipment = EquipmentProfile(dumbbellsKg: [4, 6, 8, 10, 12], platesKg: [1.25, 2.5, 5, 10], barbellKg: 20)
    static let bandsOnly = EquipmentAvailability(bands: true)

    static let seed: UInt64 = 20_260_917

    static let noPhases = CycleState(
        phaseMode: .noPhases, noPhaseReason: .userChoice, hasAnchor: false, phase: nil,
        cycleConfidence: nil, periodization: nil, effectivePhaseAdjustment: nil)

    static func phaseState(_ phase: Phase, confidence: Double) -> CycleState {
        CycleState(
            phaseMode: .phases, noPhaseReason: nil, hasAnchor: true, phase: phase, cycleConfidence: confidence,
            periodization: Cycle.periodization(phase: phase, cycleConfidence: confidence),
            effectivePhaseAdjustment: Cycle.defaultReadinessAdjustment(for: phase))
    }

    /// Все упражнения знакомы — w4 не различает кандидатов.
    static let familiar: [String: ExerciseState] = Dictionary(uniqueKeysWithValues:
        library.map { ($0.slug, ExerciseState(baselineKg: nil, isInCalibration: false)) })

    static func day(_ n: Int) -> CalendarDay { CalendarDay(dayNumber: 20_000 + n) }

    /// Неделя из дней подряд, начиная с понедельника `day(0)`.
    static func week(_ specs: [(SessionKind, MuscleSlug?, [MuscleSlug: Double])], offsets: [Int]? = nil) -> [PlannedDay] {
        specs.enumerated().map { i, spec in
            PlannedDay(id: "day\(i)", date: day(offsets?[i] ?? i), kind: spec.0, accent: spec.1, vector: spec.2)
        }
    }

    static func input(
        week: [PlannedDay],
        dayIndex: Int = 0,
        library: [ExerciseCandidate] = PlannerFixtures.library,
        availability: EquipmentAvailability = fullAvailability,
        equipment: EquipmentProfile = fullEquipment,
        safety: SafetyProfile = SafetyProfile(level: .intermediate),
        goal: Goal = .hypertrophy,
        minutes: Int? = 60,
        fatigue: [MuscleSlug: Double] = [:],
        weekDone: [MuscleSlug: Double] = [:],
        previous: Set<String> = [],
        states: [String: ExerciseState] = familiar,
        cycleState: CycleState = noPhases,
        readiness: Double = 1.0,
        isDeloadWeek: Bool = false,
        weights: PlannerWeights = .spec
    ) -> SessionInput {
        SessionInput(
            week: week, dayIndex: dayIndex, library: library, availability: availability, equipment: equipment,
            safety: safety, goal: goal, sessionMinutes: minutes, fatigue: fatigue, weekDone: weekDone,
            previousWorkoutSlugs: previous, exerciseStates: states, cycleState: cycleState, readiness: readiness,
            isDeloadWeek: isDeloadWeek, seed: seed, weights: weights)
    }

    static func context(
        week: [PlannedDay],
        library: [ExerciseCandidate] = PlannerFixtures.library,
        availability: EquipmentAvailability = fullAvailability,
        equipment: EquipmentProfile = fullEquipment,
        states: [String: ExerciseState] = familiar,
        today: CalendarDay = day(0),
        started: Set<String> = [],
        completed: [CompletedWorkout] = [],
        fatigue: [MuscleSlug: FatigueState] = [:],
        minutes: Int = 45,
        cycle: CycleInputs = CycleInputs(events: [], profile: CycleProfile(phaseMode: .noPhases, noPhaseReason: .userChoice)),
        checkin: DailyCheckin = DailyCheckin(),
        override: Override? = nil,
        isDeloadWeek: Bool = false,
        weights: PlannerWeights = .spec
    ) -> WeekContext {
        WeekContext(
            weekStart: day(0), week: week, today: today, startedDayIDs: started, completed: completed,
            fatigue: fatigue, library: library, availability: availability, equipment: equipment,
            safety: SafetyProfile(level: .intermediate), goal: .hypertrophy, sessionMinutes: minutes,
            exerciseStates: states, cycle: cycle, todayCheckin: checkin, todayOverride: override,
            isDeloadWeek: isDeloadWeek, userSeed: seed, weights: weights)
    }

    static func candidate(_ slug: String) -> ExerciseCandidate {
        library.first { $0.slug == slug }!
    }

    /// Выполнить собранную сессию: запись в журнал и утомление (§8.1, фидбэк ok)
    /// в 18:00 дня.
    static func perform(
        _ session: BuiltSession,
        on date: CalendarDay,
        completed: inout [CompletedWorkout],
        fatigue: inout [MuscleSlug: FatigueState],
        plannedDayID: String? = nil,
        library: [ExerciseCandidate] = PlannerFixtures.library
    ) {
        let at = Timestamp(hoursSinceEpoch: Double(date.dayNumber) * 24 + 18)
        let sets = Dictionary(uniqueKeysWithValues: session.exercises.map { ($0.slug, $0.targetSets) })
        completed.append(CompletedWorkout(id: "w-\(date.dayNumber)-\(session.dayID)", plannedDayID: plannedDayID ?? session.dayID,
                                          date: date, performedAt: at, setsBySlug: sets))
        var fatigueSets: [FatigueSet] = []
        for e in session.exercises {
            let c = library.first { $0.slug == e.slug }!
            let load = c.muscleContributions.mapValues { $0 * c.fatigueCost }
            fatigueSets += Array(repeating: FatigueSet(muscleLoad: load, feedback: .ok), count: e.targetSets)
        }
        fatigue = Recovery.applying(fatigueSets, at: at, to: fatigue)
    }

    static func slugs(_ session: BuiltSession?) -> Set<String> {
        Set(session?.exercises.map(\.slug) ?? [])
    }
}
