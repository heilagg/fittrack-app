//  Синтетические упражнения и векторы для тестов валидатора.
//
//  Не черновик будущей разметки: каждое упражнение собрано так, чтобы задеть
//  одно правило, и числа здесь выбраны ради проверки правила, а не ради
//  физиологии. Настоящую разметку принимает специалист (§19.2 п.2), и копия её
//  в тестах ломалась бы при каждой переразметке (content-domain §4).

import FitCore
import FitContent

enum Fixtures {

    /// Полная карта суставов из одних `none` — минимум, который проходит §6.2.
    static func noStress(_ overrides: [Joint: JointStressLevel] = [:]) -> [Joint: JointStressLevel] {
        var map: [Joint: JointStressLevel] = [:]
        for joint in Joint.allCases { map[joint] = overrides[joint] ?? JointStressLevel.none }
        return map
    }

    static func exercise(
        _ slug: String,
        pattern: Pattern,
        contributions: [MuscleSlug: Double],
        equipment: [EquipmentRequirement] = [],
        loadType: LoadType = .bodyweight,
        jointStress: [Joint: JointStressLevel]? = nil,
        skillLevel: ExperienceLevel = .novice,
        family: String? = nil,
        familyLoadRatio: Double? = nil,
        alternatives: [String] = [],
        fatigueCost: Double = 1.0,
        setupSeconds: Int = 20
    ) -> ExerciseSchema {
        ExerciseSchema(
            slug: slug,
            name: slug,
            pattern: pattern,
            muscleContributions: contributions,
            equipment: equipment,
            loadType: loadType,
            jointStress: jointStress ?? noStress(),
            skillLevel: skillLevel,
            fatigueCost: fatigueCost,
            alternatives: alternatives,
            progressionFamily: family ?? slug,
            familyLoadRatio: familyLoadRatio,
            setupSeconds: setupSeconds,
            illustration: slug)
    }

    /// Упражнения на собственном весе, которых хватает дню низа и дню жима на
    /// любом уровне инвентаря: пять паттернов, пять семей.
    static var bodyweightLower: [ExerciseSchema] {
        [
            exercise("bw_squat", pattern: .squat,
                     contributions: [.quads: 0.5, .gluteMax: 0.3, .adductors: 0.2]),
            exercise("bw_lunge", pattern: .lunge,
                     contributions: [.quads: 0.4, .gluteMax: 0.4, .gluteMed: 0.15,
                                     .hamstrings: 0.05]),
            exercise("bw_glute_bridge", pattern: .hinge,
                     contributions: [.gluteMax: 0.65, .hamstrings: 0.25, .erectors: 0.10]),
            exercise("bw_calf_raise", pattern: .isolation, contributions: [.calves: 1.0]),
            exercise("bw_plank", pattern: .core,
                     contributions: [.abs: 0.7, .obliques: 0.3]),
            exercise("bw_hip_abduction", pattern: .isolation,
                     contributions: [.gluteMed: 0.85, .gluteMax: 0.15]),
        ]
    }

    /// Жим на собственном весе: три паттерна, чтобы день жима собирался и без
    /// инвентаря.
    static var bodyweightPush: [ExerciseSchema] {
        [
            exercise("bw_pushup", pattern: .pushH,
                     contributions: [.pecs: 0.55, .frontDelts: 0.25, .triceps: 0.20]),
            exercise("bw_pike_pushup", pattern: .pushV,
                     contributions: [.frontDelts: 0.5, .triceps: 0.3, .sideDelts: 0.2]),
            exercise("bw_dip", pattern: .isolation,
                     contributions: [.triceps: 0.6, .pecs: 0.3, .frontDelts: 0.1]),
        ]
    }

    /// Тяга требует турника или гантелей: именно этого на пустом профиле и нет
    /// (§20.11, заведомо неполные комбинации).
    static var pull: [ExerciseSchema] {
        [
            exercise("db_row", pattern: .pullH,
                     contributions: [.lats: 0.45, .trapsMid: 0.3, .biceps: 0.25],
                     loadType: .dumbbell),
            exercise("pullup", pattern: .pullV,
                     contributions: [.lats: 0.6, .biceps: 0.25, .trapsMid: 0.15],
                     equipment: [.pullupBar]),
            exercise("db_curl", pattern: .isolation,
                     contributions: [.biceps: 0.85, .forearms: 0.15],
                     loadType: .dumbbell),
            exercise("db_rear_delt_raise", pattern: .isolation,
                     contributions: [.rearDelts: 0.8, .trapsMid: 0.2],
                     loadType: .dumbbell),
        ]
    }

    /// Спина на собственном весе: тянущего паттерна здесь нет — тянуть без
    /// турника и весов нечем, — но мышцы вектора тяги эти упражнения грузят.
    /// Разница видна ровно там, где её различает §20.11: комбинация
    /// (pull, без железа) выходит ОСЛАБЛЕННОЙ, а не пустой.
    static var bodyweightBack: [ExerciseSchema] {
        [
            exercise("prone_y_raise", pattern: .isolation,
                     contributions: [.trapsMid: 0.5, .rearDelts: 0.5]),
            exercise("superman", pattern: .core,
                     contributions: [.erectors: 0.7, .gluteMax: 0.3]),
        ]
    }

    static var full: [ExerciseSchema] {
        bodyweightLower + bodyweightPush + bodyweightBack + pull
    }

    // MARK: - Векторы

    static func vector(_ kind: SessionKind, _ accent: MuscleSlug? = nil,
                       _ shares: [MuscleSlug: Double]) -> DayVector {
        DayVector(key: DayVectorKey(kind: kind, accent: accent), shares: shares)
    }

    static let lowerShares: [MuscleSlug: Double] = [
        .quads: 0.30, .gluteMax: 0.25, .hamstrings: 0.25,
        .gluteMed: 0.08, .adductors: 0.06, .calves: 0.06,
    ]

    static let pushShares: [MuscleSlug: Double] = [
        .pecs: 0.40, .frontDelts: 0.25, .triceps: 0.25, .sideDelts: 0.10,
    ]

    static let pullShares: [MuscleSlug: Double] = [
        .lats: 0.40, .trapsMid: 0.25, .biceps: 0.20, .rearDelts: 0.15,
    ]

    /// Таблица только из перечисленных пар. Валидатор строит сессию лишь для
    /// тех пар, у которых вектор есть, — отсутствие остальных называет
    /// `VectorChecks`, и в тестах покрытия это удобно: набор комбинаций задаётся
    /// таблицей, а не перебором ста пар.
    static func table(_ rows: [DayVector]) -> DayVectorTable { DayVectorTable(rows) }

    static func library(_ exercises: [ExerciseSchema], _ rows: [DayVector]) -> ContentLibrary {
        ContentLibrary(exercises: exercises, vectors: table(rows))
    }
}
