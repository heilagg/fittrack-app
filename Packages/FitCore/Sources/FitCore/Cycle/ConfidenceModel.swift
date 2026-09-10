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

    /// Ступени промаха в днях, общие для `recencyFactor` (§11.3) и
    /// `predictionMissFactor` (§11.5): 0 → 1.0, 1–3 → 0.6, 4–7 → 0.3,
    /// дальше 0.0. В одном месте, чтобы правка ступеней не разъехалась по двум.
    private static func missBucket(days: Int) -> Double {
        switch days {
        case ..<1: return 1.0
        case 1...3: return 0.6
        case 4...7: return 0.3
        default: return 0.0
        }
    }

    /// SPEC §11.3: `cycleDay`/`expectedLength` — текущий день цикла и прогноз
    /// его длины. `cycleDay <= expectedLength` — в пределах ожидаемого окна.
    ///
    /// Направление ОДНО, и это не оплошность: величина про ЕЩЁ ОТКРЫТЫЙ цикл,
    /// где «раньше прогноза» не наблюдаемо в принципе — день цикла просто ещё
    /// не дошёл до предсказанной длины. Считать здесь по модулю (как на
    /// закрытии, `predictionMissFactor`) значило бы, что на пятый день цикла
    /// при прогнозе 28 промах равен 23 дням: уверенность падала бы в ноль почти
    /// у всех и почти всё время. Симметрия этих двух величин — регресс, а не
    /// унификация (SPEC §11.5, последний абзац про закрытие).
    public static func recencyFactor(cycleDay: Int, expectedLength: Int) -> Double {
        missBucket(days: cycleDay - expectedLength)
    }

    /// SPEC §11.5: насколько закрывшийся цикл промахнулся мимо собственного
    /// прогноза — по модулю, в обе стороны.
    ///
    /// Цикл, пришедший на две недели раньше предсказанного, говорит о
    /// непредсказуемости ровно то же, что и задержавшийся на две недели. Тот же
    /// принцип, по которому `regularityFactor` меряет σ, а не среднее
    /// отклонение вверх.
    ///
    /// Односторонняя версия ещё и вела себя неустойчиво на тех, ради кого
    /// правило §11.5 существует: при чередовании 20 / 45 / 20 / 45 короткие
    /// закрытия читались как «пришло вовремя» (0.40 на третьем закрытии) и
    /// обнуляли серию, так что режим без фаз не включался никогда — при том что
    /// прогноз не сбылся ни разу.
    public static func predictionMissFactor(actualLength: Int, predictedLength: Int) -> Double {
        missBucket(days: abs(actualLength - predictedLength))
    }

    /// SPEC §11.3: произведение трёх множителей.
    ///
    /// Третий назван нейтрально: на живом пути это `recencyFactor` (§11.3,
    /// односторонний), на закрытии — `predictionMissFactor` (§11.5, по модулю).
    /// Под именем `recencyFactor:` вызов на закрытии выглядел бы как ошибка,
    /// которую хочется «починить» обратно — а это ровно возврат к мёртвой
    /// арифметике, из-за которой правило §11.5 не срабатывало никогда.
    public static func cycleConfidence(dataFactor: Double, regularityFactor: Double, missFactor: Double) -> Double {
        dataFactor * regularityFactor * missFactor
    }

    /// Уверенность, зафиксированная в момент закрытия ОДНОГО цикла
    /// (SPEC §11.5, `low_confidence_streak`).
    ///
    /// `priorLengths` — история ДО этого цикла, `closedLength` — фактическая
    /// длина только что закрывшегося. `dataFactor`/`regularityFactor` считаются
    /// по истории ВКЛЮЧАЯ его, а `recencyFactor` — сравнением его фактической
    /// длины с прогнозом, который существовал ДО его начала.
    ///
    /// Почему не `recencyFactor = 1` (свежая менструация ведь не просрочена):
    /// тогда правило §11.5 не срабатывает никогда. С третьего измеренного цикла
    /// `dataFactor` = 1.0, `regularityFactor` ≥ 0.4, произведение ≥ 0.40 — серия
    /// обнуляется на каждом третьем закрытии и до трёх не доходит. Разобрано в
    /// SPEC §11.5 («Уверенность на закрытии считается не так, как сегодняшняя»),
    /// туда же вынесен и численный разбор.
    ///
    /// Промах считается по модулю (`predictionMissFactor`): цикл, пришедший
    /// раньше прогноза, промахнулся так же, как задержавшийся.
    static func confidenceAtClose(priorLengths: [Int], closedLength: Int, profile: CycleProfile) -> Double {
        let known = priorLengths + [closedLength]
        return cycleConfidence(
            dataFactor: dataFactor(measuredCount: known.count),
            regularityFactor: regularityFactor(
                filteredLengths: recentFilteredLengths(known),
                declaredRegularity: profile.declaredRegularity
            ),
            missFactor: predictionMissFactor(
                actualLength: closedLength,
                predictedLength: expectedLength(measuredLengths: priorLengths, profile: profile)
            )
        )
    }

    /// Те же величины по одной на каждый измеренный цикл, в хронологическом
    /// порядке — история счётчика, а не текущее состояние.
    static func confidenceAtEachClose(events: [CycleEvent], profile: CycleProfile) -> [Double] {
        let lengths = measuredLengths(from: events)
        guard !lengths.isEmpty else { return [] }
        return lengths.indices.map { i in
            confidenceAtClose(
                priorLengths: Array(lengths.prefix(i)),
                closedLength: lengths[i],
                profile: profile
            )
        }
    }

    /// SPEC §11.5: досчитать серию по всем закрытиям, которые ещё не учтены —
    /// счётчик `low_confidence_streak` и авто-переход в/из режима без фаз.
    /// Единственная публичная точка входа этого механизма.
    ///
    /// Учитываются измеренные циклы, закрывшиеся СТРОГО ПОЗЖЕ
    /// `profile.lowConfidenceCountedThrough`; отметка передвигается на дату
    /// последнего учтённого. Отсюда три свойства, которых раньше не было:
    ///
    ///  - Повторный вызов — no-op. «Ровно один раз на закрытие» больше не
    ///    обязанность вызывающего: §4.3 offline-first доставляет одно и то же
    ///    событие дважды, и второй раз теперь ничего не досчитывает.
    ///  - Перерыв длиннее 90 дней не двигает ничего: он не измеренный цикл
    ///    (§11.3), значит и закрытия в нём нет. Раньше `measuredLengths.last`
    ///    после перерыва указывал на ДОперерывный цикл, и тот учитывался второй
    ///    раз — у той самой пользовательницы, ради которой правило 90 дней и
    ///    введено.
    ///  - Отметка задним числом раньше отметки учёта пропускается, а не
    ///    пересчитывается.
    ///
    /// Предел точности, оговорённый и в SPEC §11.5: отметка задним числом,
    /// РАЗРЕЗАЮЩАЯ уже учтённый интервал (28 → 14 + 14), оставляет прежний учёт
    /// как есть. Отменить его мог бы только пересчёт всей истории с нуля, а он
    /// затирал бы ручные переключения режима (см. `switchingPhaseMode`).
    ///
    /// Почему счётчик вообще персистентный, а не свёртка по всей истории, как
    /// `Progression.rebuildStates`: пересчёт с нуля перетирал бы решение
    /// пользовательницы. Режим переключается вручную в любой момент (SPEC
    /// §11.5), а ручное включение фаз пишет `no_phase_reason = NULL` — от
    /// «никогда не была в режиме без фаз» это по схеме §3.1 не отличить.
    /// Пользователь главнее модели, поэтому источник истины — сохранённый
    /// профиль.
    public static func applyingClosedCycles(events: [CycleEvent], profile: CycleProfile) -> CycleProfile {
        let cycles = measuredCycles(from: events)
        let pendingFrom = profile.lowConfidenceCountedThrough
            .map { watermark in cycles.firstIndex { $0.closedOn > watermark } ?? cycles.count }
            ?? 0
        guard pendingFrom < cycles.count else { return profile }

        var updated = profile
        let lengths = cycles.map(\.length)
        for i in pendingFrom..<cycles.count {
            updated = applyingCycleClose(
                confidence: confidenceAtClose(
                    // Прогноз, существовавший ДО этого цикла, — по всем
                    // предшествующим измеренным, а не только по неучтённым.
                    priorLengths: Array(lengths.prefix(i)),
                    closedLength: cycles[i].length,
                    profile: profile
                ),
                to: updated
            )
        }
        updated.lowConfidenceCountedThrough = cycles[cycles.count - 1].closedOn
        return updated
    }

    /// SPEC §11.5: ручное переключение режима фаз («доступно в настройках в
    /// любой момент»). Обнуляет серию и сдвигает отметку учёта на день
    /// переключения, поэтому «три подряд» после ручного включения фаз означает
    /// три закрытия ПОСЛЕ этого выбора.
    ///
    /// Без сброса серия переживала переключение: пользовательница, которую
    /// автоматика увела в режим без фаз (серия = 3), включала фазы обратно и
    /// теряла их снова на ПЕРВОМ же плохом закрытии — одном вместо трёх.
    /// Сброс живёт здесь, а не в вызывающем коде, потому что этой машиной
    /// состояний владеет FitCore: снаружи о ней пришлось бы помнить.
    public static func switchingPhaseMode(
        to mode: PhaseMode,
        reason: NoPhaseReason?,
        in profile: CycleProfile,
        asOf today: CalendarDay
    ) -> CycleProfile {
        var profile = profile
        profile.phaseMode = mode
        profile.noPhaseReason = mode == .phases ? nil : reason
        profile.lowConfidenceStreak = 0
        profile.lowConfidenceCountedThrough = today
        return profile
    }

    /// SPEC §11.5: инкремент/сброс `low_confidence_streak` на закрытии
    /// одного цикла, и авто-переход в/из режима без фаз по этому счётчику.
    ///
    /// Internal, а не public: наружу торчит `applyingClosedCycles`, который сам
    /// считает нужную уверенность и следит за тем, что уже учтено. Голый `Double` в публичной сигнатуре
    /// приглашал бы передать сюда сегодняшний `cycleConfidence` — по типу
    /// неотличимый, по смыслу другой (см. `confidenceAtClose`).
    ///
    /// Счётчик копится независимо от текущей причины режима без фаз (это
    /// бухгалтерия качества данных, SPEC не оговаривает исключений), но сам
    /// АВТОПЕРЕХОД однонаправленно защищён: включается только из `.phases`
    /// (никогда не подменяет собой ручную причину вроде `.contraception`),
    /// выключается только когда текущая причина — именно `.lowConfidence`
    /// (SPEC §11.5: «только low_confidence снимается сам»).
    static func applyingCycleClose(confidence: Double, to profile: CycleProfile) -> CycleProfile {
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
