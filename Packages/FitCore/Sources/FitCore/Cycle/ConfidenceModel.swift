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
        let center = mean(of: values)
        let variance = values.reduce(0.0) { $0 + (Double($1) - center) * (Double($1) - center) } / Double(values.count)
        return variance.squareRoot()
    }

    /// Среднее по окну длин — общее для `standardDeviation` и
    /// `LengthEstimator.expectedLength`, чтобы σ и прогноз всегда описывали
    /// один и тот же центр одного и того же окна. `values` не пуст: оба
    /// вызывающих проверяют это до вызова.
    static func mean(of values: [Int]) -> Double {
        Double(values.reduce(0, +)) / Double(values.count)
    }

    /// Ступени σ из таблицы §11.3 — разброс ВСЕГО набора. Не путать с
    /// `outlierBandFloorDays`: то расстояние одной точки до медианы, и оно
    /// отдельная константа именно потому, что мерит другое.
    public static let regularSigmaDays = 2.0
    public static let variableSigmaDays = 5.0
    /// Средняя ступень таблицы — и потолок для разбросанного окна.
    public static let variableRegularityFactor = 0.7

    /// SPEC §11.3: `window` — то же окно, что и у
    /// `LengthEstimator.expectedLength` (последние 6), вместе с его
    /// неотфильтрованной версией.
    ///
    /// **Фильтр улучшает прогноз, но не делает разброс регулярным.** База
    /// считается по отфильтрованным длинам: выброс не должен портить оценку.
    /// Но выброшенное значение делает остаток ТЕСНЕЕ обычного, и σ выходит не
    /// просто низкой, а близкой к нулю — у 28, 28, 28, 28, 28, 40 остаются пять
    /// одинаковых циклов и σ = 0.00, арифметический максимум регулярности.
    /// Поэтому потолок: если σ по НЕОТФИЛЬТРОВАННОМУ окну вышла за границу
    /// регулярного, верхняя ступень запрещена.
    ///
    /// Потолок ключуется на σ набора, а НЕ на факте исключения. Исключение —
    /// расстояние точки до медианы, а таблица мерит разброс набора; история
    /// 28, 28, 28, 28, 28, 31 теряет 31 из окна, но её σ = 1.12, и таблица
    /// зовёт её регулярной — потолок здесь не срабатывает.
    ///
    /// Потолок останавливается на 0.7 и не идёт следом за неотфильтрованной σ
    /// до 0.4: у 27, 28, 28, 29, 45 она равна 6.83, то есть нижний разряд —
    /// тот же, что у скачущей 45/20/44/21/46/19. Четыре ровных цикла и один
    /// сбой — не то же самое.
    ///
    /// Про независимость множителей (SPEC §11.5): на по-настоящему
    /// разбросанной истории потолок и `predictionMissFactor` отвечают на один и
    /// тот же аномальный цикл. Принято сознательно — в отличие от версии, где
    /// потолок ключевался на исключении и дотягивался до одиночного отклонения
    /// в 3 дня, выключая фазы дрейфующей 28, 28, 28, 32, 33, 34 на цикл.
    public static func regularityFactor(window: CycleWindow, declaredRegularity: DeclaredRegularity?) -> Double {
        let base: Double
        if window.lengths.count >= 2 {
            let sigma = standardDeviation(of: window.lengths)
            if sigma <= regularSigmaDays { base = 1.0 }
            else if sigma <= variableSigmaDays { base = variableRegularityFactor }
            else { base = 0.4 }
        } else {
            switch declaredRegularity {
            case .regular, .none: base = 1.0
            case .variable: base = variableRegularityFactor
            case .irregular: base = 0.4
            }
        }
        let dispersed = standardDeviation(of: window.unfiltered) > regularSigmaDays
        return dispersed ? min(base, variableRegularityFactor) : base
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
                window: recentWindow(known),
                declaredRegularity: profile.declaredRegularity
            ),
            missFactor: predictionMissFactor(
                actualLength: closedLength,
                predictedLength: expectedLength(measuredLengths: priorLengths, profile: profile)
            )
        )
    }

    /// Уверенность на закрытии для измеренных циклов с индекса `start` и
    /// дальше, в хронологическом порядке. Единственное место, где перебираются
    /// закрытия: и `confidenceAtEachClose`, и `applyingClosedCycles` идут
    /// через него, чтобы понятие «измеренное закрытие» и нарезка
    /// `priorLengths` не разошлись между двумя копиями цикла.
    ///
    /// Прогноз для каждого закрытия — по ВСЕМ предшествующим измеренным, а не
    /// только по тем, что начинаются со `start`: судим цикл по прогнозу,
    /// который существовал на момент его начала.
    static func confidencesAtClose(lengths: [Int], from start: Int, profile: CycleProfile) -> [Double] {
        (start..<lengths.count).map { i in
            confidenceAtClose(
                priorLengths: Array(lengths.prefix(i)),
                closedLength: lengths[i],
                profile: profile
            )
        }
    }

    /// Те же величины по одной на каждый измеренный цикл, в хронологическом
    /// порядке — история счётчика, а не текущее состояние.
    static func confidenceAtEachClose(events: [CycleEvent], profile: CycleProfile) -> [Double] {
        confidencesAtClose(lengths: measuredLengths(from: events), from: 0, profile: profile)
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
    /// затирал бы ручные переключения режима (см. `switchingToPhases`,
    /// `switchingToNoPhases`).
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

        var updated = confidencesAtClose(lengths: cycles.map(\.length), from: pendingFrom, profile: profile)
            .reduce(profile) { applyingCycleClose(confidence: $1, to: $0) }
        updated.lowConfidenceCountedThrough = cycles[cycles.count - 1].closedOn
        return updated
    }

    /// Общая часть обоих направлений ручного переключения (SPEC §11.5,
    /// «доступно в настройках в любой момент»): выставить режим, обнулить
    /// серию и сдвинуть отметку учёта на день переключения, чтобы «три подряд»
    /// считалось заново, а не унаследованным от состояния до переключения.
    ///
    /// Без сброса серия переживала переключение: пользовательница, которую
    /// автоматика увела в режим без фаз (серия = 3), включала фазы обратно и
    /// теряла их снова на ПЕРВОМ же плохом закрытии — одном вместо трёх.
    /// Сброс живёт здесь, а не в вызывающем коде, потому что этой машиной
    /// состояний владеет FitCore: снаружи о ней пришлось бы помнить.
    ///
    /// **Вызов, который ничего не меняет, — не переключение.** Если режим и
    /// причина уже те, что просят, профиль возвращается как есть. Иначе экран
    /// настроек, пересохраняющий неизменённый переключатель, обнулял бы
    /// набирающуюся серию и сдвигал отметку учёта вперёд — а закрытие, пришедшее
    /// позже с датой между старой отметкой и этим пересохранением, так и не было
    /// бы учтено, хотя никакого переключения не было и считаться оно должно.
    ///
    /// **Закрытия до переключения в новую серию не идут — даже не пропущенные
    /// через `applyingClosedCycles`.** Это не потеря, а SPEC §11.5: «три подряд»
    /// после переключения — это три закрытия ПОСЛЕ него. Поэтому здесь нет
    /// параметра `events` и не нужно сначала досчитывать накопившееся: всё, что
    /// такой досчёт может изменить (серию, режим через автопереход, отметку),
    /// переключение тут же перезаписывает, так что результат совпадает
    /// побитово — это закреплено тестом, а не только этим абзацем.
    ///
    /// Отметка — именно ДЕНЬ переключения, а не дата последнего записанного
    /// закрытия. Только так отсекается закрытие задним числом или пришедшее с
    /// опозданием (§4.3), случившееся до переключения: при отметке на последнем
    /// записанном закрытии период 62-го дня, внесённый после переключения на
    /// 70-й, вошёл бы в новую серию.
    private static func switchingMode(
        to mode: PhaseMode,
        reason: NoPhaseReason?,
        in profile: CycleProfile,
        asOf today: CalendarDay
    ) -> CycleProfile {
        guard profile.phaseMode != mode || profile.noPhaseReason != reason else { return profile }
        var profile = profile
        profile.phaseMode = mode
        profile.noPhaseReason = reason
        profile.lowConfidenceStreak = 0
        profile.lowConfidenceCountedThrough = today
        return profile
    }

    /// Ручное включение режима `phases`. Без параметра `reason` — раньше он
    /// был опциональным на оба направления сразу, и `.noPhases` с `reason: nil`
    /// компилировался и создавал состояние, из которого нет автоматического
    /// выхода: `applyingCycleClose` снимает только `.lowConfidence`, а `nil` не
    /// входит ни в одну из семи причин SPEC §11.5. Разведение по направлению
    /// делает эту комбинацию непредставимой, а не только недокументированной.
    /// Семантику сброса и почему повторный вызов — no-op, см. `switchingMode`.
    public static func switchingToPhases(in profile: CycleProfile, asOf today: CalendarDay) -> CycleProfile {
        switchingMode(to: .phases, reason: nil, in: profile, asOf: today)
    }

    /// Ручное включение режима `no_phases` — `reason` обязателен и без
    /// значения по умолчанию: SPEC §11.5 перечисляет ровно семь причин, и у
    /// режима без фаз не бывает состояния «без причины».
    ///
    /// Смена одной лишь причины — переключение: автоматическая `.lowConfidence`
    /// → явная `.userChoice` переводит её из самоснимаемого состояния в
    /// снимаемое только вручную. Сброс серии там безвреден — в режиме без фаз
    /// её никто не читает.
    public static func switchingToNoPhases(reason: NoPhaseReason, in profile: CycleProfile, asOf today: CalendarDay) -> CycleProfile {
        switchingMode(to: .noPhases, reason: reason, in: profile, asOf: today)
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
