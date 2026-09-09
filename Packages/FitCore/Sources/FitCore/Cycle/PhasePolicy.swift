//  PhasePolicy — таблица фазовой периодизации (SPEC §11.2) и овуляторное
//  ограничение по ударной нагрузке. Канал влияния фазы на ПОДБОР И ОБЪЁМ —
//  не единственный канал влияния фазы вообще (второй — `effectiveReadinessAdjustment`
//  ниже, входит в `phaseTerm` модуля Readiness, SPEC §10).
//
//  Числовые поправки (объём, RIR) масштабируются × confidence и никогда не
//  обнуляются скачком (SPEC §11.2, §11.3). Категориальные (тип блока) —
//  умножить не на что, поэтому гейтятся порогом `categoricalConfidenceThreshold`
//  (SPEC §11.2, §11.3): тот же порог, что разрешает интерфейсу назвать фазу.
extension Cycle {

    /// SPEC §11.3: порог, ниже которого категориальные решения нейтральны, а
    /// интерфейс не называет фазу. НЕ участвует в числовых поправках.
    public static let categoricalConfidenceThreshold = 0.3

    /// SPEC §11.2, столбец «Объём», как доля от базового (−0.25 = −25%).
    public static let volumeShift: [Phase: Double] = [
        .menstrual: -0.25,
        .follicular: 0.10,
        .ovulatory: 0.0,
        .earlyLuteal: 0.15,
        .lateLuteal: -0.15,
    ]

    /// SPEC §11.2, столбец «Целевой RIR».
    public static let rirShift: [Phase: Int] = [
        .menstrual: 1,
        .follicular: -1,
        .ovulatory: -1,
        .earlyLuteal: 0,
        .lateLuteal: 1,
    ]

    /// SPEC §11.2, столбец «Тип блока».
    public static let blockType: [Phase: BlockType] = [
        .menstrual: .recovery,
        .follicular: .strength,
        .ovulatory: .peak,
        .earlyLuteal: .volumeAccumulation,
        .lateLuteal: .deload,
    ]

    /// `defaultAdjustment[P]` для формулы готовности (SPEC §11.2, §10) — вход
    /// для `effectiveReadinessAdjustment`, а не для этой таблицы объёма/RIR.
    public static let defaultReadinessAdjustment: [Phase: Double] = [
        .menstrual: -0.10,
        .follicular: 0.05,
        .ovulatory: 0.05,
        .earlyLuteal: 0.00,
        .lateLuteal: -0.07,
    ]

    /// SPEC §11.2: `effectiveVolumeShift = volumeShift[P] × cycleConfidence`.
    public static func effectiveVolumeShift(phase: Phase, cycleConfidence: Double) -> Double {
        volumeShift[phase]! * cycleConfidence
    }

    /// SPEC §11.2: `effectiveRIRShift = round(rirShift[P] × cycleConfidence)`,
    /// округление к ближайшему при ровной половине — от нуля (не банковское):
    /// на `cycleConfidence = 0.5` поправка обязана остаться ±1, а не стать 0.
    public static func effectiveRIRShift(phase: Phase, cycleConfidence: Double) -> Int {
        let shifted = Double(rirShift[phase]!) * cycleConfidence
        return Int(shifted.rounded(.toNearestOrAwayFromZero))
    }

    /// SPEC §11.2: тип блока — категория, включается только при
    /// `cycleConfidence ≥ categoricalConfidenceThreshold`, иначе нейтральный.
    public static func effectiveBlockType(phase: Phase, cycleConfidence: Double) -> BlockType {
        cycleConfidence >= categoricalConfidenceThreshold ? blockType[phase]! : .neutral
    }

    /// SPEC §11.2: сведённый вклад фазы в подбор и объём на день с известной
    /// фазой (режим `phases`). `reason` несёт `cycleConfidence` для §14.6
    /// независимо от порога — решение «показывать ли фазу утвердительно»
    /// остаётся за слоем представления, а не зашивается здесь в отсутствие
    /// значения.
    public static func periodization(phase: Phase, cycleConfidence: Double) -> PhasePeriodization {
        PhasePeriodization(
            volumeMultiplier: 1.0 + effectiveVolumeShift(phase: phase, cycleConfidence: cycleConfidence),
            rirShift: effectiveRIRShift(phase: phase, cycleConfidence: cycleConfidence),
            blockType: effectiveBlockType(phase: phase, cycleConfidence: cycleConfidence),
            reason: .phasePeriodization(phase: phase, cycleConfidence: cycleConfidence)
        )
    }

    /// SPEC §11.2: «Осторожность в овуляторную фазу» — мягкий штраф в целевую
    /// функцию подбора (Planner, ещё не реализован) для упражнений с
    /// `impact = high`, только в овуляторной фазе. Масштабируется непрерывно
    /// × confidence, как и volume/RIR (SPEC §11.2: «числовые поправки»,
    /// сюда же по конструкции относится и эта, хоть таблица §11.2 её не
    /// перечисляет как строку — она описана отдельным абзацем как то же
    /// правило). Величина 0.3 — не значение из SPEC (там не задано число:
    /// раздел описывает штраф качественно, «снижает приоритет», Planner
    /// ещё не реализован и его весовая функция w1..w6 тоже без чисел в
    /// SPEC §7.3) — задокументированный выбор шкалы 0...1, которую Planner
    /// умножит на свой вес при интеграции; не факт из SPEC.
    public static func exerciseBias(phase: Phase, cycleConfidence: Double, impact: ExerciseImpact) -> (value: Double, reason: ReasonCode?) {
        guard phase == .ovulatory, impact == .high else { return (0, nil) }
        let maxPenalty = 0.3
        return (-maxPenalty * cycleConfidence, .ovulatoryImpactCaution(cycleConfidence: cycleConfidence))
    }

    /// SPEC §11.2/§11.4: `effectivePhaseAdjustment = defaultAdjustment[P] +
    /// profile[P].adjustment`, но личный сдвиг применяется только начиная с
    /// `sampleSize ≥ 3` (SPEC §11.4) — до этого выборка слишком мала, чтобы
    /// профилю можно было доверять.
    public static func effectiveReadinessAdjustment(phase: Phase, profile: PhaseResponseProfile) -> Double {
        let learned = profile.sampleSize >= 3 ? profile.adjustment : 0
        return defaultReadinessAdjustment[phase]! + learned
    }
}
