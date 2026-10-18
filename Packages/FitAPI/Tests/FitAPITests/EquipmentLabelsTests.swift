import XCTest
@testable import FitAPI
import FitCore

/// Подписи снаряда (SPEC §6.6, «Подпись снаряда на экране»).
final class EquipmentLabelsTests: XCTestCase {

    private func labels(_ loadType: LoadType, _ equipment: [EquipmentRequirement] = []) -> [String] {
        EquipmentLabels.labels(loadType: loadType, equipment: equipment)
    }

    func test_loadTypeGivesDumbbellsAndBarbell() {
        XCTAssertEqual(labels(.dumbbell), ["Гантели"])
        XCTAssertEqual(labels(.barbell), ["Штанга"])
        XCTAssertEqual(labels(.dumbbell, [.benchAdjustable]), ["Гантели", "Регулируемая скамья"])
        XCTAssertEqual(labels(.barbell, [.benchFlat]), ["Штанга", "Скамья"])
    }

    func test_smithIsLabelledOnlyByItsMachine() {
        XCTAssertEqual(labels(.barbell, [.machine("smith")]), ["Тренажёр Смита"])
    }

    func test_requirementsLabelThemselvesWithoutDuplicates() {
        XCTAssertEqual(labels(.kettlebell, [.kettlebells]), ["Гири"])
        XCTAssertEqual(labels(.cable, [.cableMachine]), ["Блочный тренажёр (кроссовер)"])
        XCTAssertEqual(labels(.machine, [.machine("leg_press")]), ["Жим ногами"])
        XCTAssertEqual(labels(.band, [.bands]), ["Резинка"])
        XCTAssertEqual(labels(.bodyweight, [.machine("assisted_pullup")]), ["Гравитрон"])
        XCTAssertEqual(labels(.bodyweight, [.stepPlatform]), ["Степ-платформа"])
        XCTAssertEqual(labels(.bodyweight, [.plyoBox]), ["Тумба"])
    }

    func test_bodyweightWithoutEquipmentHasNoLabel() {
        XCTAssertEqual(labels(.bodyweight), [])
        XCTAssertEqual(labels(.bodyweightLoaded), [])
    }

    /// Порядок — таблица §6.6, а не разметка: чем нагружают, потом опоры.
    func test_orderFollowsTableNotMarkup() {
        XCTAssertEqual(labels(.band, [.bands, .pullupBar]), ["Турник", "Резинка"])
        XCTAssertEqual(labels(.band, [.pullupBar, .bands]), ["Турник", "Резинка"])
        XCTAssertEqual(labels(.dumbbell, [.stepPlatform, .benchFlat]), ["Гантели", "Скамья", "Степ-платформа"])
        XCTAssertEqual(labels(.cable, [.benchFlat, .cableMachine]), ["Блочный тренажёр (кроссовер)", "Скамья"])
    }

    /// Закрытый список слагов §6.6 — у каждого название. Полнота против списка
    /// FitContent сверяется в тестах сервера, который линкует оба пакета.
    func test_machineNamesCoverClosedList() {
        let slugs = ["leg_press", "leg_extension", "leg_curl", "hip_abduction", "calf_raise",
                     "lat_pulldown", "seated_row", "back_extension", "chest_press", "pec_deck",
                     "shoulder_press", "ab_crunch", "hip_adduction", "chest_supported_row",
                     "assisted_pullup", "smith"]
        XCTAssertEqual(Set(EquipmentLabels.machineNames.keys), Set(slugs))
        XCTAssertEqual(EquipmentLabels.machineNames["lat_pulldown"], "Верхний блок")
    }

    func test_unknownMachineSlugFallsBackToSlug() {
        XCTAssertEqual(EquipmentLabels.label(.machine("rowing_erg")), "rowing_erg")
    }
}
