import XCTest
@testable import FitAPI
@testable import FitCore

/// Дерево решений §20.9 — карта состояний. Здесь же половины теста 20c
/// (§20.15), к которым сверка «ветка против прямого вызова» слепа по
/// построению.
final class DecisionTreeTests: XCTestCase {

    private let range = 8...12
    private var dumbbells: WeightLadder {
        WeightLadder.build(loadType: .dumbbell,
                           profile: EquipmentProfile(dumbbellsKg: [4, 6, 8, 10, 12, 14, 16, 18, 20]))
    }
    private var machine: WeightLadder { .arithmetic(step: 2.5) }
    private var barbell: WeightLadder {
        WeightLadder.build(loadType: .barbell,
                           profile: EquipmentProfile(platesKg: [1.25, 2.5, 5, 10], barbellKg: 20))
    }

    /// Обход карты от корня с восстановлением состояния, из которого узел
    /// строился. Посещённые пары (узел, состояние) не повторяются — карта DAG,
    /// и без отметки обход разворачивал бы её обратно в дерево.
    private func walk(
        _ tree: DecisionTreeDTO,
        isCalibration: Bool,
        visit: (TreeState, TreeBranch, DecisionNode) -> Void
    ) {
        var seen = Set<String>()
        func go(_ id: String, _ state: TreeState) {
            guard seen.insert(id).inserted, let node = tree.nodes[id] else { return }
            for branch in TreeBranch.allCases {
                guard let childID = node.transitions[branch.rawValue],
                      let child = tree.nodes[childID] else { continue }
                visit(state, branch, child)
                guard !child.terminates, !child.truncated else { continue }
                let consumed = Progression.consumesCalibrationIncrease(
                    feedback: branch.feedback, actualReps: branch.representativeReps(range),
                    range: range, isCalibration: isCalibration,
                    calibrationIncreasesUsed: state.calibrationIncreasesUsed)
                go(childID, TreeState(
                    weightKg: child.weightKg,
                    previousWasFailed: branch.feedback == .failed,
                    calibrationIncreasesUsed: state.calibrationIncreasesUsed + (consumed ? 1 : 0)))
            }
        }
        go(tree.start, TreeState(weightKg: tree.nodes[tree.start]?.weightKg,
                                 previousWasFailed: false, calibrationIncreasesUsed: 0))
    }

    /// 20c: каждая ветка отданной карты совпадает с прямым вызовом
    /// `Progression.nextSet` на том же состоянии.
    func test_20c_everyBranchMatchesDirectNextSetCall() {
        for (name, ladder) in [("гантели", dumbbells), ("тренажёр", machine), ("штанга", barbell)] {
            for isCalibration in [false, true] {
                let tree = DecisionTree.build(weightKg: 10, remainingSets: 4, range: range,
                                              isCalibration: isCalibration, ladder: ladder)
                var checked = 0
                walk(tree, isCalibration: isCalibration) { state, branch, child in
                    let outcome = Progression.nextSet(
                        priorFeedback: state.previousWasFailed ? .failed : nil,
                        current: state.weightKg ?? 0, feedback: branch.feedback,
                        actualReps: branch.representativeReps(self.range), range: self.range,
                        isCalibration: isCalibration,
                        calibrationIncreasesUsed: state.calibrationIncreasesUsed, ladder: ladder)
                    checked += 1
                    switch outcome {
                    case .terminateExercise:
                        XCTAssertTrue(child.terminates,
                                      "\(name): ветка \(branch.rawValue) обязана завершать упражнение")
                    case .nextWeight(let expected):
                        guard !child.truncated else { return }
                        XCTAssertEqual(child.weightKg ?? .nan, expected, accuracy: 0.0001,
                                       "\(name): ветка \(branch.rawValue) разошлась с nextSet")
                    }
                }
                XCTAssertGreaterThan(checked, 10, "\(name): карта обязана иметь ветки")
            }
        }
    }

    /// 20c, вторая слепая половина (§9.8, п.20): карта обязана переставать
    /// поднимать вес после трёх калибровочных повышений.
    func test_20c_calibrationLimitHoldsAlongTheEasyBranch() {
        let tree = DecisionTree.build(weightKg: 10, remainingSets: 5, range: range,
                                      isCalibration: true, ladder: dumbbells)
        var id = tree.start
        var weights: [Double] = [tree.nodes[id]!.weightKg!]
        while let next = tree.nodes[id]?.transitions[TreeBranch.easyAtOrAboveRepMax.rawValue],
              let node = tree.nodes[next], let w = node.weightKg {
            weights.append(w)
            id = next
        }
        XCTAssertEqual(weights.count, 6, "пять подходов дают шесть узлов на ветке: \(weights)")

        let rises = zip(weights, weights.dropFirst()).filter { $1 > $0 }.count
        XCTAssertEqual(rises, Progression.maxCalibrationIncreases,
                       "в калибровке вес поднимается ровно три раза, дальше стоит: \(weights)")
        XCTAssertEqual(weights[4], weights[5], accuracy: 0.0001, "четвёртое «легко» вес не двигает")
    }

    /// 20c, третья слепая половина (п.18): у упражнения без веса карта весов не
    /// несёт вовсе. Числа прошли бы сверку с `nextSet` зелёными — обе стороны
    /// врали бы одинаково.
    func test_20c_weightlessExerciseCarriesNoWeights() {
        let tree = DecisionTree.build(weightKg: nil, remainingSets: 4, range: range,
                                      isCalibration: false, ladder: .none)
        XCTAssertGreaterThan(tree.nodes.count, 1)
        for (id, node) in tree.nodes {
            XCTAssertNil(node.weightKg, "узел \(id): у упражнения без веса весов не бывает (§20.9)")
        }
        XCTAssertTrue(tree.nodes.values.contains { $0.terminates },
                      "ветка «два failed подряд» осмысленна и без веса и обязана остаться")
    }

    /// §9.3: два `failed` подряд завершают упражнение досрочно.
    func test_twoFailedInARowTerminates() {
        let tree = DecisionTree.build(weightKg: 10, remainingSets: 3, range: range,
                                      isCalibration: false, ladder: dumbbells)
        guard let firstID = tree.nodes[tree.start]?.transitions[TreeBranch.failed.rawValue],
              let first = tree.nodes[firstID] else { return XCTFail("нет ветки failed") }
        XCTAssertFalse(first.terminates, "первый failed упражнение не завершает")
        guard let secondID = first.transitions[TreeBranch.failed.rawValue] else {
            return XCTFail("нет второй ветки failed")
        }
        XCTAssertTrue(tree.nodes[secondID]?.terminates ?? false, "второй failed подряд завершает (§9.3)")
    }

    /// §19.2 п.19 и §20.9: предел 512 — предохранитель. При потолке подходов
    /// §7.3 он не срабатывает ни на одной реальной лестнице. Это то самое
    /// утверждение, ради которого форма ответа и есть карта, а не вложенное
    /// дерево: во вложенном на четырёх переходах 1483 узла.
    func test_nodeLimitNeverBindsAtTheSpecSetCap() {
        for (name, ladder) in [("гантели", dumbbells), ("тренажёр", machine), ("штанга", barbell)] {
            for isCalibration in [false, true] {
                for sets in 1...Planner.maxSetsPerExercise {
                    let tree = DecisionTree.build(weightKg: 10, remainingSets: sets, range: range,
                                                  isCalibration: isCalibration, ladder: ladder)
                    XCTAssertFalse(tree.nodes.values.contains(where: \.truncated),
                                   "\(name) cal=\(isCalibration) подходов=\(sets): обрезки быть не должно")
                    XCTAssertLessThan(tree.nodes.count, DecisionTree.maxNodes,
                                      "\(name) cal=\(isCalibration) подходов=\(sets): узлов \(tree.nodes.count)")
                }
            }
        }
    }

    /// Протокол обрезки обязан работать, если предел всё же достигнут.
    func test_truncationMarksTheNodeWhereItStopped() {
        let tree = DecisionTree.build(weightKg: 10, remainingSets: 400, range: range,
                                      isCalibration: true, ladder: machine)
        XCTAssertLessThanOrEqual(tree.nodes.count, DecisionTree.maxNodes, "предел обязан держаться")
        XCTAssertTrue(tree.nodes.values.contains(where: \.truncated),
                      "за пределом узлов ветки обязаны обрезаться")
    }

    /// Карта воспроизводима: одинаковый вход даёт побайтово одинаковый ответ,
    /// иначе диф двух ответов шумит на ровном месте.
    func test_mapIsDeterministic() {
        let a = DecisionTree.build(weightKg: 10, remainingSets: 4, range: range,
                                   isCalibration: true, ladder: dumbbells)
        let b = DecisionTree.build(weightKg: 10, remainingSets: 4, range: range,
                                   isCalibration: true, ladder: dumbbells)
        XCTAssertEqual(a, b)
    }

    func test_treeSurvivesRoundTrip() throws {
        let tree = DecisionTree.build(weightKg: 10, remainingSets: 4, range: range,
                                      isCalibration: false, ladder: dumbbells)
        let data = try JSONEncoder().encode(tree)
        XCTAssertEqual(try JSONDecoder().decode(DecisionTreeDTO.self, from: data), tree)
    }

    /// Замер, ради которого форма и менялась.
    func test_mapSizeIsTensOfNodesNotThousands() {
        for (name, ladder) in [("гантели", dumbbells), ("тренажёр", machine), ("штанга", barbell)] {
            for isCalibration in [false, true] {
                let tree = DecisionTree.build(weightKg: 10, remainingSets: 4, range: range,
                                              isCalibration: isCalibration, ladder: ladder)
                XCTAssertLessThan(tree.nodes.count, 100,
                                  "\(name) cal=\(isCalibration): узлов \(tree.nodes.count)")
                print("\(name) cal=\(isCalibration): узлов \(tree.nodes.count)")
            }
        }
    }
}
