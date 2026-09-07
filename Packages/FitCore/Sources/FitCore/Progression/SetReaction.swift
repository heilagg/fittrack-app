//  Реакция внутри сессии — следующий подход того же упражнения (SPEC §9.3).
//  Мгновенная: реагирует только на подход, который только что завершился, и
//  ничего не знает о прошлых сессиях (это уже BaselineUpdater).

/// Что делать с упражнением после только что завершённого подхода.
public enum SetOutcome: Sendable, Equatable {
    /// Вес для следующего подхода того же упражнения.
    case nextWeight(Double)
    /// Два `failed` подряд (SPEC §9.3): упражнение завершается досрочно,
    /// оставшиеся подходы снимаются. Перенос объёма на следующее упражнение —
    /// решение Planner, не Progression.
    case terminateExercise
}

public enum Progression {

    /// `priorFeedback` — фидбэк подхода, непосредственно предшествующего
    /// только что завершённому (`nil`, если только что завершённый подход —
    /// первый в упражнении за сессию). Нужен только для проверки «два
    /// failed подряд»; вся остальная реакция зависит исключительно от
    /// последнего подхода (SPEC §9.3 нарочно не использует более глубокую
    /// историю здесь — это работа `BaselineUpdater`).
    public static func nextSet(
        priorFeedback: Feedback?,
        current: Double,
        feedback: Feedback,
        actualReps: Int,
        range: ClosedRange<Int>,
        isCalibration: Bool,
        ladder: WeightLadder
    ) -> SetOutcome {
        if feedback == .failed && priorFeedback == .failed {
            return .terminateExercise
        }

        let raw: Double
        switch (feedback, actualReps) {
        case (.failed, _):
            raw = current * 0.90
        case (.hard, let r) where r < range.lowerBound:
            raw = current * 0.95
        case (.hard, _):
            raw = current
        case (.ok, _):
            raw = current
        case (.easy, let r) where r >= range.upperBound:
            // Калибровка: шаг вверх +15% вместо +5% (SPEC §9.8). Ограничение
            // «не больше 3 повышений за упражнение в калибровке» здесь не
            // учитывается — это счётчик на уровне сессии, которым
            // Progression не владеет (см. Progression.swift, раздел
            // «Сознательно не реализовано» в теле коммита).
            raw = isCalibration ? current * 1.15 : current * 1.05
        case (.easy, _):
            // Легко, но повторов ниже верха диапазона (в т.ч. пользователь
            // сам снизил вес и не добрал до rep_min) — добираем повторами,
            // вес не трогаем. SPEC §18, сценарий 9.
            raw = current
        }

        let direction: RoundDirection = raw < current ? .down : .up
        return .nextWeight(ladder.roundToAchievable(raw, direction: direction))
    }
}
