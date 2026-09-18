//  Расчётное время тренировки (SPEC §7.3, «Расчётное время»). Разминка и
//  заминка в `session_minutes` не входят; внутрисессионные надбавки таймера
//  тоже — бюджет оценивает план, а не настенные часы.

extension Planner {
    /// Работа в подходе — константа, пока не закрыт §9.5; ×2 на односторонних.
    public static let workSecondsPerSet = 40.0

    /// Множитель отдыха — ступенька на тех же порогах §10, что и ±1 подход на
    /// сессию: пороги берутся из `Readiness.Thresholds`, своих чисел у
    /// планировщика нет (§7.3, «новых порогов не вводим»). Тот же множитель
    /// читает таймер §13.3.
    public static func restFactor(readiness: Double) -> Double {
        if readiness < Readiness.Thresholds.setDecrease { return 1.2 }
        if readiness > Readiness.Thresholds.setIncrease { return 0.8 }
        return 1.0
    }

    /// `Σ (setup + подходы × работа + подходы × отдых) − отдых последнего`.
    /// Порядок — порядок сессии (он определяет последнее упражнение).
    static func estimatedSeconds(_ ordered: [(ExerciseCandidate, Int)], restFactor: Double) -> Double {
        guard let last = ordered.last else { return 0 }
        var total = 0.0
        for (candidate, sets) in ordered {
            let work = workSecondsPerSet * (candidate.unilateral ? 2 : 1)
            let rest = Double(candidate.defaultRestSeconds) * restFactor
            total += Double(candidate.setupSeconds) + Double(sets) * (work + rest)
        }
        return total - Double(last.0.defaultRestSeconds) * restFactor
    }
}
