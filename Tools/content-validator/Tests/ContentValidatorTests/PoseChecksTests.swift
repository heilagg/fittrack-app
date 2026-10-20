import XCTest
import FitCore
import FitContent
import ContentValidator

/// Проверки поз и шаблонов (SPEC §12.2, §12.3).
final class PoseChecksTests: XCTestCase {

    private func pose(_ slug: String, kind: PoseKind = .static, name: String? = nil,
                      joints: [Joint: JointStressLevel]? = nil, muscles: [MuscleSlug] = [.quads],
                      technique: [String] = ["Шаг один.", "Шаг два.", "Шаг три."]) -> PoseSchema {
        PoseSchema(slug: slug, name: name ?? "Поза \(cyrillic(slug))", kind: kind, defaultSeconds: 30, muscles: muscles,
                   jointStress: joints ?? Fixtures.noStress(), cues: ["Подсказка"], technique: technique,
                   illustration: "placeholder/stretch/\(slug)")
    }

    private func cyrillic(_ slug: String) -> String {
        ["a": "А", "b": "Б", "c": "В", "d": "Г"][slug] ?? "Х"
    }

    private func findings(_ poses: [PoseSchema], _ templates: [StretchTemplateSchema]) -> [String] {
        let collector = FindingCollector()
        PoseChecks.run(ContentLibrary(exercises: [], vectors: DayVectorTable([]), poses: poses, templates: templates),
                       into: collector)
        return collector.findings.map(\.line)
    }

    private func template(_ slug: String, _ items: [TemplateItem]) -> StretchTemplateSchema {
        StretchTemplateSchema(slug: slug, name: "Шаблон \(cyrillic(slug))", purpose: "п", items: items)
    }

    func test_cleanPosesAndTemplatesPass() {
        let poses = [pose("a"), pose("b"), pose("c", kind: .cardio), pose("d", kind: .cardio)]
        let templates = [
            template("s", [TemplateItem(pose: "a", seconds: 30), TemplateItem(pose: "b", seconds: 45)]),
            template("k", [TemplateItem(pose: "c", workSeconds: 30, restSeconds: 15, rounds: 3),
                           TemplateItem(pose: "d", workSeconds: 30, restSeconds: 15, rounds: 3)]),
        ]
        XCTAssertEqual(findings(poses, templates), [])
    }

    func test_incompleteJointMapAndEmptyMuscles() {
        let lines = findings([pose("a", joints: [.knee: .low], muscles: [])], [])
        XCTAssertTrue(lines.contains { $0.contains("joint_stress неполная") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("muscles пуст") }, "\(lines)")
    }

    func test_techniqueAndNameRulesApplyToPoses() {
        let lines = findings([pose("a", name: "pose", technique: ["Один шаг."])], [])
        XCTAssertTrue(lines.contains { $0.contains("латиницу") })
        XCTAssertTrue(lines.contains { $0.contains("technique: 1 шагов") })
    }

    func test_repeatedAndUnknownPoseInTemplate() {
        let lines = findings([pose("a")], [template("s", [TemplateItem(pose: "a", seconds: 30),
                                                         TemplateItem(pose: "a", seconds: 30),
                                                         TemplateItem(pose: "zz", seconds: 30)])])
        XCTAssertTrue(lines.contains { $0.contains("повторяется в шаблоне") })
        XCTAssertTrue(lines.contains { $0.contains("«zz» нет в каталоге") })
    }

    func test_cardioOnlyInItsTemplateAndWithIntervals() {
        let poses = [pose("a"), pose("c", kind: .cardio), pose("d", kind: .cardio)]
        let mixed = findings(poses, [template("k", [TemplateItem(pose: "c", workSeconds: 30, restSeconds: 15, rounds: 3),
                                                   TemplateItem(pose: "a", workSeconds: 30, restSeconds: 15, rounds: 3)])])
        XCTAssertTrue(mixed.contains { $0.contains("в кардио-шаблоне поза «a»") }, "\(mixed)")
        let rounds = findings(poses, [template("k", [TemplateItem(pose: "c", workSeconds: 30, restSeconds: 15, rounds: 3),
                                                    TemplateItem(pose: "d", workSeconds: 30, restSeconds: 15, rounds: 2)])])
        XCTAssertTrue(rounds.contains { $0.contains("rounds у записей") })
        let secondsOnCardio = findings(poses, [template("k", [TemplateItem(pose: "c", seconds: 30)])])
        XCTAssertTrue(secondsOnCardio.contains { $0.contains("у кардио нужны") })
        let intervalOnStretch = findings(poses, [template("s", [TemplateItem(pose: "a", workSeconds: 30, restSeconds: 15, rounds: 3)])])
        XCTAssertTrue(intervalOnStretch.contains { $0.contains("у растяжки нужно seconds") })
    }

    func test_emptyTemplate() {
        XCTAssertTrue(findings([], [template("e", [])]).contains { $0.contains("шаблон без поз") })
    }
}
