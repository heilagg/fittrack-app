import XCTest
@testable import FitCore

/// Замена упражнения (SPEC §13.4) и альтернативы по флагу боли (§8.4, п.2).
/// В номерном списке §18 за этим кодом сценариев не закреплено — §18 писался
/// до того, как §13.4 получила реализацию, — поэтому тесты контрактные и
/// помечены по смыслу, а не `test_scenarioN`.
final class SubstitutionTests: XCTestCase {

    private let today = CalendarDay(year: 2026, month: 9, day: 23)

    private func candidate(
        _ slug: String,
        contributions: [MuscleSlug: Double],
        jointStress: [Joint: JointStressLevel] = [:],
        family: String = "fam",
        ratio: Double? = nil,
        alternatives: [String] = [],
        loadType: LoadType = .dumbbell,
        equipment: [EquipmentRequirement] = []
    ) -> ExerciseCandidate {
        ExerciseCandidate(
            slug: slug, pattern: .hinge, muscleContributions: contributions,
            equipment: equipment, jointStress: jointStress,
            progressionFamily: family, familyLoadRatio: ratio,
            fatigueCost: 1.0, setupSeconds: 30, loadType: loadType,
            alternatives: alternatives
        )
    }

    private var profile: EquipmentProfile { EquipmentProfile(dumbbellsKg: [4, 6, 8, 10, 12, 14, 16]) }

    // MARK: - Отбор и порядок

    func test_alternativesSortedByProfileProximityAndCappedAtThree() {
        let origin = candidate("origin", contributions: [.gluteMax: 0.7, .hamstrings: 0.3],
                               alternatives: ["near", "mid", "far", "farthest"])
        let library = [
            origin,
            candidate("far", contributions: [.quads: 0.7, .calves: 0.3]),
            candidate("near", contributions: [.gluteMax: 0.68, .hamstrings: 0.32]),
            candidate("farthest", contributions: [.biceps: 1.0]),
            candidate("mid", contributions: [.gluteMax: 0.5, .hamstrings: 0.5]),
        ]

        let result = Planner.alternatives(
            to: origin, library: library,
            safety: SafetyProfile(level: .intermediate),
            availability: EquipmentAvailability(), equipment: profile, on: today
        )

        XCTAssertEqual(result.map(\.slug), ["near", "mid", "far"],
                       "порядок — по близости профиля вклада, и не больше трёх (§13.4)")
    }

    func test_alternativesExcludeTheExerciseItselfAndAnythingOutsideTheDeclaredPool() {
        let origin = candidate("origin", contributions: [.gluteMax: 1.0], alternatives: ["listed"])
        let library = [
            origin,
            candidate("listed", contributions: [.gluteMax: 0.9, .hamstrings: 0.1]),
            // Ближе по профилю, чем listed, но в разметке не объявлено.
            candidate("unlisted", contributions: [.gluteMax: 1.0]),
        ]

        let result = Planner.alternatives(
            to: origin, library: library,
            safety: SafetyProfile(level: .intermediate),
            availability: EquipmentAvailability(), equipment: profile, on: today
        )

        XCTAssertEqual(result.map(\.slug), ["listed"],
                       "пул задаёт разметка; добирать похожим из всей библиотеки функция не вправе")
    }

    func test_alternativesRespectHardConstraintsAndMayReturnFewerThanThree() {
        let origin = candidate("origin", contributions: [.gluteMax: 1.0],
                               alternatives: ["needs_bar", "hurts_knee", "fine"])
        let library = [
            origin,
            candidate("needs_bar", contributions: [.gluteMax: 1.0], equipment: [.pullupBar]),
            candidate("hurts_knee", contributions: [.gluteMax: 1.0], jointStress: [.knee: .high]),
            candidate("fine", contributions: [.gluteMax: 0.8, .hamstrings: 0.2]),
        ]
        let safety = SafetyProfile(
            level: .intermediate,
            restrictions: [UserRestriction(joint: .knee, severity: .careful)]
        )

        let result = Planner.alternatives(
            to: origin, library: library, safety: safety,
            availability: EquipmentAvailability(), equipment: profile, on: today
        )

        XCTAssertEqual(result.map(\.slug), ["fine"],
                       "инвентаря нет, колено под ограничением — остаётся одна, и это не ошибка")
    }

    // MARK: - Флаг боли (§8.4, п.2)

    func test_painPurposeRequiresStrictlyLessStressOnTheFlaggedJoint() {
        let origin = candidate("origin", contributions: [.gluteMax: 1.0],
                               jointStress: [.knee: .medium],
                               alternatives: ["same_stress", "lower_stress", "absent_stress"])
        let library = [
            origin,
            // Ближайший по профилю, но грузит колено ровно так же — и потому
            // не годится именно для этой причины замены.
            candidate("same_stress", contributions: [.gluteMax: 1.0], jointStress: [.knee: .medium]),
            candidate("lower_stress", contributions: [.gluteMax: 0.9, .hamstrings: 0.1], jointStress: [.knee: .low]),
            candidate("absent_stress", contributions: [.gluteMax: 0.7, .hamstrings: 0.3]),
        ]

        let result = Planner.alternatives(
            to: origin, purpose: .pain(joints: [.knee]), library: library,
            safety: SafetyProfile(level: .intermediate),
            availability: EquipmentAvailability(), equipment: profile, on: today
        )

        XCTAssertEqual(result.map(\.slug), ["lower_stress", "absent_stress"],
                       "§8.4 п.2: альтернатива обязана грузить больной сустав строго меньше")
    }

    func test_absentJointStressRanksBelowLow() {
        XCTAssertLessThan(Planner.stressRank(nil), Planner.stressRank(.low),
                          "сустава нет в разметке — это не та же нагрузка, что низкая")
    }

    // MARK: - Причины пригодности

    func test_fitReasonsNameSharedLeadingMuscleAndRelievedConcerningJoint() {
        let origin = candidate("origin", contributions: [.gluteMax: 0.7, .quads: 0.3],
                               jointStress: [.knee: .high, .hip: .medium],
                               alternatives: ["alt"])
        let alt = candidate("alt", contributions: [.gluteMax: 0.8, .quads: 0.2],
                            jointStress: [.knee: .low, .hip: .low])
        let safety = SafetyProfile(
            level: .intermediate,
            restrictions: [UserRestriction(joint: .knee, severity: .careful)]
        )

        let result = Planner.alternatives(
            to: origin, library: [origin, alt], safety: safety,
            availability: EquipmentAvailability(), equipment: profile, on: today
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].reasons, [
            .substitutionKeepsLeadingMuscle(muscle: .gluteMax),
            .substitutionRelievesJoint(joint: .knee, from: .high, to: .low),
        ], "бедро разгружено тоже, но ограничения на него нет — про него молчим (§13.4)")
    }

    // MARK: - Перенос веса (§13.4)

    func test_weightTransferScalesByRatioAndRoundsDown() {
        let from = candidate("from", contributions: [.gluteMax: 1.0], family: "hinge", ratio: 1.0)
        let to = candidate("to", contributions: [.gluteMax: 1.0], family: "hinge", ratio: 0.5)
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: profile)

        // 16 × 0.5 / 1.0 = 8.0 — ступень есть, берётся она.
        XCTAssertEqual(
            Planner.transferredBaseline(from: from, to: to, baselineKg: 16, ladder: ladder) ?? -1,
            8, accuracy: 0.0001)

        // 14 × 0.5 = 7.0 — ступени нет, округление вниз даёт 6, а не 8.
        XCTAssertEqual(
            Planner.transferredBaseline(from: from, to: to, baselineKg: 14, ladder: ladder) ?? -1,
            6, accuracy: 0.0001,
            "ошибка пересчёта обязана давать недогруз, а не перегруз (§13.4, §9.8)")
    }

    func test_weightTransferUndefinedFallsToCalibration() {
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: profile)
        let base = candidate("base", contributions: [.gluteMax: 1.0], family: "hinge", ratio: 1.0)

        let otherFamily = candidate("other", contributions: [.gluteMax: 1.0], family: "squat", ratio: 0.5)
        XCTAssertNil(Planner.transferredBaseline(from: base, to: otherFamily, baselineKg: 16, ladder: ladder),
                     "разные progression_family — вес не переносится")

        let noRatio = candidate("no_ratio", contributions: [.gluteMax: 1.0], family: "hinge", ratio: nil)
        XCTAssertNil(Planner.transferredBaseline(from: base, to: noRatio, baselineKg: 16, ladder: ladder),
                     "нет family_load_ratio у нового — пересчёт не определён")
        XCTAssertNil(Planner.transferredBaseline(from: noRatio, to: base, baselineKg: 16, ladder: ladder),
                     "нет family_load_ratio у старого — тоже")

        XCTAssertNil(Planner.transferredBaseline(from: base, to: otherFamily, baselineKg: nil, ladder: ladder),
                     "нет базовой линии — переносить нечего")
    }
}
