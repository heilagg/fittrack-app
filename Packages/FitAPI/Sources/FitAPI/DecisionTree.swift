//  Дерево решений экрана тренировки (SPEC §20.9).
//
//  Сервер отдаёт его вперёд, вместе с составом упражнения; фронтенд применяет
//  ветку мгновенно. Обоснование — только латентность (§13.2, «один тап на
//  подход»); устойчивостью к обрыву сети дерево не является (§20.10).
//
//  Строится вызовом `Progression.nextSet` и ничего не решает само: дерево —
//  кеш ответа FitCore, и тест 20c обязан ловить расхождение кеша с источником
//  (§20.15). Поэтому здесь нет ни одной ветки с собственной арифметикой весов.
//
//  Живёт в FitAPI, а не в Server/: форму дерева видит фронтенд, а строит его
//  тот же код, который однажды понадобится iOS-экрану — там §9.3 вызывается
//  локально, и расходиться этим двум нельзя.

import FitCore

/// Состояние узла (§20.9) — тройка, а не пара: третья компонента появилась
/// вместе с лимитом калибровки §9.8. Счётчик нигде не хранится, он выражен
/// структурой дерева.
public struct TreeState: Sendable, Equatable, Hashable {
    /// `nil` — упражнение без веса (`ladder == .none`): квантовать нечего, и
    /// стартового веса не существует (§20.9).
    public var weightKg: Double?
    public var previousWasFailed: Bool
    public var calibrationIncreasesUsed: Int
}

/// Узел карты. `transitions` пуст у листа — либо кончились подходы, либо
/// ветка обрезана (`truncated`), либо упражнение завершилось досрочно.
public struct DecisionNode: Sendable, Equatable, Codable {
    /// Вес, который показывается на этот подход; `null` у упражнения без веса.
    public var weightKg: Double?
    /// Ветка обрезана по глубине: фронтенд, дойдя сюда, идёт на сервер
    /// (§20.9). Признак стоит на узле, а не один на всё дерево, потому что
    /// ветки сходятся на разной глубине.
    public var truncated: Bool
    /// Упражнение завершается досрочно — два `failed` подряд (§9.3).
    public var terminates: Bool
    /// Переход по (фидбэк, попадание повторов в диапазон) → идентификатор
    /// узла. Ключ — строка вида `easy_at_or_above_max`, потому что фактические
    /// повторы входят в решение предикатами, а не значением (§20.9).
    public var transitions: [String: String]

    enum CodingKeys: String, CodingKey {
        case weightKg = "weight_kg", truncated, terminates, transitions
    }
}

/// Дерево целиком (§20.9) — **карта состояний, а не вложенное дерево**.
///
/// Разница не косметическая. §20.9 обосновывает малый размер тем, что «ветки
/// сходятся: число различимых состояний растёт много медленнее». Это верно
/// ровно для различимых состояний: на четырёх переходах их 7–23 на реальных
/// лестницах. При вложенном кодировании то же самое разворачивается в 1483
/// узла — каждое состояние повторяется на каждом пути, которым в него можно
/// прийти. Поскольку §20.9 существует ради латентности и ни ради чего больше,
/// платить пятьюдесятью кратами размера ответа за вложенность нечем.
public struct DecisionTreeDTO: Sendable, Equatable, Codable {
    public var start: String
    public var nodes: [String: DecisionNode]
}

/// Предикат перехода §20.9: шесть веток, а не четыре.
public enum TreeBranch: String, Sendable, Equatable, CaseIterable {
    case failed
    case hardBelowRepMin = "hard_below_min"
    case hardAtOrAboveRepMin = "hard_at_or_above_min"
    case ok
    case easyBelowRepMax = "easy_below_max"
    case easyAtOrAboveRepMax = "easy_at_or_above_max"

    public var feedback: Feedback {
        switch self {
        case .failed: return .failed
        case .hardBelowRepMin, .hardAtOrAboveRepMin: return .hard
        case .ok: return .ok
        case .easyBelowRepMax, .easyAtOrAboveRepMax: return .easy
        }
    }

    /// Представитель класса повторов — любое число, удовлетворяющее предикату.
    /// Сама `nextSet` читает повторы только через сравнение с границами, и
    /// дерево обязано передавать ей ровно тот класс, который назвал.
    public func representativeReps(_ range: ClosedRange<Int>) -> Int {
        switch self {
        case .failed, .ok: return range.lowerBound
        case .hardBelowRepMin: return range.lowerBound - 1
        case .hardAtOrAboveRepMin: return range.lowerBound
        case .easyBelowRepMax: return range.upperBound - 1
        case .easyAtOrAboveRepMax: return range.upperBound
        }
    }
}

public enum DecisionTree {

    /// §19.2 п.19, §20.9: предохранитель, а не рабочий режим. Потолок подходов
    /// §7.3 — пять, и на реальных лестницах карта укладывается в десятки узлов.
    public static let maxNodes = 512

    /// Ключ узла — состояние ВМЕСТЕ с числом оставшихся подходов. Остаток
    /// входит в ключ не для порядка: переходы от состояния от него не зависят,
    /// а вот их наличие зависит, и слив состояния на разной глубине пометил бы
    /// обрезанным то, у которого подходы ещё есть.
    private struct NodeKey: Hashable {
        let state: TreeState
        let remaining: Int
    }

    /// Карта на оставшиеся подходы упражнения.
    ///
    /// `remainingSets` — сколько подходов ещё предстоит после текущего. Ноль
    /// даёт единственный узел: решать нечего.
    public static func build(
        weightKg: Double?,
        remainingSets: Int,
        range: ClosedRange<Int>,
        isCalibration: Bool,
        ladder: WeightLadder
    ) -> DecisionTreeDTO {
        var nodes: [String: DecisionNode] = [:]
        var ids: [NodeKey: String] = [:]
        // Идентификаторы выдаются по порядку первого посещения, а обход идёт по
        // `TreeBranch.allCases` — значит карта воспроизводима, и диф двух
        // ответов на одинаковом входе пуст.
        var nextID = 0

        func allocate(_ key: NodeKey) -> String? {
            if let existing = ids[key] { return existing }
            guard nodes.count < maxNodes else { return nil }
            let id = "n\(nextID)"
            nextID += 1
            ids[key] = id
            nodes[id] = DecisionNode(weightKg: key.state.weightKg, truncated: false,
                                     terminates: false, transitions: [:])
            return id
        }

        /// Единственный терминальный узел на всю карту: досрочное завершение
        /// ничем не отличается от ветки к ветке, и дублировать его незачем.
        var terminalID: String?
        func terminal() -> String? {
            if let terminalID { return terminalID }
            guard nodes.count < maxNodes else { return nil }
            let id = "n\(nextID)"
            nextID += 1
            terminalID = id
            nodes[id] = DecisionNode(weightKg: nil, truncated: false,
                                     terminates: true, transitions: [:])
            return id
        }

        func expand(_ key: NodeKey, id: String) {
            guard key.remaining > 0 else { return }
            var transitions: [String: String] = [:]
            for branch in TreeBranch.allCases {
                let outcome = Progression.nextSet(
                    priorFeedback: key.state.previousWasFailed ? .failed : nil,
                    // Упражнение без веса: `nextSet` всё равно вызывается —
                    // ветка «два failed подряд» осмысленна и для него, — но
                    // число, которое она вернёт, в карту не попадает.
                    current: key.state.weightKg ?? 0,
                    feedback: branch.feedback,
                    actualReps: branch.representativeReps(range),
                    range: range,
                    isCalibration: isCalibration,
                    calibrationIncreasesUsed: key.state.calibrationIncreasesUsed,
                    ladder: ladder
                )

                switch outcome {
                case .terminateExercise:
                    guard let target = terminal() else {
                        nodes[id]?.truncated = true
                        continue
                    }
                    transitions[branch.rawValue] = target
                case .nextWeight(let next):
                    let consumed = Progression.consumesCalibrationIncrease(
                        feedback: branch.feedback, actualReps: branch.representativeReps(range),
                        range: range, isCalibration: isCalibration,
                        calibrationIncreasesUsed: key.state.calibrationIncreasesUsed)
                    let childKey = NodeKey(
                        state: TreeState(
                            // Веса у упражнения без лестницы не бывает ни на
                            // одном узле: `roundToAchievable` при `.none`
                            // возвращает вход как есть, и отданное число
                            // означало бы вес там, где его нет.
                            weightKg: key.state.weightKg == nil ? nil : next,
                            previousWasFailed: branch.feedback == .failed,
                            calibrationIncreasesUsed: key.state.calibrationIncreasesUsed + (consumed ? 1 : 0)),
                        remaining: key.remaining - 1)
                    let known = ids[childKey] != nil
                    guard let childID = allocate(childKey) else {
                        // Места под новый узел нет: ветка обрывается здесь, и
                        // фронтенд с этого узла идёт на сервер.
                        nodes[id]?.truncated = true
                        continue
                    }
                    transitions[branch.rawValue] = childID
                    if !known { expand(childKey, id: childID) }
                }
            }
            nodes[id]?.transitions = transitions
        }

        let rootKey = NodeKey(
            state: TreeState(weightKg: weightKg, previousWasFailed: false, calibrationIncreasesUsed: 0),
            remaining: remainingSets)
        let rootID = allocate(rootKey)!
        expand(rootKey, id: rootID)
        return DecisionTreeDTO(start: rootID, nodes: nodes)
    }
}
