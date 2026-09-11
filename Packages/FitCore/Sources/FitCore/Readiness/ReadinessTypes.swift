//  Типы данных Readiness: срез `daily_checkins` (SPEC §3.1), нужный формуле
//  §10, кроме `override` — тот читается отдельно (см. doc-комментарий
//  `CycleState`, почему оверрайд не проходит через `CycleState`).

/// Компоненты ежедневного чек-ина (SPEC §10) — `energy`, `soreness`,
/// `sleep_quality`, `stress` из `daily_checkins`, каждый 1...5 или `nil`.
///
/// Чек-ин сворачиваемый (SPEC §13.1): любое поле может быть не заполнено, а
/// строки за день может не быть вовсе. Оба случая неотличимы для формулы —
/// `DailyCheckin()` (все поля `nil`) корректно представляет «строки нет» и
/// не нуждается в отдельном `Optional<DailyCheckin>` на вызывающей стороне.
public struct DailyCheckin: Sendable, Equatable {
    public var energy: Int?
    public var soreness: Int?
    public var sleepQuality: Int?
    public var stress: Int?

    public init(energy: Int? = nil, soreness: Int? = nil, sleepQuality: Int? = nil, stress: Int? = nil) {
        self.energy = energy
        self.soreness = soreness
        self.sleepQuality = sleepQuality
        self.stress = stress
    }
}
