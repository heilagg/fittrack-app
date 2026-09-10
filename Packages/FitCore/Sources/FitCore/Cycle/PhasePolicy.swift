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
    ///
    /// Все четыре таблицы фазы — исчерпывающие `switch`, а не словари
    /// `[Phase: X]` с force-unwrap: `Phase` закрыт (SPEC §11.1 — пять
    /// сегментов), и новая фаза обязана не скомпилироваться, пока ей не
    /// назначили значение в каждой из четырёх, а не упасть в рантайме при
    /// первом обращении. Тот же довод и та же форма, что у
    /// `Recovery.fatigueHalfLifeHours(for:)` (SPEC §8.1).
    public static func volumeShift(for phase: Phase) -> Double {
        switch phase {
        case .menstrual: return -0.25
        case .follicular: return 0.10
        case .ovulatory: return 0.0
        case .earlyLuteal: return 0.15
        case .lateLuteal: return -0.15
        }
    }

    /// SPEC §11.2, столбец «Целевой RIR».
    public static func rirShift(for phase: Phase) -> Int {
        switch phase {
        case .menstrual: return 1
        case .follicular: return -1
        case .ovulatory: return -1
        case .earlyLuteal: return 0
        case .lateLuteal: return 1
        }
    }

    /// SPEC §11.2, столбец «Тип блока».
    public static func blockType(for phase: Phase) -> BlockType {
        switch phase {
        case .menstrual: return .recovery
        case .follicular: return .strength
        case .ovulatory: return .peak
        case .earlyLuteal: return .volumeAccumulation
        case .lateLuteal: return .deload
        }
    }

    /// `defaultAdjustment[P]` для формулы готовности (SPEC §11.2, §10) — вход
    /// для `effectiveReadinessAdjustment`, а не для этой таблицы объёма/RIR.
    public static func defaultReadinessAdjustment(for phase: Phase) -> Double {
        switch phase {
        case .menstrual: return -0.10
        case .follicular: return 0.05
        case .ovulatory: return 0.05
        case .earlyLuteal: return 0.00
        case .lateLuteal: return -0.07
        }
    }

    /// SPEC §11.2: `effectiveVolumeShift = volumeShift[P] × cycleConfidence`.
    public static func effectiveVolumeShift(phase: Phase, cycleConfidence: Double) -> Double {
        volumeShift(for: phase) * cycleConfidence
    }

    /// SPEC §11.2: `effectiveRIRShift = round(rirShift[P] × cycleConfidence)`,
    /// округление к ближайшему при ровной половине — от нуля (не банковское):
    /// на `cycleConfidence = 0.5` поправка обязана остаться ±1, а не стать 0.
    public static func effectiveRIRShift(phase: Phase, cycleConfidence: Double) -> Int {
        let shifted = Double(rirShift(for: phase)) * cycleConfidence
        return Int(shifted.rounded(.toNearestOrAwayFromZero))
    }

    /// SPEC §11.2: тип блока — категория, включается только при
    /// `cycleConfidence ≥ categoricalConfidenceThreshold`, иначе нейтральный.
    public static func effectiveBlockType(phase: Phase, cycleConfidence: Double) -> BlockType {
        cycleConfidence >= categoricalConfidenceThreshold ? blockType(for: phase) : .neutral
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
        let learned = profile.sampleSize >= phaseAdjustmentAppliesFromSampleSize ? profile.adjustment : 0
        return defaultReadinessAdjustment(for: phase) + learned
    }
}
