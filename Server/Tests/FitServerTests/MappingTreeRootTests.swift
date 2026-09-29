//  Корень дерева §20.9 из журнала (SPEC §9.3, §9.8, §20.9, §20.15 20c).
//
//  Это та половина 20c, которую сверка дерева с `nextSet` не ловит по
//  построению: она передаёт обеим сторонам одно состояние и потому слепа к его
//  ВЫВОДУ. Здесь проверяется именно вывод — что журнал превращается в те три
//  компоненты, которые §20.9 называет, и что подходы вне дерева их не двигают.
//
//  Через HTTP это же будет проверяться отдельно, когда появится `POST …/sets`;
//  до тех пор 20c закрыт не полностью.

import Testing
import FitAPI
import FitCore
@testable import FitServer

@Suite("Mapping: корень дерева §20.9 из журнала")
struct MappingTreeRootTests {

    private let day = CalendarDay(year: 2026, month: 9, day: 29)
    private let range = 8...12
    private let ladder = WeightLadder.arithmetic(step: 2.5)

    private func set(_ index: Int, _ feedback: String?, reps: Int?, actual: Double?,
                     prescribed: Double? = nil, skipped: Bool = false,
                     pain: Bool = false) -> Mapping.SetRow {
        Mapping.SetRow(exerciseSlug: "bench_press_barbell", setIndex: index,
                       prescribedKg: prescribed ?? actual, actualKg: actual, actualReps: reps,
                       feedback: feedback, skipped: skipped, painFlag: pain, performedOn: day)
    }

    private func root(_ sets: [Mapping.SetRow], start: Double? = 40,
                      calibration: Bool = false) -> Mapping.TreeRoot {
        Mapping.treeRoot(sets: sets, startWeightKg: start, range: range,
                         isCalibration: calibration, ladder: ladder)
    }

    // MARK: - Пустой журнал

    @Test("подходов нет — корень это стартовый вес и чистое состояние")
    func emptyJournalYieldsTheStartWeight() {
        let r = root([])
        #expect(r.weightKg == 40)
        #expect(!r.previousWasFailed)
        #expect(r.calibrationIncreasesUsed == 0)
        #expect(!r.terminated)
    }

    // MARK: - Вес: current = actual_kg

    @Test("следующий вес считается от ФАКТИЧЕСКОГО, а не от показанного (§20.9)")
    func currentIsActualNotPrescribed() {
        // Показали 40, она взяла 45 и сказала «легко» на верхе диапазона.
        // От показанного вышло бы 42.5 — то есть меньше, чем она уже подняла.
        let r = root([set(1, "easy", reps: 12, actual: 45, prescribed: 40)])
        #expect(r.weightKg == 47.5, "от 45 вверх на ступень")

        let fromPrescribed = Progression.nextSet(priorFeedback: nil, current: 40, feedback: .easy,
                                                 actualReps: 12, range: range, isCalibration: false,
                                                 calibrationIncreasesUsed: 0, ladder: ladder)
        #expect(fromPrescribed == .nextWeight(42.5),
                "фиксирует цену подмены: вернули бы к числу, которое она отвергла")
    }

    @Test("вес идёт по цепочке подходов, а не считается от старта каждый раз")
    func weightFollowsTheChain() {
        let r = root([set(1, "easy", reps: 12, actual: 40),
                      set(2, "easy", reps: 12, actual: 42.5)])
        #expect(r.weightKg == 45)
    }

    @Test("«тяжело» ниже rep_min опускает вес")
    func hardBelowMinLowersWeight() {
        let r = root([set(1, "hard", reps: 7, actual: 40)])
        #expect((r.weightKg ?? 0) < 40)
    }

    // MARK: - previousWasFailed

    @Test("после failed корень несёт признак, и следующий failed завершает (§9.3)")
    func failedIsCarried() {
        let r = root([set(1, "failed", reps: 6, actual: 40)])
        #expect(r.previousWasFailed)
        #expect(!r.terminated, "один failed упражнение не закрывает")
    }

    @Test("два failed подряд — упражнение завершено, дерева больше нет")
    func twoFailedTerminate() {
        let r = root([set(1, "failed", reps: 6, actual: 40),
                      set(2, "failed", reps: 5, actual: 36)])
        #expect(r.terminated)
    }

    @Test("не-failed после failed снимает признак")
    func okClearsTheFlag() {
        let r = root([set(1, "failed", reps: 6, actual: 40),
                      set(2, "ok", reps: 10, actual: 36)])
        #expect(!r.previousWasFailed)
        #expect(!r.terminated)
    }

    // MARK: - Счётчик калибровки

    /// Цепочка строится самим корнем, а не формулой: ×1.15 округляется к
    /// лестнице, и посчитанное отдельно ожидание проверяло бы вторую копию
    /// арифметики вместо той, что работает.
    private func calibrationChain(length: Int) -> (sets: [Mapping.SetRow], weights: [Double?]) {
        var sets: [Mapping.SetRow] = []
        var weights: [Double?] = [40]
        for index in 1...length {
            sets.append(set(index, "easy", reps: 12, actual: weights.last ?? 40))
            weights.append(root(sets, start: 40, calibration: true).weightKg)
        }
        return (sets, weights)
    }

    @Test("израсходованные повышения считаются по сессии (§9.8)")
    func calibrationIncreasesAccumulate() {
        let chain = calibrationChain(length: 3)
        let r = root(chain.sets, start: 40, calibration: true)
        #expect(r.calibrationIncreasesUsed == Progression.maxCalibrationIncreases)
        #expect((r.weightKg ?? 0) > 40, "три ×1.15 вес подняли")
    }

    @Test("четвёртое «легко» в калибровке вес уже не двигает")
    func fourthEasyDoesNotRaise() {
        let chain = calibrationChain(length: 3)
        let afterThree = chain.weights.last ?? 40
        let four = chain.sets + [set(4, "easy", reps: 12, actual: afterThree)]
        let r = root(four, start: 40, calibration: true)
        #expect(r.weightKg == afterThree, "лимит §9.8 держится и через перестроенное дерево")
        #expect(r.calibrationIncreasesUsed == Progression.maxCalibrationIncreases)
    }

    @Test("вне калибровки счётчик не растёт")
    func counterStaysZeroOutsideCalibration() {
        let r = root([set(1, "easy", reps: 12, actual: 40), set(2, "easy", reps: 12, actual: 42.5)])
        #expect(r.calibrationIncreasesUsed == 0)
    }

    // MARK: - Подходы вне дерева (§20.9)

    @Test("пропущенный подход не двигает ни одной компоненты")
    func skippedMovesNothing() {
        let base = root([set(1, "ok", reps: 10, actual: 40)])
        let withSkip = root([set(1, "ok", reps: 10, actual: 40),
                             set(2, nil, reps: nil, actual: nil, skipped: true)])
        #expect(withSkip == base)
    }

    @Test("подход с флагом боли не двигает ни одной компоненты")
    func painFlagMovesNothing() {
        let base = root([set(1, "ok", reps: 10, actual: 40)])
        let withPain = root([set(1, "ok", reps: 10, actual: 40),
                             set(2, "failed", reps: 4, actual: 40, pain: true)])
        #expect(withPain == base, "у флага боли своя ветка §8.4, а не шаг прогрессии")
        #expect(!withPain.previousWasFailed, "и failed на нём не считается")
    }

    @Test("пропуск между двумя failed не разрывает пару")
    func skipBetweenFailedKeepsThePair() {
        // Иначе пропуск отменял бы досрочное завершение §9.3 — правило,
        // которого ни §9.3, ни §20.9 не вводят.
        let r = root([set(1, "failed", reps: 6, actual: 40),
                      set(2, nil, reps: nil, actual: nil, skipped: true),
                      set(3, "failed", reps: 5, actual: 40)])
        #expect(r.terminated)
    }

    // MARK: - Порядок и упражнение без веса

    @Test("порядок берётся из set_index, а не из порядка строк")
    func orderComesFromSetIndex() {
        let shuffled = [set(3, "easy", reps: 12, actual: 45),
                        set(1, "easy", reps: 12, actual: 40),
                        set(2, "easy", reps: 12, actual: 42.5)]
        #expect(root(shuffled).weightKg == 47.5)
    }

    @Test("упражнение без веса: весов нет ни на одном узле, ветка завершения жива")
    func weightlessKeepsNoWeights() {
        let r = root([set(1, "ok", reps: 15, actual: nil)], start: nil)
        #expect(r.weightKg == nil)

        let terminated = Mapping.treeRoot(
            sets: [set(1, "failed", reps: 8, actual: nil), set(2, "failed", reps: 6, actual: nil)],
            startWeightKg: nil, range: range, isCalibration: false, ladder: .none)
        #expect(terminated.terminated, "два failed подряд завершают и отжимания (§9.3)")
        #expect(terminated.weightKg == nil)
    }

    // MARK: - Стык с построением дерева

    @Test("корень доезжает до дерева: ветка failed из него завершает упражнение")
    func rootReachesTheTree() throws {
        let r = root([set(1, "failed", reps: 6, actual: 40)])
        let tree = DecisionTree.build(weightKg: r.weightKg, remainingSets: 2, range: range,
                                      isCalibration: false,
                                      previousWasFailed: r.previousWasFailed,
                                      calibrationIncreasesUsed: r.calibrationIncreasesUsed,
                                      ladder: ladder)
        let start = try #require(tree.nodes[tree.start])
        let next = try #require(start.transitions[TreeBranch.failed.rawValue])
        #expect(tree.nodes[next]?.terminates == true)
    }
}
