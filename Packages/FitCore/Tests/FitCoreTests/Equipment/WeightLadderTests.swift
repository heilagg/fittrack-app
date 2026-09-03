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

    func test_scenario1And2_dumbbellStepAboveMidRange() {
        // Сценарии 1 и 2 из §18 расходятся только в решении Progression
        // (расширить диапазон vs. прыгнуть после исчерпания rep_extension) —
        // на уровне WeightLadder оба сводятся к одному и тому же запросу
        // nextAchievableWeight(above: 6), поэтому это один тест, а не два
        // текстуально идентичных.
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

    func test_kettlebellUsesOwnKgListNotDumbbells() {
        // Раньше единственный тест на .kettlebell гонял пустой профиль, где
        // kettlebellsKg и dumbbellsKg совпадают ([]) — копипаст-баг
        // (.kettlebell читает profile.dumbbellsKg) прошёл бы незамеченным.
        let profile = EquipmentProfile(dumbbellsKg: [10, 20], kettlebellsKg: [8, 12, 16])
        let ladder = WeightLadder.build(loadType: .kettlebell, profile: profile)
        XCTAssertEqual(ladder.nextAchievableWeight(above: 8), 12)
        XCTAssertEqual(ladder.nextAchievableWeight(above: 16), nil)
    }

    func test_bodyweightAndBandHaveNoLadder() {
        let profile = EquipmentProfile(dumbbellsKg: [2, 4, 6, 8])
        XCTAssertEqual(WeightLadder.build(loadType: .bodyweight, profile: profile), .none)
        XCTAssertEqual(WeightLadder.build(loadType: .band, profile: profile), .none)
    }

    func test_bodyweightLoadedHasNoLadder() {
        // SPEC §6.3 не говорит, куда добавляется вес у bodyweight_loaded
        // (гантель? блин? жилет?) — до прояснения он трактуется так же, как
        // bodyweight/band: без квантования. Явный тест, а не полагание на
        // то, что общая ветка `case .bodyweight, .bodyweightLoaded, .band`
        // покрыта соседями.
        let profile = EquipmentProfile(dumbbellsKg: [2, 4, 6, 8])
        XCTAssertEqual(WeightLadder.build(loadType: .bodyweightLoaded, profile: profile), .none)
    }

    // MARK: - round2 (округление до сотых поверх арифметики Double)

    func test_barbellDedupsSumsThatDifferOnlyByFloatingPointNoise() {
        // 0.1 kg плюс 0.2 kg — классический пример, где Double-сложение не
        // даёт бит-в-бит то же значение, что прямой 0.3 kg. round2 должен
        // схлопнуть оба пути к одному элементу лестницы.
        let profile = EquipmentProfile(platesKg: [0.1, 0.2, 0.3], barbellKg: 0)
        let ladder = WeightLadder.build(loadType: .barbell, profile: profile)
        guard case .discrete(let weights) = ladder else {
            XCTFail("ожидалась дискретная лестница")
            return
        }
        // Суммы на сторону: 0, 0.1, 0.2, 0.3(=0.1+0.2 или сам блин), 0.4, 0.5, 0.6
        // → ×2: 0, 0.2, 0.4, 0.6, 0.8, 1.0, 1.2 — семь значений, не восемь.
        XCTAssertEqual(weights, [0, 0.2, 0.4, 0.6, 0.8, 1.0, 1.2])
    }

    func test_nextAchievableWeightRoundsBaselineBeforeComparing() {
        // Складываем 0.1 десять раз вместо использования литерала 1.0 —
        // классика Double: сумма не совпадает бит-в-бит с 1.0, и
        // noisyBaseline получается 5.999999999999999, а не ровно 6.0. Без
        // округления `weights.filter { $0 > baseline }` посчитал бы сам вес
        // 6 "следующим" — тем же весом, на котором пользователь уже стоит.
        let noisyBaseline = (0..<10).reduce(5.0) { sum, _ in sum + 0.1 }
        XCTAssertLessThan(noisyBaseline, 6.0, "тест ничего не проверяет, если сумма оказалась точной")

        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [2, 4, 6, 8]))
        XCTAssertEqual(ladder.nextAchievableWeight(above: noisyBaseline), 8)
    }
}
