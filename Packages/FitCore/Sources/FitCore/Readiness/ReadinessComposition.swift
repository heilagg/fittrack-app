//  Композиция §10 поверх готовности: то, что Planner вызывает, а не
//  реализует заново (см. doc-комментарий Readiness.swift, «Выход»). Порядок
//  входов везде один — готовность посчитана первой, утомление (Recovery)
//  ложится на её результат и никогда не откатывается назад (сценарий 25).
extension Readiness {

    // MARK: - RIR (SPEC §10, «сумма, ограниченная сверху +1»)

    /// `readiness < 0.85` добавляет к целевому RIR, независимо от фазы.
    static func readinessRIRBump(readiness: Double) -> Int {
        readiness < 0.85 ? 1 : 0
    }

    /// Итоговый целевой RIR: `min(фаза + готовность, +1)` — сумма, а не
    /// максимум (иначе отрицательный фазовый вклад, §11.2, стирался бы в
    /// обычный день), — плюс надбавка утомления СВЕРХ потолка (§8.2, служит
    /// безопасности, а не подстройке под самочувствие дня, и потолком не
    /// ограничивается).
    ///
    /// `cycleState.periodization?.rirShift` уже несёт `phaseUnknown ? 0 : …`:
    /// оба состояния холодного старта возвращают `periodization == nil`
    /// (см. doc-комментарий `CycleState`), поэтому `?? 0` — не заглушка, а
    /// прямое чтение того же условия, что в `phaseUnknown(_:)`.
    public static func targetRIR(
        baseRIR: Int,
        readiness: Double,
        cycleState: CycleState,
        fatigueRIRBump: Int
    ) -> Int {
        let phaseRIR = cycleState.periodization?.rirShift ?? 0
        let rirFromPhaseAndReadiness = min(phaseRIR + readinessRIRBump(readiness: readiness), 1)
        return baseRIR + rirFromPhaseAndReadiness + fatigueRIRBump
    }

    // MARK: - Объём (SPEC §10, «срезы объёма не перемножаются»)

    /// Плановый недельный срез объёма мышцы — ровно один источник:
    /// фаза (`phases`, с опорной датой), 3+1 без фаз, либо 1.0, когда
    /// срезать нечем (без опорной даты). `isDeloadWeek` — решение
    /// планировщика (счётчик недель накопления/разгрузки), не этого модуля.
    public static func plannedVolumeFactor(cycleState: CycleState, isDeloadWeek: Bool) -> Double {
        switch cycleState.phaseMode {
        case .noPhases:
            return isDeloadWeek ? 0.85 : 1.0
        case .phases:
            // `hasAnchor == false` и `periodization == nil` совпадают
            // (см. doc-комментарий `CycleState`) — `?? 1.0` читает оба разом.
            return cycleState.periodization?.volumeMultiplier ?? 1.0
        }
    }

    /// Композиция планового среза с утомлением: «сильнейший», не
    /// произведение — иначе разгрузочная неделя/фаза И утомление наказывали
    /// бы одно и то же дважды (SPEC §10, «предельный случай», пол 0.7).
    /// Надбавку планового среза (`plannedFactor > 1.0`) получает только
    /// свежая мышца — ветвление, а не `min` целиком, иначе, например, ранняя
    /// лютеиновая (×1.15) на восстановленной мышце (×1.0) вернула бы 1.0 и
    /// убила бы фазовую надбавку.
    public static func volumeFactor(plannedFactor: Double, fatigueFactor: Double) -> Double {
        fatigueFactor < 1.0 ? min(plannedFactor, fatigueFactor) : plannedFactor
    }

    // MARK: - Вес упражнения (SPEC §10, «вес следует порогу RIR»)

    /// Готовность, применяемая к весу конкретного упражнения: надбавка выше
    /// 1.0 срезается, если хоть одна нагруженная мышца получила от утомления
    /// надбавку RIR (§8.2, `fatigue > 1.8` → `RecoveryAdjustment.targetRIRDelta
    /// > 0`). При частичном утомлении (0.8...1.8, `targetRIRDelta == 0`)
    /// надбавка остаётся — §8.2 разводит объём (режется непрерывно с 0.8) и
    /// интенсивность (защищается только за 1.8). Срез только сверху: день с
    /// низкой готовностью снижает вес на невосстановленной мышце так же, как
    /// на любой другой.
    public static func weightReadiness(
        readiness: Double,
        contributingMuscleAdjustments: [RecoveryAdjustment]
    ) -> Double {
        let anyMuscleGotFatigueRIRBump = contributingMuscleAdjustments.contains { $0.targetRIRDelta > 0 }
        return anyMuscleGotFatigueRIRBump ? min(readiness, 1.0) : readiness
    }

    // MARK: - ±1 подход на сессию (SPEC §10, «на сессию целиком»)

    /// Поправка подходов на сессию из самой готовности — прежде, чем решать,
    /// на какое упражнение она ляжет. Границы строгие: 0.9 и 1.05 сами
    /// поправки не дают.
    public static func sessionSetDelta(readiness: Double) -> Int {
        if readiness < 0.9 { return -1 }
        if readiness > 1.05 { return 1 }
        return 0
    }

    /// Куда ложится +1: только на упражнение, ни одна из нагруженных мышц
    /// которого не срезана утомлением — то же условие, что включает ветку
    /// `min` в `volumeFactor` (`fatigueFactor < 1.0`, здесь — `false` в
    /// `hasFatiguedMuscle`, в порядке сессии). Если такого упражнения нет,
    /// +1 не даётся вовсе (`nil`): выбор первого подходящего, а не любого —
    /// упражнения в `hasFatiguedMuscle` эквивалентны по этому правилу, и
    /// порядок брать неважно, но детерминированный выбор нужен для
    /// воспроизводимости (задокументированный выбор, не факт из SPEC).
    public static func exerciseForSessionSetIncrease(hasFatiguedMuscle: [Bool]) -> Int? {
        hasFatiguedMuscle.firstIndex(of: false)
    }

    /// Куда ложится −1: с упражнения, нагружающего самую утомлённую мышцу
    /// сессии (минимальный `volumeMultiplier` среди нагруженных им мышц —
    /// то же число, что определяет ветку `min` в `volumeFactor`); если
    /// утомлённых нет — с последнего по порядку сессии (изоляция, §7.3).
    /// Пустая сессия возвращает `nil` — снимать нечего.
    ///
    /// Если несколько упражнений нагружают равно утомлённую мышцу (одинаковый
    /// минимальный `volumeMultiplier`), −1 достаётся ПЕРВОМУ из них по
    /// порядку сессии — `indices.min(by:)` возвращает первый минимум при
    /// равенстве (в отличие от `max(by:)`, который вернул бы последний).
    /// Такое же зеркальное правило, что у выбора для `+1` выше (первый
    /// подходящий из равнозначных): упражнения с одинаковым
    /// `worstVolumeMultiplier` эквивалентны по этому правилу, и порядок брать
    /// неважно, но детерминированный выбор нужен для воспроизводимости
    /// (задокументированный выбор, не факт из SPEC — SPEC не разбирает случай
    /// нескольких равно-утомлённых упражнений).
    public static func exerciseForSessionSetDecrease(worstVolumeMultiplier: [Double]) -> Int? {
        guard !worstVolumeMultiplier.isEmpty else { return nil }
        if let mostFatigued = worstVolumeMultiplier.indices.min(by: {
            worstVolumeMultiplier[$0] < worstVolumeMultiplier[$1]
        }), worstVolumeMultiplier[mostFatigued] < 1.0 {
            return mostFatigued
        }
        return worstVolumeMultiplier.indices.last
    }
}
