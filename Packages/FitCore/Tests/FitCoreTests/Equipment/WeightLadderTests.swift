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

    // MARK: - Границы ступеней в .arithmetic (код-ревью feature/weight-ladder, 2026-09-04)

    func test_arithmeticLadderQuantisesAroundStepBoundaries() {
        // Для каждого шага три позиции вокруг границы n×step: чуть ниже
        // (n×step − 0.01), ровно на ней и чуть выше (n×step + 0.01). Обе
        // прошлые попытки чинить эту ветку ловились ровно здесь:
        //
        //   • сырое `baseline / step` промахивалось вниз на «ровно» —
        //     0.3 / 0.1 == 2.9999999999999996, floor давал 2 вместо 3, и
        //     функция возвращала саму baseline;
        //   • round2 поверх частного промахивался вверх на «чуть ниже» —
        //     2.49 / 2.5 == 0.996, округление до сотых поднимало это до 1.0,
        //     и лестница перепрыгивала через ступень (2.5 → 5.0).
        //
        // Оговорка про строку 0.1/«чуть ниже»: она проходила и на сломанном
        // варианте (зазор 0.01/0.1 = 0.1 заведомо больше допуска round2
        // 0.005), то есть служит контролем, а не детектором. Регрессию вверх
        // ловят строки с шагом ≥ 2.0.
        //
        // (loadType, шаг, baseline, ожидаемый следующий вес)
        let cases: [(LoadType, Double, Double, Double)] = [
            (.machine, 0.10,  0.29,  0.30),
            (.machine, 0.10,  0.30,  0.40),
            (.machine, 0.10,  0.31,  0.40),

            (.cable,   2.27, 34.04, 34.05),   // 5 фунтов
            (.cable,   2.27, 34.05, 36.32),
            (.cable,   2.27, 34.06, 36.32),

            (.machine, 4.54, 68.09, 68.10),   // 10 фунтов
            (.machine, 4.54, 68.10, 72.64),
            (.machine, 4.54, 68.11, 72.64),

            (.machine, 2.50,  2.49,  2.50),
            (.machine, 2.50,  2.50,  5.00),
            (.machine, 2.50,  2.51,  5.00),

            (.cable,   5.00,  4.99,  5.00),
            (.cable,   5.00,  5.00, 10.00),
            (.cable,   5.00,  5.01, 10.00),

            (.machine, 4.10, 12.29, 12.30),
            (.machine, 4.10, 12.30, 16.40),
            (.machine, 4.10, 12.31, 16.40),
        ]

        for (loadType, step, baseline, expected) in cases {
            let ladder = WeightLadder.build(
                loadType: loadType,
                profile: EquipmentProfile(machineStepKg: step)
            )
            XCTAssertEqual(
                ladder.nextAchievableWeight(above: baseline), expected,
                "loadType=\(loadType) step=\(step) baseline=\(baseline)"
            )
        }
    }

    func test_arithmeticLadderReturnsNilForNonFiniteBaseline() {
        // Счёт в целых сотых переводит Double в Int, а `Int(_: Double)` на
        // nan/inf не возвращает мусор, а роняет процесс — здесь проверяется
        // именно то, что guard в cents() отрабатывает раньше конверсии.
        let ladder = WeightLadder.build(loadType: .machine, profile: EquipmentProfile(machineStepKg: 2.5))
        XCTAssertNil(ladder.nextAchievableWeight(above: .nan))
        XCTAssertNil(ladder.nextAchievableWeight(above: .infinity))
        XCTAssertNil(ladder.nextAchievableWeight(above: -.infinity))
        XCTAssertNil(ladder.nextAchievableWeight(above: 1e300))
    }

    // MARK: - Sweep: инвариант вместо таблицы чисел

    // Три раунда вручную подобранных чисел трижды не поймали следующий
    // случай, потому что каждый раз двигались по той оси, которую только что
    // починили. Здесь проверяется инвариант — «ни одна ступень не пропущена и
    // nil не возвращается ложно» — на сетке baseline вокруг ступеней, а
    // ожидаемое значение даёт независимый оракул (линейный поиск по
    // ступеням), а не повтор формулы из реализации.
    //
    // Ключевое: offset'ы берутся ТРЕМЯ полосами, разнесёнными на порядки.
    // Черновик с двумя полосами (шумовой и центовой) проходил на сломанном
    // коде: целые центы — ровно та точность, где округление baseline к
    // ближайшему центу является no-op. Баг жил в промежутке между шумом и
    // центом, и именно его никто не тестировал.
    //
    //   шумовая    ±1…10 ULP          — шум обязан гаситься
    //   субцентовая ±1e-8…±0.009 кг   — честная разница обязана НЕ гаситься
    //   центовая   ±0.01…±0.03 кг     — обычная сетка
    //
    // Полоса между 1e-14 и 1e-8 кг намеренно не проверяется: там проходит
    // сама граница допуска, её точное положение — проектное решение, а не
    // инвариант. Обе проверяемые полосы отстоят от неё на ~1000×, поэтому
    // тест не зашивает конкретное значение epsilon.

    private static let realOffsetsKg: [Double] = [
        -0.03, -0.02, -0.01, -0.009, -0.005, -0.001, -0.00001, -0.00000001,
         0.00000001, 0.00001, 0.001, 0.005, 0.009, 0.01, 0.02, 0.03,
    ]
    private static let ulpOffsets: [Int] = [-10, -4, -1, 0, 1, 4, 10]

    /// `value`, сдвинутое на `k` ULP (знак `k` задаёт направление).
    private func perturb(_ value: Double, byULP k: Int) -> Double {
        var x = value
        for _ in 0..<abs(k) { x = k < 0 ? x.nextDown : x.nextUp }
        return x
    }

    func test_sweep_arithmeticNeverSkipsRungAndNeverFalselyReportsExhausted() {
        for step in [0.1, 2.5, 2.27] {
            let ladder = WeightLadder.build(loadType: .machine, profile: EquipmentProfile(machineStepKg: step))
            let stepCents = Int((step * 100).rounded())

            for n in 1...12 {
                let rungKg = Double(n * stepCents) / 100

                for offset in Self.realOffsetsKg {
                    let baseline = rungKg + offset
                    // Оракул: линейный поиск по ступеням, независим от
                    // floor-деления в реализации.
                    var rung = stepCents
                    while Double(rung) / 100 <= baseline { rung += stepCents }
                    XCTAssertEqual(
                        ladder.nextAchievableWeight(above: baseline), Double(rung) / 100,
                        "step=\(step) n=\(n) offset=\(offset)"
                    )
                }

                for k in Self.ulpOffsets {
                    // Шум обязан гаситься: baseline читается как «ровно на
                    // ступени n», значит ответ — ступень n+1.
                    var rung = stepCents
                    while rung <= n * stepCents { rung += stepCents }
                    XCTAssertEqual(
                        ladder.nextAchievableWeight(above: perturb(rungKg, byULP: k)), Double(rung) / 100,
                        "step=\(step) n=\(n) ulp=\(k)"
                    )
                }
            }
        }
    }

    func test_sweep_discreteNeverSkipsRungAndNeverFalselyReportsExhausted() {
        let weights: [Double] = [2, 4, 6, 8]
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: weights))

        for rungKg in weights {
            for offset in Self.realOffsetsKg {
                let baseline = rungKg + offset
                XCTAssertEqual(
                    ladder.nextAchievableWeight(above: baseline), weights.filter { $0 > baseline }.min(),
                    "rung=\(rungKg) offset=\(offset)"
                )
            }
            for k in Self.ulpOffsets {
                // Шум гасится → стоим на rungKg, ответ — следующая гантель
                // (или nil на самой тяжёлой, что и есть честная исчерпанность).
                XCTAssertEqual(
                    ladder.nextAchievableWeight(above: perturb(rungKg, byULP: k)),
                    weights.filter { $0 > rungKg }.min(),
                    "rung=\(rungKg) ulp=\(k)"
                )
            }
        }
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
