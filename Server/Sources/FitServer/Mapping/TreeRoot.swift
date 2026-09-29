//  Начальное состояние дерева решений §20.9 из журнала подходов
//  (SPEC §9.3, §9.8, §20.3, §20.6, §20.9).
//
//  Дерево строится заново после КАЖДОГО подхода, а состояние, которое ему нужно,
//  живёт в журнале, а не в дереве. Три компоненты, и у каждой свой источник
//  (§20.9):
//
//    вес                        `Progression.nextSet` на последнем записанном
//    был ли предыдущий `failed`  фидбэк последнего записанного
//    израсходованные повышения   сумма `consumesCalibrationIncrease` по сессии
//
//  ── `current` — это `actual_kg` ───────────────────────────────────────────
//
//  §20.9 после решения: реакция §9.3 — это реакция на подход, который человек
//  ДЕЙСТВИТЕЛЬНО сделал. Отсчитывать следующий вес от показанного там, где она
//  подняла другой, значит вернуть её к числу, которое она уже отвергла.
//  `prescribed_kg` при этом никуда не девается: от него считается `SetResult` и
//  демпфирование §9.6 между сессиями. Внутрисессионная реакция идёт от факта.
//
//  ── Подходы вне дерева состояния не двигают ───────────────────────────────
//
//  Пропуск и флаг боли (§8.4) лежат в журнале и не меняют ни одной из трёх
//  компонент. Пропуск не несёт фидбэка вовсе — «предыдущий был `failed`» про
//  него не определено ни в какую сторону; флаг боли запускает свою ветку, и
//  засчитывать его ещё и шагом прогрессии значит применить к одному событию два
//  правила. Абзац §20.9 про «что уводит с дерева» отвечает, когда клиенту идти
//  на сервер; этот — что сервер ответит, и ответы разные.
//
//  ── Своей арифметики весов здесь нет ──────────────────────────────────────
//
//  Ни одной. Вес двигает `nextSet`, счётчик — `consumesCalibrationIncrease`; обе
//  публичны в FitCore именно затем, чтобы веб и iOS считали одно и то же, а
//  тест 20c сверял дерево с источником, а не две копии одной формулы.

import FitCore

extension Mapping {

    /// Корень дерева §20.9 — то, с чем `DecisionTree.build` начинает.
    public struct TreeRoot: Sendable, Equatable {
        /// `nil` — упражнение без веса (`ladder == .none`): квантовать нечего.
        public var weightKg: Double?
        public var previousWasFailed: Bool
        public var calibrationIncreasesUsed: Int
        /// Упражнение уже завершилось досрочно — два `failed` подряд (§9.3).
        /// Дерева у него больше нет: решать нечего.
        public var terminated: Bool

        public init(weightKg: Double?, previousWasFailed: Bool,
                    calibrationIncreasesUsed: Int, terminated: Bool) {
            self.weightKg = weightKg
            self.previousWasFailed = previousWasFailed
            self.calibrationIncreasesUsed = calibrationIncreasesUsed
            self.terminated = terminated
        }
    }

    /// Состояние на следующий подход упражнения.
    ///
    /// `sets` — подходы ЭТОГО упражнения в ЭТОЙ сессии, в любом порядке:
    /// функция сортирует их по `set_index` сама, потому что «последний
    /// записанный» — это максимальный индекс, а порядок строк выборки его не
    /// гарантирует.
    ///
    /// `startWeightKg` — с чего упражнение началось (`workout_exercises
    /// .prescribed_kg`). Он же и есть корень, пока нет ни одного подхода на
    /// дереве. `nil` — упражнение без веса.
    public static func treeRoot(
        sets: [SetRow],
        startWeightKg: Double?,
        range: ClosedRange<Int>,
        isCalibration: Bool,
        ladder: WeightLadder
    ) -> TreeRoot {
        // Подходы, принадлежащие дереву: с фидбэком и повторами, не пропущенные
        // и без флага боли (§20.9).
        let onTree = sets
            .filter { !$0.skipped && !$0.painFlag && $0.feedback != nil && $0.actualReps != nil }
            .sorted { $0.setIndex < $1.setIndex }

        var weight = startWeightKg
        var previousWasFailed = false
        var used = 0

        for row in onTree {
            guard let feedback = Feedback(rawValue: row.feedback ?? ""),
                  let reps = row.actualReps
            else { continue }

            // `current` — фактический вес подхода (§20.9). Упражнение без веса
            // даёт 0: `nextSet` всё равно вызывается ради ветки «два failed
            // подряд», но её результат в вес не попадает.
            let current = row.actualKg ?? weight ?? 0
            let outcome = Progression.nextSet(
                priorFeedback: previousWasFailed ? .failed : nil,
                current: current,
                feedback: feedback,
                actualReps: reps,
                range: range,
                isCalibration: isCalibration,
                calibrationIncreasesUsed: used,
                ladder: ladder
            )
            // Счётчик продвигается тем же правилом, что и внутри `nextSet`, и
            // ПОСЛЕ вызова: она читает его состояние до этого подхода.
            if Progression.consumesCalibrationIncrease(
                feedback: feedback, actualReps: reps, range: range,
                isCalibration: isCalibration, calibrationIncreasesUsed: used) {
                used += 1
            }
            previousWasFailed = feedback == .failed

            switch outcome {
            case .terminateExercise:
                return TreeRoot(weightKg: weight, previousWasFailed: true,
                                calibrationIncreasesUsed: used, terminated: true)
            case .nextWeight(let next):
                // Вес обновляется только у весового упражнения: при
                // `ladder == .none` число, которое вернула `nextSet`, весом не
                // является (§20.9).
                weight = startWeightKg == nil ? nil : next
            }
        }

        return TreeRoot(weightKg: weight, previousWasFailed: previousWasFailed,
                        calibrationIncreasesUsed: used, terminated: false)
    }
}
