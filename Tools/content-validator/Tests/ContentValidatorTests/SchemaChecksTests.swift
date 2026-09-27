//  Правила §6.2, §6.3, §6.6, §7.5 — по тесту на правило, положительный и
//  отрицательный случай.

import XCTest
import FitCore
import FitContent
import ContentValidator

final class SchemaChecksTests: XCTestCase {

    private func findings(_ exercises: [ExerciseSchema], rule: String? = nil) -> [Finding] {
        let collector = FindingCollector()
        SchemaChecks.run(Fixtures.library(exercises, []), into: collector)
        guard let rule else { return collector.findings }
        return collector.findings(rule: rule)
    }

    // MARK: - §6.3, сумма вкладов

    func test_cleanLibraryProducesNoSchemaFindings() {
        XCTAssertEqual(findings(Fixtures.full), [], "чистая разметка не даёт находок")
    }

    func test_contributionSumOutsideToleranceIsReported() {
        let broken = Fixtures.exercise("broken", pattern: .squat,
                                       contributions: [.quads: 0.5, .gluteMax: 0.2])
        let found = findings([broken], rule: "§6.3")
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found[0].message.contains("сумма вкладов"), found[0].message)
    }

    func test_contributionSumWithinTolerancePasses() {
        // 0.6 + 0.4005 = 1.0005 — округление двух знаков, а не ошибка разметки.
        let ok = Fixtures.exercise("ok", pattern: .squat,
                                   contributions: [.quads: 0.6, .gluteMax: 0.4005])
        XCTAssertEqual(findings([ok], rule: "§6.3"), [])
    }

    func test_negativeContributionIsReported() {
        let broken = Fixtures.exercise("broken", pattern: .squat,
                                       contributions: [.quads: 1.2, .gluteMax: -0.2])
        XCTAssertTrue(findings([broken], rule: "§6.3")
            .contains { $0.message.contains("отрицательный вклад") })
    }

    // MARK: - §6.2, полная карта суставов

    func test_incompleteJointMapIsReported() {
        let broken = Fixtures.exercise("broken", pattern: .squat, contributions: [.quads: 1.0],
                                       jointStress: [.knee: .medium])
        let found = findings([broken], rule: "§6.2")
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found[0].message.contains("неполная"), found[0].message)
        XCTAssertTrue(found[0].message.contains("ankle"),
                      "перечислены недостающие суставы: \(found[0].message)")
    }

    func test_fullJointMapOfNonesPasses() {
        let ok = Fixtures.exercise("ok", pattern: .squat, contributions: [.quads: 1.0])
        XCTAssertEqual(findings([ok], rule: "§6.2"), [],
                       "все семь суставов со значением none — это полная карта")
    }

    // MARK: - §6.6, словарь инвентаря

    func test_machineSlugOutsideTheClosedListIsReported() {
        let broken = Fixtures.exercise("broken", pattern: .squat, contributions: [.quads: 1.0],
                                       equipment: [.machine("leg_pres")], loadType: .machine)
        XCTAssertTrue(findings([broken], rule: "§6.6")
            .contains { $0.message.contains("leg_pres") })
    }

    func test_machineSlugFromTheClosedListPasses() {
        let ok = Fixtures.exercise("ok", pattern: .squat, contributions: [.quads: 1.0],
                                   equipment: [.machine("leg_press")], loadType: .machine)
        XCTAssertEqual(findings([ok], rule: "§6.6"), [])
    }

    func test_weightedLoadTypeMustNameItsGear() {
        let kettlebell = Fixtures.exercise("kb", pattern: .hinge, contributions: [.gluteMax: 1.0],
                                           loadType: .kettlebell)
        let cable = Fixtures.exercise("cable", pattern: .isolation, contributions: [.triceps: 1.0],
                                      loadType: .cable)
        let machine = Fixtures.exercise("machine", pattern: .squat, contributions: [.quads: 1.0],
                                        loadType: .machine)
        let messages = findings([kettlebell, cable, machine], rule: "§6.6").map(\.message)
        XCTAssertEqual(messages.count, 3, "все три весовых типа обязаны назвать снаряд")
        XCTAssertTrue(messages.contains { $0.contains("kettlebells") })
        XCTAssertTrue(messages.contains { $0.contains("cable_machine") })
        XCTAssertTrue(messages.contains { $0.contains("machine:<слаг>") })
    }

    func test_dumbbellLoadTypeNeedsNoEquipment() {
        // Гантели и штанга снаряд не называют: за них отвечает лестница (§6.6).
        let ok = Fixtures.exercise("db", pattern: .pullH, contributions: [.lats: 1.0],
                                   loadType: .dumbbell)
        XCTAssertEqual(findings([ok], rule: "§6.6"), [])
    }

    // MARK: - §7.5, альтернативы

    func test_alternativePointingNowhereIsReported() {
        let broken = Fixtures.exercise("broken", pattern: .squat, contributions: [.quads: 1.0],
                                       alternatives: ["does_not_exist"])
        XCTAssertTrue(findings([broken], rule: "§7.5")
            .contains { $0.message.contains("does_not_exist") })
    }

    func test_selfReferenceIsReported() {
        let broken = Fixtures.exercise("broken", pattern: .squat, contributions: [.quads: 1.0],
                                       alternatives: ["broken"])
        XCTAssertTrue(findings([broken], rule: "§7.5")
            .contains { $0.message.contains("своей же альтернативой") })
    }

    func test_oneWayAlternativeIsNotAnError() {
        // Список направленный (§7.5): у A есть B, у B нет A — это норма.
        let a = Fixtures.exercise("a", pattern: .squat, contributions: [.quads: 1.0],
                                  alternatives: ["b"])
        let b = Fixtures.exercise("b", pattern: .squat, contributions: [.quads: 1.0])
        XCTAssertEqual(findings([a, b], rule: "§7.5"), [])
    }

    // MARK: - §6.3, семья прогрессии

    func test_familyLoadRatioIsRequiredInAFamilyOfMoreThanOne() {
        let first = Fixtures.exercise("first", pattern: .hinge, contributions: [.gluteMax: 1.0],
                                      family: "thrust", familyLoadRatio: 1.0)
        let second = Fixtures.exercise("second", pattern: .hinge, contributions: [.gluteMax: 1.0],
                                       family: "thrust")
        let found = findings([first, second], rule: "§6.3")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].subject, "second")
        XCTAssertTrue(found[0].message.contains("family_load_ratio обязателен"), found[0].message)
    }

    func test_familyOfOneNeedsNoRatio() {
        let alone = Fixtures.exercise("alone", pattern: .hinge, contributions: [.gluteMax: 1.0],
                                      family: "thrust")
        XCTAssertEqual(findings([alone], rule: "§6.3"), [])
    }

    func test_nonPositiveRatioIsReported() {
        let a = Fixtures.exercise("a", pattern: .hinge, contributions: [.gluteMax: 1.0],
                                  family: "thrust", familyLoadRatio: 1.0)
        let b = Fixtures.exercise("b", pattern: .hinge, contributions: [.gluteMax: 1.0],
                                  family: "thrust", familyLoadRatio: 0)
        XCTAssertTrue(findings([a, b], rule: "§6.3")
            .contains { $0.subject == "b" && $0.message.contains("больше нуля") })
    }

    // MARK: - Санитарные

    func test_nonPositiveFatigueCostAndRestAreReported() {
        let broken = Fixtures.exercise("broken", pattern: .squat, contributions: [.quads: 1.0],
                                       fatigueCost: 0)
        XCTAssertTrue(findings([broken]).contains { $0.message.contains("fatigue_cost") })
    }
}
