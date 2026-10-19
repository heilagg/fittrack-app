import XCTest
@testable import FitCore

private typealias F = PlannerFixtures

/// Автозаминка и предложенный шаблон (SPEC §12.2). Позы — синтетические, по
/// правилу planner-domain §4: тест проверяет правило, а не разметку.
final class StretchingTests: XCTestCase {

    private func pose(_ slug: String, _ muscles: [MuscleSlug], kind: PoseKind = .static,
                      unilateral: Bool = false, seconds: Int = 30,
                      stress: [Joint: JointStressLevel] = [:]) -> StretchPose {
        StretchPose(slug: slug, kind: kind, unilateral: unilateral, defaultSeconds: seconds,
                    muscles: muscles, jointStress: stress)
    }

    private var poses: [StretchPose] {
        [
            pose("hamstring", [.hamstrings, .calves], unilateral: true),
            pose("pigeon", [.gluteMax, .gluteMed], unilateral: true, seconds: 45, stress: [.knee: .medium]),
            pose("hip_flexor", [.quads], unilateral: true, seconds: 45, stress: [.knee: .medium]),
            pose("butterfly", [.adductors, .gluteMed], seconds: 45),
            pose("child", [.lats, .erectors, .gluteMax], seconds: 60),
            pose("doorway", [.pecs, .frontDelts]),
            pose("cobra", [.abs]),
            pose("cat_cow", [.erectors, .abs], kind: .dynamic, seconds: 45),
            pose("jack", [.calves, .quads], kind: .cardio),
        ]
    }

    private var library: [String: ExerciseCandidate] {
        Dictionary(uniqueKeysWithValues: F.library.map { ($0.slug, $0) })
    }

    private func cooldown(_ sets: [String: Int], restrictions: [UserRestriction] = []) -> [CooldownPose] {
        Stretching.cooldown(setsBySlug: sets, library: library, poses: poses, restrictions: restrictions)
    }

    // MARK: - Сценарий 38

    /// Сценарий 38: заминка после тренировки низа тела — статические позы по
    /// проработанным мышцам, не больше пяти; ограничения §14.4 действуют.
    func test_scenario38_lowerDayCooldown() {
        let sets = ["hip_thrust_barbell": 4, "goblet_squat": 4, "rdl_band": 3, "band_abduction": 3, "calf_raise_bw": 2]
        let result = cooldown(sets)
        let slugs = result.map(\.slug)
        XCTAssertTrue((3...5).contains(slugs.count), "\(slugs)")
        XCTAssertEqual(slugs.first, "pigeon", "первая — по ягодичным, у них больше всего подходов")
        XCTAssertFalse(slugs.contains("cat_cow"), "динамическая в заминку не идёт")
        XCTAssertFalse(slugs.contains("jack"), "кардио в заминку не идёт")
        XCTAssertFalse(slugs.contains("doorway"), "грудь не работала")
        XCTAssertEqual(result.first { $0.slug == "pigeon" }?.seconds, 45, "секунды — default_seconds позы")

        // §14.4: avoid по колену исключает позы с medium на колене.
        let avoid = cooldown(sets, restrictions: [UserRestriction(joint: .knee, severity: .avoid)]).map(\.slug)
        XCTAssertFalse(avoid.contains("pigeon") || avoid.contains("hip_flexor"), "\(avoid)")
        let careful = cooldown(sets, restrictions: [UserRestriction(joint: .knee, severity: .careful)]).map(\.slug)
        XCTAssertTrue(careful.contains("pigeon"), "careful исключает только high")
    }

    /// Порог §12.2: четвёртая и пятая поза — только мышце с ≥ 4 эффективными
    /// подходами; первые три — при любом объёме.
    func test_extraPosesNeedFourEffectiveSets() {
        // Пять мышц по одной позе, подходы 6, 5, 4, 4, 3.9 — пятая не проходит порог.
        let syntheticLib: [String: ExerciseCandidate] = [
            "a": candidate("a", .pecs), "b": candidate("b", .lats), "c": candidate("c", .quads),
            "d": candidate("d", .abs), "e": candidate("e", .hamstrings),
        ]
        let list = [pose("p_pecs", [.pecs]), pose("p_lats", [.lats]), pose("p_quads", [.quads]),
                    pose("p_abs", [.abs]), pose("p_ham", [.hamstrings])]
        let five = Stretching.cooldown(setsBySlug: ["a": 6, "b": 5, "c": 4, "d": 4, "e": 4],
                                       library: syntheticLib, poses: list, restrictions: [])
        XCTAssertEqual(five.count, 5)
        let four = Stretching.cooldown(setsBySlug: ["a": 6, "b": 5, "c": 4, "d": 4, "e": 3],
                                       library: syntheticLib, poses: list, restrictions: [])
        XCTAssertEqual(four.map(\.slug), ["p_pecs", "p_lats", "p_abs", "p_quads"], "d и c — ничья 4, по слагу")
        let three = Stretching.cooldown(setsBySlug: ["a": 2, "b": 2, "c": 1, "d": 1, "e": 1],
                                        library: syntheticLib, poses: list, restrictions: [])
        XCTAssertEqual(three.count, 3, "первые три — при любом объёме")
        XCTAssertEqual(Stretching.cooldownExtraThreshold, 4)
        XCTAssertEqual(Stretching.cooldownMaxPoses, 5)
    }

    /// Только статические: динамическая поза не отвечает мышце даже тогда,
    /// когда больше ответить нечем (§12.2).
    func test_dynamicPoseIsNeverACooldown() {
        let lib = ["a": candidate("a", .abs)]
        let result = Stretching.cooldown(setsBySlug: ["a": 5], library: lib,
                                         poses: [pose("cat_cow", [.abs], kind: .dynamic)], restrictions: [])
        XCTAssertEqual(result, [])
    }

    /// Мышца, уже покрытая выбранной позой, второй позы не получает.
    func test_coveredMuscleGetsNoSecondPose() {
        let lib = ["a": candidate("a", .pecs), "b": candidate("b", .frontDelts)]
        let result = Stretching.cooldown(setsBySlug: ["a": 6, "b": 5], library: lib,
                                         poses: [pose("both", [.pecs, .frontDelts]), pose("delts", [.frontDelts])],
                                         restrictions: [])
        XCTAssertEqual(result.map(\.slug), ["both"])
    }

    // MARK: - Сценарий 39

    /// Сценарий 39: без подходов заминки нет; мышцам без статической позы
    /// ответить нечем — заминка короче трёх поз и без чужих поз.
    func test_scenario39_emptyAndShortCooldown() {
        XCTAssertEqual(cooldown([:]), [])
        XCTAssertEqual(cooldown(["hip_thrust_barbell": 0]), [])
        // Только махи в стороны: средние дельты и трапеции, позы нет ни одной.
        XCTAssertEqual(cooldown(["db_lateral_raise": 4]), [])
        // Жим гантелей: грудь, трицепс, передние дельты — одна поза на грудь и
        // передние дельты, трицепсу ответить нечем.
        let push = cooldown(["db_bench": 5])
        XCTAssertEqual(push.map(\.slug), ["doorway"], "короче трёх, без добора чужими позами")
    }

    // MARK: - Предложенный шаблон

    func test_suggestedTemplateRule() {
        XCTAssertEqual(Stretching.suggestedTemplate(phase: .menstrual, cycleConfidence: 0.3, lastStrengthKind: .lower),
                       .menstrualGentle)
        XCTAssertEqual(Stretching.suggestedTemplate(phase: .menstrual, cycleConfidence: 0.29, lastStrengthKind: .lower),
                       .lowerBackPelvis, "ниже порога фаза не решает (§11.2)")
        XCTAssertEqual(Stretching.suggestedTemplate(phase: .follicular, cycleConfidence: 1, lastStrengthKind: .push),
                       .neckThoracic)
        XCTAssertEqual(Stretching.suggestedTemplate(phase: nil, cycleConfidence: nil, lastStrengthKind: .pull),
                       .neckThoracic)
        XCTAssertEqual(Stretching.suggestedTemplate(phase: nil, cycleConfidence: nil, lastStrengthKind: .upper),
                       .neckThoracic)
        XCTAssertEqual(Stretching.suggestedTemplate(phase: nil, cycleConfidence: nil, lastStrengthKind: .fullBody),
                       .fullStretch)
        XCTAssertEqual(Stretching.suggestedTemplate(phase: nil, cycleConfidence: nil, lastStrengthKind: nil),
                       .morningMobility)
    }

    private func candidate(_ slug: String, _ muscle: MuscleSlug) -> ExerciseCandidate {
        ExerciseCandidate(slug: slug, pattern: .isolation, muscleContributions: [muscle: 1.0],
                          progressionFamily: slug, fatigueCost: 0.5, setupSeconds: 10, loadType: .bodyweight)
    }
}
