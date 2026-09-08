//  Типы данных Recovery: срез `muscle_fatigue` (SPEC §3.1) плюс вход одного
//  подхода в объёме, нужном для накопления утомления.

/// Утомление одной мышцы на момент времени — срез `muscle_fatigue`.
public struct FatigueState: Sendable, Equatable {
    public var value: Double
    public var updatedAt: Timestamp

    public init(value: Double = 0, updatedAt: Timestamp) {
        self.value = value
        self.updatedAt = updatedAt
    }
}

/// Вклад одного выполненного подхода в утомление — срез `sets`, необходимый
/// Recovery. `muscleLoad` — это уже `contribution[exercise][m] ×
/// fatigue_cost[exercise]` (SPEC §8.1) на каждую задействованную мышцу;
/// сами `contribution`/`fatigue_cost` — поля упражнения из FitContent,
/// от которого FitCore не зависит, поэтому их перемножает вызывающая
/// сторона, а не этот модуль.
public struct FatigueSet: Sendable, Equatable {
    public var muscleLoad: [MuscleSlug: Double]
    public var feedback: Feedback

    public init(muscleLoad: [MuscleSlug: Double], feedback: Feedback) {
        self.muscleLoad = muscleLoad
        self.feedback = feedback
    }
}

/// Порог восстановления мышцы (SPEC §8.1): `< 0.8` — восстановлена,
/// `0.8...1.8` — частично, `> 1.8` — не восстановлена.
public enum RecoveryStatus: Sendable, Equatable {
    case recovered
    case partial
    case notRecovered
}

/// Поправка к рекомендации из-за утомления мышцы (SPEC §8.2, §8.3).
public struct RecoveryAdjustment: Sendable, Equatable {
    public var targetRIRDelta: Int
    public var volumeMultiplier: Double

    public init(targetRIRDelta: Int, volumeMultiplier: Double) {
        self.targetRIRDelta = targetRIRDelta
        self.volumeMultiplier = volumeMultiplier
    }
}
