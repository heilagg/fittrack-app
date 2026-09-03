//  WeightLadder — сценарии 1–3, 14 из SPEC §18 (см. doc-комментарий в
//  Equipment.swift) плюс тесты контракта построения лестницы по каждому
//  loadType, на который эти сценарии опираются.
//
//  Что здесь намеренно НЕ проверяется: сама реакция на процент шага
//  («расширить диапазон» / «прыгнуть с сбросом повторов») — это решение
//  Progression (SPEC §9.5), которого в этой ветке нет. WeightLadder отвечает
//  только за «какой вес достижим следующим», это и проверяется.
//
//  XCTest, а не Swift Testing: окружение — только Command Line Tools (см.
//  App/README.md), `Testing` как модуль SwiftPM здесь недоступен.

import XCTest
@testable import FitCore

final class WeightLadderTests: XCTestCase {

    // MARK: - Сценарии SPEC §18

    func test_scenario1_dumbbellStepAboveMidRange() {
        let ladder = WeightLadder.build(
            loadType: .dumbbell,
            profile: EquipmentProfile(dumbbellsKg: [2, 4, 6, 8])
        )
        XCTAssertEqual(ladder.nextAchievableWeight(above: 6), 8)
    }

    func test_scenario2_dumbbellStepAfterExtensionExhausted() {
        // Лестница не знает о rep_extension: Progression запрашивает тот же
        // nextAchievableWeight(above: 6) оба раза и решает по-разному сама.
        // Здесь фиксируется именно стабильность и корректность значения.
        let ladder = WeightLadder.build(
            loadType: .dumbbell,
            profile: EquipmentProfile(dumbbellsKg: [2, 4, 6, 8])
        )
        XCTAssertEqual(ladder.nextAchievableWeight(above: 6), 8)
    }

    func test_scenario3_dumbbellNoStepAtMax() {
        let ladder = WeightLadder.build(
            loadType: .dumbbell,
            profile: EquipmentProfile(dumbbellsKg: [2, 4, 6, 8])
        )
        XCTAssertNil(ladder.nextAchievableWeight(above: 8))
    }

    func test_scenario14_emptyInventoryHasNoWeightedLadder() {
        let weightedLoadTypes: [LoadType] = [.dumbbell, .kettlebell, .barbell, .machine, .cable]
        for loadType in weightedLoadTypes {
            let ladder = WeightLadder.build(loadType: loadType, profile: EquipmentProfile())
            XCTAssertNil(ladder.nextAchievableWeight(above: 0), "\(loadType) не должен давать вес на пустом инвентаре")
            XCTAssertNil(ladder.nextAchievableWeight(above: -5), "\(loadType) не должен давать вес на пустом инвентаре")
        }
    }

    func test_scenario14_bodyweightNeedsNoLadder() {
        XCTAssertEqual(WeightLadder.build(loadType: .bodyweight, profile: EquipmentProfile()), .none)
    }

    // MARK: - Контракт построения лестницы (не входит в 4 сценария §18)

    func test_barbellSubsetSum() {
        let profile = EquipmentProfile(platesKg: [1.25, 2.5, 5], barbellKg: 20)
        let ladder = WeightLadder.build(loadType: .barbell, profile: profile)

        guard case .discrete(let weights) = ladder else {
            XCTFail("ожидалась дискретная лестница")
            return
        }
        // Подмножества блинов на сторону: 0, 1.25, 2.5, 5, 3.75, 6.25, 7.5, 8.75
        // → ×2 + 20 → отсортированный список без дублей.
        XCTAssertEqual(weights, [20, 22.5, 25, 27.5, 30, 32.5, 35, 37.5])
    }

    func test_barbellMissingBarGivesEmptyLadder() {
        let profile = EquipmentProfile(platesKg: [5, 10], barbellKg: nil)
        XCTAssertEqual(WeightLadder.build(loadType: .barbell, profile: profile), .discrete([]))
    }

    func test_machineArithmeticStep() {
        let ladder = WeightLadder.build(loadType: .machine, profile: EquipmentProfile(machineStepKg: 5))
        XCTAssertEqual(ladder.nextAchievableWeight(above: 22), 25)
        XCTAssertEqual(ladder.nextAchievableWeight(above: 20), 25)
        XCTAssertEqual(ladder.nextAchievableWeight(above: 0), 5)
        XCTAssertEqual(ladder.nextAchievableWeight(above: -3), 5)
    }

    func test_cableUsesMachineStep() {
        let ladder = WeightLadder.build(loadType: .cable, profile: EquipmentProfile(machineStepKg: 2.5))
        XCTAssertEqual(ladder.nextAchievableWeight(above: 10), 12.5)
    }

    func test_machineMissingStepGivesEmptyLadder() {
        XCTAssertEqual(WeightLadder.build(loadType: .machine, profile: EquipmentProfile()), .discrete([]))
    }

    func test_kettlebellEmptyWhenNoneOwned() {
        XCTAssertEqual(WeightLadder.build(loadType: .kettlebell, profile: EquipmentProfile()), .discrete([]))
    }

    func test_bodyweightAndBandHaveNoLadder() {
        let profile = EquipmentProfile(dumbbellsKg: [2, 4, 6, 8])
        XCTAssertEqual(WeightLadder.build(loadType: .bodyweight, profile: profile), .none)
        XCTAssertEqual(WeightLadder.build(loadType: .band, profile: profile), .none)
    }
}
