//  Срез библиотеки упражнений, который читает планировщик (SPEC §7.5). Ровно
//  поля таблицы §7.5 — `name`, `cues`, `default_rep_range`,
//  `weight_increment_source` и прочее показывает и квантует не планировщик.
//  FitCore не зависит от FitContent: срез строит вызывающая сторона, как
//  `FatigueSet` для Recovery.

/// Требование `exercise.equipment` — закрытый словарь §6.6. Значения вне
/// словаря ловит валидатор, а не планировщик, поэтому их здесь не бывает.
public enum EquipmentRequirement: Sendable, Equatable, Hashable {
    case benchFlat
    case benchAdjustable
    case pullupBar
    case bands
    case kettlebells
    case cableMachine
    case machine(String)
}

public struct ExerciseCandidate: Sendable, Equatable {
    public var slug: String
    public var pattern: Pattern
    /// Сырые вклады, сумма ≈ 1.0 (§6.3). Утомление (§8.1) считается по ним,
    /// объём (§7.4) — по `effectiveContributions`.
    public var muscleContributions: [MuscleSlug: Double]
    public var equipment: [EquipmentRequirement]
    public var jointStress: [Joint: JointStressLevel]
    public var impact: ExerciseImpact
    public var skillLevel: ExperienceLevel
    public var progressionFamily: String
    public var familyLoadRatio: Double?
    public var fatigueCost: Double
    public var setupSeconds: Int
    public var defaultRestSeconds: Int
    public var unilateral: Bool
    public var loadType: LoadType
    public var alternatives: [String]

    public init(
        slug: String,
        pattern: Pattern,
        muscleContributions: [MuscleSlug: Double],
        equipment: [EquipmentRequirement] = [],
        jointStress: [Joint: JointStressLevel] = [:],
        impact: ExerciseImpact = .none,
        skillLevel: ExperienceLevel = .novice,
        progressionFamily: String,
        familyLoadRatio: Double? = nil,
        fatigueCost: Double,
        setupSeconds: Int,
        defaultRestSeconds: Int = 90,
        unilateral: Bool = false,
        loadType: LoadType,
        alternatives: [String] = []
    ) {
        self.slug = slug
        self.pattern = pattern
        self.muscleContributions = muscleContributions
        self.equipment = equipment
        self.jointStress = jointStress
        self.impact = impact
        self.skillLevel = skillLevel
        self.progressionFamily = progressionFamily
        self.familyLoadRatio = familyLoadRatio
        self.fatigueCost = fatigueCost
        self.setupSeconds = setupSeconds
        self.defaultRestSeconds = defaultRestSeconds
        self.unilateral = unilateral
        self.loadType = loadType
        self.alternatives = alternatives
    }

    /// Эффективный подход (SPEC §7.4): ведущей мышце — 1.0, остальным —
    /// вклад / максимальный вклад.
    public var effectiveContributions: [MuscleSlug: Double] {
        guard let top = muscleContributions.values.max(), top > 0 else { return [:] }
        return muscleContributions.compactMapValues { $0 > 0 ? $0 / top : nil }
    }

    /// Мышцы с ненулевым вкладом — «нагруженные» (§7.3, §10).
    public var loadedMuscles: [MuscleSlug] {
        MuscleSlug.allCases.filter { (muscleContributions[$0] ?? 0) > 0 }
    }

    /// Ведущая мышца упражнения; ничья — по порядку объявления `MuscleSlug`.
    public var leadingMuscle: MuscleSlug? {
        loadedMuscles.max { (muscleContributions[$0] ?? 0) < (muscleContributions[$1] ?? 0) }
    }
}
