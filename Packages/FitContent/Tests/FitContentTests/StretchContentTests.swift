import XCTest
import FitCore
@testable import FitContent

/// Позы и шаблоны растяжки на настоящих ресурсах пакета (SPEC §12.2, §12.3).
final class StretchContentTests: XCTestCase {

    private func bundled() throws -> ContentLibrary { try Content.loadBundled() }

    /// Сценарий 40 (§18): длительность шаблона — сумма поз, односторонняя
    /// дважды; у кардио — круги без отдыха после последнего интервала; минуты
    /// совпадают с таблицей §12.2.
    func test_scenario40_templateDurationsMatchSpecTable() throws {
        let library = try bundled()
        let expected: [String: (seconds: Int, minutes: Int)] = [
            "morning_mobility": (435, 7),
            "evening_relax": (600, 10),
            "neck_thoracic": (495, 8),
            "hip_opening": (690, 12),
            "lower_back_pelvis": (600, 10),
            "menstrual_gentle": (705, 12),
            "full_stretch": (1185, 20),
            "cardio_intervals": (525, 9),
        ]
        XCTAssertEqual(Set(library.templates.map(\.slug)), Set(expected.keys))
        for template in library.templates {
            let seconds = try XCTUnwrap(template.durationSeconds(poses: library.poseBySlug), template.slug)
            XCTAssertEqual(seconds, expected[template.slug]?.seconds, template.slug)
            XCTAssertEqual(StretchTemplateSchema.minutes(fromSeconds: seconds),
                           expected[template.slug]?.minutes, template.slug)
        }
    }

    func test_minutesRoundHalfUp() {
        XCTAssertEqual(StretchTemplateSchema.minutes(fromSeconds: 690), 12, "11.5 → 12")
        XCTAssertEqual(StretchTemplateSchema.minutes(fromSeconds: 689), 11)
        XCTAssertEqual(StretchTemplateSchema.minutes(fromSeconds: 435), 7)
    }

    /// Односторонняя поза идёт дважды, кардио — круги минус последний отдых.
    func test_durationFormula() {
        let poses = [
            "a": PoseSchema(slug: "a", name: "А", kind: .static, unilateral: true, defaultSeconds: 30,
                            muscles: [.quads], illustration: "x"),
            "b": PoseSchema(slug: "b", name: "Б", kind: .static, defaultSeconds: 30, muscles: [.pecs], illustration: "x"),
            "c": PoseSchema(slug: "c", name: "В", kind: .cardio, defaultSeconds: 30, muscles: [.calves], illustration: "x"),
            "d": PoseSchema(slug: "d", name: "Г", kind: .cardio, defaultSeconds: 30, muscles: [.abs], illustration: "x"),
        ]
        let stretch = StretchTemplateSchema(slug: "s", name: "С", purpose: "п",
                                            items: [TemplateItem(pose: "a", seconds: 40), TemplateItem(pose: "b", seconds: 50)])
        XCTAssertEqual(stretch.durationSeconds(poses: poses), 130)
        let cardio = StretchTemplateSchema(slug: "k", name: "К", purpose: "п", items: [
            TemplateItem(pose: "c", workSeconds: 30, restSeconds: 15, rounds: 2),
            TemplateItem(pose: "d", workSeconds: 20, restSeconds: 10, rounds: 2),
        ])
        XCTAssertEqual(cardio.durationSeconds(poses: poses), 2 * 45 + 2 * 30 - 10)
        let unknown = StretchTemplateSchema(slug: "u", name: "Н", purpose: "п", items: [TemplateItem(pose: "zz", seconds: 10)])
        XCTAssertNil(unknown.durationSeconds(poses: poses))
    }

    /// §7.5: позы в срез планировщика не попадают — это свойство построения.
    func test_posesNeverReachThePlannerSlice() throws {
        let library = try bundled()
        XCTAssertEqual(library.poses.count, 18)
        let candidateSlugs = Set(library.candidates.map(\.slug))
        XCTAssertTrue(library.poses.allSatisfy { !candidateSlugs.contains($0.slug) })
        XCTAssertEqual(library.candidates.count, library.exercises.count)
        XCTAssertEqual(library.poses.filter { $0.kind == .cardio }.map(\.slug).sorted(),
                       ["burpee_no_pushup", "jumping_jack", "mountain_climber", "running_in_place"])
    }

    /// Картинка — только у семи точных совпадений; остальные на заглушке
    /// `placeholder/stretch/<слаг>` (§6.5, §12.3).
    func test_poseIllustrationKeys() throws {
        let library = try bundled()
        let catalog = library.poses.filter { $0.illustration.hasPrefix("catalog/exact/") }.map(\.slug).sorted()
        XCTAssertEqual(catalog, ["arm_circles", "childs_pose", "hamstring_stretch", "kneeling_hip_flexor_stretch",
                                 "mountain_climber", "neck_side_stretch", "standing_toe_touch"])
        for pose in library.poses where !catalog.contains(pose.slug) {
            XCTAssertEqual(pose.illustration, "placeholder/stretch/\(pose.slug)")
        }
    }

    /// Шея и сгибатели бедра размечены слагами §6.4 (решение §12.3).
    func test_neckAndHipFlexorUseExistingSlugs() throws {
        let library = try bundled()
        XCTAssertEqual(library.poseBySlug["neck_side_stretch"]?.muscles, [.trapsUpper])
        XCTAssertEqual(library.poseBySlug["kneeling_hip_flexor_stretch"]?.muscles, [.quads])
    }
}
