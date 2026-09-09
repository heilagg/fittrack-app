//  ConfidenceModel — cycleConfidence = dataFactor × regularityFactor ×
//  recencyFactor (SPEC §11.3), плюс автоматический переход в режим без фаз
//  по счётчику `low_confidence_streak` (SPEC §11.5).
//
//  «Заявленное работает, пока нет измеренного»: regularityFactor читает
//  declaredRegularity только когда отфильтрованных длин меньше двух — на
//  одной длине σ не существует. Как только измерений достаточно, заявленное
//  не участвует вовсе, даже если оно есть.
extension Cycle {

    /// SPEC §11.3: сколько всего измерено циклов, без верхнего окна —
    /// отвечает на вопрос «сколько накоплено истории», а не «какой цикл
    /// ожидается» (см. SPEC §11.3, «Область подсчёта»).
    public static func dataFactor(measuredCount: Int) -> Double {
        switch measuredCount {
        case 0: return 0.3
        case 1: return 0.5
        case 2: return 0.7
        default: return 1.0
        }
    }

    /// Выборочное σ (население, а не оценка по выборке: описываем разброс
    /// именно этого наблюдённого набора, а не экстраполируем на большую
    /// популяцию) — задокументированный выбор, см. описание PR.
    static func standardDeviation(of values: [Int]) -> Double {
        guard values.count > 1 else { return 0 }
        let doubles = values.map(Double.init)
        let mean = doubles.reduce(0, +) / Double(doubles.count)
        let variance = doubles.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(doubles.count)
        return variance.squareRoot()
    }

    /// SPEC §11.3: `filteredLengths` — то же отфильтрованное окно, что и
    /// `LengthEstimator.expectedLength` (последние 6, минус выбросы).
    public static func regularityFactor(filteredLengths: [Int], declaredRegularity: DeclaredRegularity?) -> Double {
        if filteredLengths.count >= 2 {
            let sigma = standardDeviation(of: filteredLengths)
            if sigma <= 2 { return 1.0 }
            if sigma <= 5 { return 0.7 }
            return 0.4
        }
        switch declaredRegularity {
        case .regular, .none: return 1.0
        case .variable: return 0.7
        case .irregular: return 0.4
        }
    }

    /// SPEC §11.3: `cycleDay`/`expectedLength` — текущий день цикла и прогноз
    /// его длины. `cycleDay <= expectedLength` — в пределах ожидаемого окна.
    public static func recencyFactor(cycleDay: Int, expectedLength: Int) -> Double {
        let overdue = cycleDay - expectedLength
        switch overdue {
        case ..<1: return 1.0
        case 1...3: return 0.6
        case 4...7: return 0.3
        default: return 0.0
        }
    }

    /// SPEC §11.3: произведение трёх множителей.
    public static func cycleConfidence(dataFactor: Double, regularityFactor: Double, recencyFactor: Double) -> Double {
        dataFactor * regularityFactor * recencyFactor
    }

    /// Уверенность, зафиксированная в момент закрытия цикла (SPEC §11.5,
    /// `low_confidence_streak`) — по одной на каждый измеренный цикл, в
    /// хронологическом порядке. `recencyFactor` в момент закрытия равен 1:
    /// свежий `period_start` по определению не просрочен, просрочка —
    /// понятие для ЕЩЁ ОТКРЫТОГО цикла (см. `recencyFactor` выше), а не для
    /// того, что только что завершился день в день.
    public static func confidenceAtEachClose(events: [CycleEvent], profile: CycleProfile) -> [Double] {
        let lengths = measuredLengths(from: events)
        guard !lengths.isEmpty else { return [] }
        return (1...lengths.count).map { i in
            let prefix = Array(lengths.prefix(i))
            let df = dataFactor(measuredCount: prefix.count)
            let rf = regularityFactor(
                filteredLengths: recentFilteredLengths(prefix),
                declaredRegularity: profile.declaredRegularity
            )
            return cycleConfidence(dataFactor: df, regularityFactor: rf, recencyFactor: 1.0)
        }
    }

    /// SPEC §11.5: инкремент/сброс `low_confidence_streak` на закрытии
    /// одного цикла, и авто-переход в/из режима без фаз по этому счётчику.
    ///
    /// Счётчик копится независимо от текущей причины режима без фаз (это
    /// бухгалтерия качества данных, SPEC не оговаривает исключений), но сам
    /// АВТОПЕРЕХОД однонаправленно защищён: включается только из `.phases`
    /// (никогда не подменяет собой ручную причину вроде `.contraception`),
    /// выключается только когда текущая причина — именно `.lowConfidence`
    /// (SPEC §11.5: «только low_confidence снимается сам»).
    public static func applyingCycleClose(confidence: Double, to profile: CycleProfile) -> CycleProfile {
        var profile = profile
        if confidence >= 0.3 {
            profile.lowConfidenceStreak = 0
            if profile.noPhaseReason == .lowConfidence {
                profile.phaseMode = .phases
                profile.noPhaseReason = nil
            }
        } else {
            profile.lowConfidenceStreak += 1
            if profile.lowConfidenceStreak >= 3, profile.phaseMode == .phases {
                profile.phaseMode = .noPhases
                profile.noPhaseReason = .lowConfidence
            }
        }
        return profile
    }
}
