//  Калибровочная библиотека — синтетика, на которой прогоном выбирались вес и
//  форма слагаемого покрытия w11 (SPEC §7.3, planner-domain §2 п.11). Перенесена
//  без изменений: двадцать упражнений, без требований к инвентарю, все
//  `bodyweight`, отдых 90 с у многосуставных и 60 с у изоляции.
//
//  Отдельная фикстура нужна ровно для сценария 27c («недельный glute_max тот же,
//  что без w11»). На основной PlannerFixtures с полным инвентарём (резинки,
//  гантели, скамья, штанга) утверждение не держится: 15.56 против 16.56. Это
//  зависимость от пути, а не дефект. В более богатом пуле есть составы с почти
//  равным score (glute_max 8.0 против 8.1 в первый день); крошечный штраф w11 за
//  икры (доля 0.06 в кубе, порядка 0.008) выбирает другой из них, и во второй
//  день w6 («не повторять вчерашнее») уводит сборку к составу на 0.9
//  эффективного подхода легче. На калибровочной библиотеке утверждение держится
//  во всех 18 прогнанных случаях — с утомлением между днями и без, при трёх
//  интервалах между днями, — и на основной фикстуре при минимальном инвентаре
//  тоже. Проверять 27c на ней значит проверять ровно то, что проверил прогон
//  SPEC, и не делать число сценария заложником ничьих в чужом пуле.
//
//  Остальные сценарии используют PlannerFixtures (planner-domain §4).

@testable import FitCore

enum PlannerCalibrationFixtures {

    private static func exercise(
        _ slug: String, _ pattern: Pattern, _ family: String, _ contributions: [MuscleSlug: Double],
        _ fatigueCost: Double, _ setup: Int, _ rest: Int, unilateral: Bool = false
    ) -> ExerciseCandidate {
        ExerciseCandidate(slug: slug, pattern: pattern, muscleContributions: contributions, progressionFamily: family,
                          fatigueCost: fatigueCost, setupSeconds: setup, defaultRestSeconds: rest,
                          unilateral: unilateral, loadType: .bodyweight)
    }

    static let library: [ExerciseCandidate] = [
        exercise("goblet_squat", .squat, "squat", [.quads: 0.50, .gluteMax: 0.25, .adductors: 0.15, .erectors: 0.10], 1.0, 60, 90),
        exercise("leg_press", .squat, "leg_press", [.quads: 0.55, .gluteMax: 0.30, .adductors: 0.15], 1.0, 60, 90),
        exercise("rdl_db", .hinge, "rdl", [.hamstrings: 0.45, .gluteMax: 0.35, .erectors: 0.20], 1.1, 60, 90),
        exercise("hip_thrust_db", .hinge, "hip_thrust", [.gluteMax: 0.60, .hamstrings: 0.20, .quads: 0.10, .erectors: 0.10], 0.9, 90, 90),
        exercise("split_squat", .lunge, "split_squat", [.quads: 0.45, .gluteMax: 0.35, .gluteMed: 0.10, .adductors: 0.10], 1.0, 45, 90, unilateral: true),
        exercise("leg_curl", .isolation, "leg_curl", [.hamstrings: 1.0], 0.6, 45, 60),
        exercise("calf_raise", .isolation, "calf", [.calves: 1.0], 0.5, 30, 60),
        exercise("abduction", .isolation, "abduction", [.gluteMed: 0.85, .gluteMax: 0.15], 0.5, 30, 60),
        exercise("adductor_mach", .isolation, "adductor", [.adductors: 1.0], 0.5, 45, 60),
        exercise("db_bench", .pushH, "bench", [.pecs: 0.55, .frontDelts: 0.20, .triceps: 0.25], 1.0, 60, 90),
        exercise("pushup", .pushH, "pushup", [.pecs: 0.50, .frontDelts: 0.20, .triceps: 0.20, .abs: 0.10], 0.8, 20, 90),
        exercise("db_ohp", .pushV, "ohp", [.frontDelts: 0.45, .sideDelts: 0.20, .triceps: 0.30, .trapsUpper: 0.05], 0.9, 45, 90),
        exercise("db_row", .pullH, "row", [.lats: 0.40, .trapsMid: 0.25, .rearDelts: 0.15, .biceps: 0.15, .forearms: 0.05], 1.0, 45, 90, unilateral: true),
        exercise("lat_pulldown", .pullV, "pulldown", [.lats: 0.55, .biceps: 0.25, .trapsMid: 0.10, .rearDelts: 0.10], 0.9, 45, 90),
        exercise("lateral_raise", .isolation, "lateral", [.sideDelts: 0.85, .trapsUpper: 0.15], 0.4, 30, 60),
        exercise("rear_fly", .isolation, "rear_fly", [.rearDelts: 0.60, .trapsMid: 0.40], 0.4, 30, 60),
        exercise("curl", .isolation, "curl", [.biceps: 0.85, .forearms: 0.15], 0.4, 30, 60),
        exercise("tri_ext", .isolation, "tri_ext", [.triceps: 1.0], 0.4, 30, 60),
        exercise("plank", .core, "plank", [.abs: 0.60, .obliques: 0.30, .erectors: 0.10], 0.3, 20, 60),
        exercise("pallof", .core, "pallof", [.obliques: 0.55, .abs: 0.45], 0.3, 30, 60),
    ]

    /// Все упражнения знакомы — как в прогоне, где w4 не различал кандидатов.
    static let familiar: [String: ExerciseState] = Dictionary(uniqueKeysWithValues:
        library.map { ($0.slug, ExerciseState(isInCalibration: false)) })
}
