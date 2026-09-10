//  Cycle — контракт SPEC §11, тесты для сценариев §18, закрытых этим
//  модулем (см. doc-комментарий Cycle.swift): 15, 15a, 15b, 16, 17, 18, 18a,
//  19, 19a, 20, 21, 22, 23c, 24, 24b, 24c, 26. Сценарии 23, 23a (частично),
//  23b (частично), 24a, 25, 25a, 25b, 25c комбинируют выход этого модуля с
//  формулой готовности (SPEC §10) и относятся к Readiness — здесь их нет.
//
//  XCTest, а не Swift Testing — окружение только с Command Line Tools
//  (`swift test` падает на `no such module`), логика прогнана вручную через
//  временный executable, см. implement-feature §5.

import XCTest
@testable import FitCore

final class CycleTests: XCTestCase {

    private func day(_ n: Int) -> CalendarDay {
        CalendarDay(year: 2026, month: 1, day: 1).adding(days: n)
    }

    private func starts(_ gaps: [Int], from base: Int = 0) -> [CycleEvent] {
        var d = base
        var result = [CycleEvent(kind: .periodStart, occurredOn: day(d))]
        for gap in gaps {
            d += gap
            result.append(CycleEvent(kind: .periodStart, occurredOn: day(d)))
        }
        return result
    }

    // MARK: - Сценарий 15: ноль измеренных циклов, заявленная регулярность

    func test_scenario15_zeroMeasuredCyclesRegularDeclared() {
        let events = [CycleEvent(kind: .periodStart, occurredOn: day(0))]
        let profile = CycleProfile(declaredRegularity: .regular)
        let state = Cycle.state(events: events, profile: profile, responseProfiles: [:], asOf: day(0))

        XCTAssertEqual(state.cycleConfidence!, 0.30, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(state.cycleConfidence!, Cycle.categoricalConfidenceThreshold,
            "заявлена regular — фаза показывается")
        XCTAssertEqual(state.periodization?.blockType, .recovery, "категория включена на пороге")
    }

    func test_scenario15_zeroMeasuredCyclesIrregularDeclared() {
        let events = [CycleEvent(kind: .periodStart, occurredOn: day(0))]
        let profile = CycleProfile(declaredRegularity: .irregular)
        let state = Cycle.state(events: events, profile: profile, responseProfiles: [:], asOf: day(0))

        XCTAssertEqual(state.cycleConfidence!, 0.12, accuracy: 0.0001)
        XCTAssertLessThan(state.cycleConfidence!, Cycle.categoricalConfidenceThreshold,
            "заявлена irregular — фаза не показывается")
        XCTAssertEqual(state.periodization?.blockType, .neutral, "ниже порога — категория нейтральна")
        XCTAssertNotEqual(state.periodization?.volumeMultiplier, 1.0,
            "но числовая поправка не обнулена, а масштабирована")
        XCTAssertEqual(state.periodization!.volumeMultiplier, 1.0 - 0.25 * 0.12, accuracy: 0.0001)
    }

    // MARK: - Сценарий 15a: опорной даты нет вовсе

    func test_scenario15a_noAnchorAtAll() {
        let state = Cycle.state(events: [], profile: CycleProfile(), responseProfiles: [:], asOf: day(0))

        XCTAssertEqual(state.phaseMode, .phases, "режим остаётся phases")
        XCTAssertFalse(state.hasAnchor)
        XCTAssertNil(state.phase)
        XCTAssertNil(state.cycleConfidence)
        XCTAssertNil(state.periodization)
        XCTAssertNil(state.effectivePhaseAdjustment)
    }

    // MARK: - Сценарий 15b: одна отметка — ноль измеренных циклов, не один

    func test_scenario15b_singlePeriodStartIsZeroMeasuredCycles() {
        let events = [CycleEvent(kind: .periodStart, occurredOn: day(0))]
        XCTAssertEqual(Cycle.measuredLengths(from: events).count, 0)
        XCTAssertEqual(Cycle.dataFactor(measuredCount: 0), 0.3)
    }

    // MARK: - Сценарий 16: задержка 3 дня — confidence падает непрерывно

    func test_scenario16_threeDayDelayContinuousDegradation() {
        let events = starts([28, 28]) // expectedLength = 28 (среднее по 2 циклам)
        let profile = CycleProfile()
        let onTime = Cycle.state(events: events, profile: profile, responseProfiles: [:], asOf: day(56 + 27))
        let delayed = Cycle.state(events: events, profile: profile, responseProfiles: [:], asOf: day(56 + 30))

        XCTAssertEqual(Cycle.recencyFactor(cycleDay: 31, expectedLength: 28), 0.6)
        XCTAssertLessThan(delayed.cycleConfidence!, onTime.cycleConfidence!)
        XCTAssertGreaterThan(delayed.cycleConfidence!, 0, "поправка ослабевает, не обнуляется")
        XCTAssertNotEqual(delayed.periodization?.volumeMultiplier, 1.0,
            "непрерывное ослабление, не скачок в ноль")
    }

    // MARK: - Сценарий 17: задержка 10 дней — recencyFactor = 0

    func test_scenario17_tenDayDelayZeroesRecency() {
        XCTAssertEqual(Cycle.recencyFactor(cycleDay: 38, expectedLength: 28), 0.0)
        let events = starts([28, 28])
        let state = Cycle.state(events: events, profile: CycleProfile(), responseProfiles: [:], asOf: day(56 + 37))
        XCTAssertEqual(state.cycleConfidence!, 0, accuracy: 0.0001)
        XCTAssertNotNil(state.phase, "PhaseResolver не отказывает, confidence отдельно гасит показ")
    }

    // MARK: - Сценарий 18 / 18a: границы фаз на нестандартных длинах цикла

    func test_scenario18a_cycle21DaysCollapsesFollicular() {
        // ovulationDay = 21 − 14 = 7. Менструальная 1–5, фолликулярной не
        // остаётся ни одного дня, овуляторная 6–9 (SPEC §11.1, worked example).
        let menstrualEnd = 5
        for d in 1...5 { XCTAssertEqual(Cycle.phase(forDay: d, expectedLength: 21, menstrualEnd: menstrualEnd), .menstrual, "day \(d)") }
        for d in 1...21 { XCTAssertNotEqual(Cycle.phase(forDay: d, expectedLength: 21, menstrualEnd: menstrualEnd), .follicular, "day \(d): фолликулярная схлопнулась") }
        for d in 6...9 { XCTAssertEqual(Cycle.phase(forDay: d, expectedLength: 21, menstrualEnd: menstrualEnd), .ovulatory, "day \(d)") }
        for d in 10...16 { XCTAssertEqual(Cycle.phase(forDay: d, expectedLength: 21, menstrualEnd: menstrualEnd), .earlyLuteal, "day \(d)") }
        for d in 17...21 { XCTAssertEqual(Cycle.phase(forDay: d, expectedLength: 21, menstrualEnd: menstrualEnd), .lateLuteal, "day \(d)") }
    }

    func test_scenario18_cycle45DaysBoundaries() {
        // ovulationDay = 45 − 14 = 31.
        let menstrualEnd = 5
        for d in 1...5 { XCTAssertEqual(Cycle.phase(forDay: d, expectedLength: 45, menstrualEnd: menstrualEnd), .menstrual, "day \(d)") }
        for d in 6...29 { XCTAssertEqual(Cycle.phase(forDay: d, expectedLength: 45, menstrualEnd: menstrualEnd), .follicular, "day \(d)") }
        for d in 30...33 { XCTAssertEqual(Cycle.phase(forDay: d, expectedLength: 45, menstrualEnd: menstrualEnd), .ovulatory, "day \(d)") }
        for d in 34...40 { XCTAssertEqual(Cycle.phase(forDay: d, expectedLength: 45, menstrualEnd: menstrualEnd), .earlyLuteal, "day \(d)") }
        for d in 41...45 { XCTAssertEqual(Cycle.phase(forDay: d, expectedLength: 45, menstrualEnd: menstrualEnd), .lateLuteal, "day \(d)") }
    }

    func test_scenario18_cycle28DaysMatchesSpecTable() {
        XCTAssertEqual(Cycle.phase(forDay: 1, expectedLength: 28, menstrualEnd: 5), .menstrual)
        XCTAssertEqual(Cycle.phase(forDay: 5, expectedLength: 28, menstrualEnd: 5), .menstrual)
        XCTAssertEqual(Cycle.phase(forDay: 6, expectedLength: 28, menstrualEnd: 5), .follicular)
        XCTAssertEqual(Cycle.phase(forDay: 12, expectedLength: 28, menstrualEnd: 5), .follicular)
        XCTAssertEqual(Cycle.phase(forDay: 13, expectedLength: 28, menstrualEnd: 5), .ovulatory)
        XCTAssertEqual(Cycle.phase(forDay: 16, expectedLength: 28, menstrualEnd: 5), .ovulatory)
        XCTAssertEqual(Cycle.phase(forDay: 17, expectedLength: 28, menstrualEnd: 5), .earlyLuteal)
        XCTAssertEqual(Cycle.phase(forDay: 23, expectedLength: 28, menstrualEnd: 5), .earlyLuteal)
        XCTAssertEqual(Cycle.phase(forDay: 24, expectedLength: 28, menstrualEnd: 5), .lateLuteal)
        XCTAssertEqual(Cycle.phase(forDay: 28, expectedLength: 28, menstrualEnd: 5), .lateLuteal)
    }

    // MARK: - Сценарий 19 / 19a: скользящее среднее, выброс, перерыв

    func test_scenario19_outlierDroppedFromAverage() {
        // Записи циклов 28, 29, 27, 45, 28 (SPEC §11.3 worked example).
        let events = starts([28, 29, 27, 45, 28])
        let lengths = Cycle.measuredLengths(from: events)
        XCTAssertEqual(lengths, [28, 29, 27, 45, 28])
        let expected = Cycle.expectedLength(measuredLengths: lengths, profile: CycleProfile())
        XCTAssertEqual(expected, 28, "среднее по {27,28,28,29} = 28, не 31 (с выбросом)")
    }

    func test_scenario19a_120DayGapIsABreakNotACycle() {
        let events = starts([120])
        XCTAssertEqual(Cycle.measuredLengths(from: events), [], "перерыв не входит в среднее")
        XCTAssertEqual(Cycle.dataFactor(measuredCount: Cycle.measuredLengths(from: events).count), 0.3,
            "и не засчитывается в dataFactor")
    }

    // MARK: - Сценарий 20: переключение режимов, история сохранена

    func test_scenario20_switchingModesPreservesHistory() {
        let events = starts([28, 28])
        var profile = CycleProfile()
        let before = Cycle.state(events: events, profile: profile, responseProfiles: [:], asOf: day(60))

        profile.phaseMode = .noPhases
        profile.noPhaseReason = .userChoice
        let inNoPhases = Cycle.state(events: events, profile: profile, responseProfiles: [:], asOf: day(60))
        XCTAssertNil(inNoPhases.phase)
        XCTAssertTrue(inNoPhases.hasAnchor, "события никуда не делись")

        profile.phaseMode = .phases
        profile.noPhaseReason = nil
        let after = Cycle.state(events: events, profile: profile, responseProfiles: [:], asOf: day(60))
        XCTAssertEqual(after.phase, before.phase)
        XCTAssertEqual(after.cycleConfidence!, before.cycleConfidence!, accuracy: 0.0001,
            "тот же результат, что и до переключения — ничего не потеряно")
    }

    // MARK: - Сценарий 21: отметка задним числом — пересчёт от порядка дат, не вставки

    func test_scenario21_backdatedEntryRecomputesFromDateOrder() {
        let inOrder = starts([28, 28, 28])
        // Тот же набор дат, но последний (самый ранний по времени) элемент
        // вставлен задним числом — как будто пользователь ввёл его последним.
        let backdated = [inOrder[3], inOrder[1], inOrder[2], inOrder[0]]

        let profile = CycleProfile()
        let a = Cycle.state(events: inOrder, profile: profile, responseProfiles: [:], asOf: day(90))
        let b = Cycle.state(events: backdated, profile: profile, responseProfiles: [:], asOf: day(90))

        XCTAssertEqual(a.phase, b.phase)
        XCTAssertEqual(a.cycleConfidence!, b.cycleConfidence!, accuracy: 0.0001)
        XCTAssertEqual(Cycle.measuredLengths(from: inOrder), Cycle.measuredLengths(from: backdated))
    }

    // MARK: - Сценарий 22: дубликат period_start в один день — идемпотентность

    func test_scenario22_duplicatePeriodStartSameDayIsIdempotent() {
        let events = [
            CycleEvent(kind: .periodStart, occurredOn: day(0)),
            CycleEvent(kind: .periodStart, occurredOn: day(0)),
        ]
        XCTAssertEqual(Cycle.periodStartDays(from: events).count, 1)
    }

    // MARK: - Сценарий 23c: rest не учится

    func test_scenario23c_restDoesNotShiftProfile() {
        let fresh = PhaseResponseProfile()
        let (result, notified) = Cycle.applyingOverride(.rest, to: fresh)
        XCTAssertEqual(result, fresh)
        XCTAssertFalse(notified)
    }

    // MARK: - Сценарий 23a (частично): без фазы обучение не идёт

    func test_scenario23a_noPhaseKnownMeansNoLearningTarget() {
        // Cycle не решает САМ, применять ли обучение — это делает вызывающая
        // сторона по CycleState.phase. Контракт: phase == nil ровно в двух
        // состояниях (no_phases, нет опорной даты), и оба уже проверены в
        // 15a/20 — здесь фиксируется сам факт, что «фаза известна» имеет
        // единственный источник истины (CycleState.phase), а не отдельный флаг.
        let noAnchor = Cycle.state(events: [], profile: CycleProfile(), responseProfiles: [:], asOf: day(0))
        XCTAssertNil(noAnchor.phase, "оверрайд в этот день не может обучить ни один профиль")

        var noPhaseProfile = CycleProfile()
        noPhaseProfile.phaseMode = .noPhases
        noPhaseProfile.noPhaseReason = .contraception
        let noPhases = Cycle.state(events: starts([28]), profile: noPhaseProfile, responseProfiles: [:], asOf: day(35))
        XCTAssertNil(noPhases.phase)
    }

    func test_scenario23a_overrideWithoutPhaseNeverTrainsTheProfile() {
        // Тот же оверрайд, что обучал бы профиль в фазе, в день без фазы
        // (режим без фаз или нет опорной даты) не делает ничего: ни сдвига,
        // ни sampleSize. Сигнатура `rebuildingProfiles` принимает `Phase?`
        // именно потому, что её источник — `CycleState.phase` — опционален.
        let learned = Cycle.rebuildingProfiles(from: [
            (phase: nil, override: .push),
            (phase: nil, override: .ease),
        ])
        XCTAssertTrue(learned.isEmpty, "дни без фазы в обучение не идут вовсе")

        // А смешанная история учит ровно те дни, у которых фаза есть.
        let mixed = Cycle.rebuildingProfiles(from: [
            (phase: .lateLuteal, override: .push),
            (phase: nil, override: .push),
            (phase: .lateLuteal, override: .push),
        ])
        XCTAssertEqual(mixed[.lateLuteal]?.sampleSize, 2, "день без фазы не досчитался")
        XCTAssertEqual(mixed[.lateLuteal]?.adjustment ?? 0, 0.04, accuracy: 0.0001)
    }

    // MARK: - Сценарий 23b: push, затем ease в тот же день — сдвиг один раз, по итогу

    func test_scenario23b_onlyFinalDailyOverrideIsLearned() {
        // daily_checkins.override — одна колонка на дату: обучение видит
        // только финальное нажатие (.ease), а не оба.
        let fresh = PhaseResponseProfile()
        let (result, _) = Cycle.applyingOverride(.ease, to: fresh)
        XCTAssertEqual(result.adjustment, -0.02, accuracy: 0.0001)
        XCTAssertEqual(result.sampleSize, 1, "не 2 — push из того же дня в обучение не попадает")
    }

    // MARK: - Сценарий 24: три оверрайда push в лютеиновой — сдвиг, уведомление раз

    func test_scenario24_threePushOverridesShiftProfileNotifyOnce() {
        var profile = PhaseResponseProfile()
        var notifications: [Bool] = []
        for _ in 0..<4 {
            let (next, justNotified) = Cycle.applyingOverride(.push, to: profile)
            profile = next
            notifications.append(justNotified)
        }
        XCTAssertEqual(profile.sampleSize, 4)
        XCTAssertEqual(profile.adjustment, 0.08, accuracy: 0.0001)
        XCTAssertEqual(notifications, [false, false, true, false], "уведомление — ровно на 3-м переходе")

        let effective = Cycle.effectiveReadinessAdjustment(phase: .earlyLuteal, profile: profile)
        XCTAssertEqual(effective, 0.00 + 0.08, accuracy: 0.0001, "лютеиновую больше не режет — сдвинута вверх")
    }

    // MARK: - Контракт: потолок clamp профиля (SPEC §11.4), не входит в номерные сценарии

    func test_clampNeverExceedsFifteenHundredths() {
        var profile = PhaseResponseProfile()
        for _ in 0..<50 {
            profile = Cycle.applyingOverride(.push, to: profile).profile
        }
        XCTAssertEqual(profile.adjustment, 0.15, accuracy: 0.0001)
    }

    // MARK: - Сценарий 24b: низкая уверенность — непрерывное масштабирование, не порог

    func test_scenario24b_lowConfidenceScalesVolumeContinuously() {
        let p = Cycle.periodization(phase: .menstrual, cycleConfidence: 0.12)
        XCTAssertEqual(p.volumeMultiplier, 1.0 - 0.25 * 0.12, accuracy: 0.0001, "−3%, не −25%")
        XCTAssertEqual(p.blockType, .neutral, "ниже 0.3 — тип блока нейтрален")
    }

    // MARK: - Сценарий 24c: округление RIR от нуля на границе 0.5

    func test_scenario24c_rirRoundsAwayFromZeroAtHalf() {
        XCTAssertEqual(Cycle.effectiveRIRShift(phase: .menstrual, cycleConfidence: 0.5), 1,
            "menstrual rirShift=+1 × 0.5 = 0.5 → 1, не 0")
        XCTAssertEqual(Cycle.effectiveRIRShift(phase: .follicular, cycleConfidence: 0.5), -1,
            "follicular rirShift=−1 × 0.5 = −0.5 → −1, симметрично")
    }

    // MARK: - Сценарий 26: беременность — общая ветка no_phases, без спецкейса

    func test_scenario26_pregnancyUsesGenericNoPhasesBranch() {
        var profile = CycleProfile()
        profile.phaseMode = .noPhases
        profile.noPhaseReason = .pregnancy
        let state = Cycle.state(events: starts([28]), profile: profile, responseProfiles: [:], asOf: day(35))
        XCTAssertNil(state.phase)
        XCTAssertNil(state.periodization)
        XCTAssertEqual(state.noPhaseReason, .pregnancy)
    }

    // MARK: - Контракт: квартили/IQR (SPEC §11.3 worked example), не входит в номерные сценарии

    func test_quartilesMatchSpecWorkedExample() {
        let sorted = [27.0, 28, 28, 29, 45]
        XCTAssertEqual(Cycle.quantile(0.25, of: sorted), 28, accuracy: 0.0001)
        XCTAssertEqual(Cycle.quantile(0.75, of: sorted), 29, accuracy: 0.0001)
        XCTAssertEqual(Cycle.rejectingOutliers([27, 28, 28, 29, 45]).lengths, [27, 28, 28, 29])
    }

    // MARK: - Контракт: dataFactor (не входит в номерные сценарии)

    func test_dataFactorMatchesSpecTable() {
        XCTAssertEqual(Cycle.dataFactor(measuredCount: 0), 0.3)
        XCTAssertEqual(Cycle.dataFactor(measuredCount: 1), 0.5)
        XCTAssertEqual(Cycle.dataFactor(measuredCount: 2), 0.7)
        XCTAssertEqual(Cycle.dataFactor(measuredCount: 3), 1.0)
        XCTAssertEqual(Cycle.dataFactor(measuredCount: 10), 1.0)
    }

    // MARK: - Контракт: σ-границы regularityFactor (правка гэпа (2,3))

    func test_regularityFactorSigmaBoundaries() {
        // σ = 0 при постоянной длине.
        XCTAssertEqual(Cycle.regularityFactor(window: Cycle.CycleWindow(lengths: [28, 28, 28], excludedOutlier: false), declaredRegularity: nil), 1.0)
        // σ ровно на границе 2 включена в верхний бакет.
        XCTAssertEqual(Cycle.regularityFactor(window: Cycle.CycleWindow(lengths: [26, 30], excludedOutlier: false), declaredRegularity: nil), 1.0,
            "σ([26,30]) = 2 ровно")
        // σ в открытом раньше промежутке (2,3] — закрытая правка.
        XCTAssertEqual(Cycle.regularityFactor(window: Cycle.CycleWindow(lengths: [25, 31], excludedOutlier: false), declaredRegularity: nil), 0.7,
            "σ([25,31]) = 3")
        XCTAssertEqual(Cycle.regularityFactor(window: Cycle.CycleWindow(lengths: [15, 45], excludedOutlier: false), declaredRegularity: nil), 0.4,
            "σ([15,45]) = 15 > 5")
    }

    func test_regularityFactorFallsBackToDeclaredBelowTwoMeasuredLengths() {
        XCTAssertEqual(Cycle.regularityFactor(window: Cycle.CycleWindow(lengths: [], excludedOutlier: false), declaredRegularity: .regular), 1.0)
        XCTAssertEqual(Cycle.regularityFactor(window: Cycle.CycleWindow(lengths: [28], excludedOutlier: false), declaredRegularity: .variable), 0.7)
        XCTAssertEqual(Cycle.regularityFactor(window: Cycle.CycleWindow(lengths: [28], excludedOutlier: false), declaredRegularity: .irregular), 0.4)
        XCTAssertEqual(Cycle.regularityFactor(window: Cycle.CycleWindow(lengths: [], excludedOutlier: false), declaredRegularity: nil), 1.0,
            "регулярность не заявлена → 1.0")
    }

    /// SPEC §11.3, «Область подсчёта»: dataFactor и regularityFactor читают
    /// РАЗНЫЕ окна измеренных циклов. Точечные тесты выше проверяют это по
    /// отдельности (dataFactor на голых числах, σ-границы на готовых списках),
    /// но ни один не показывает случай, где это различие реально могло бы
    /// разойтись незаметно: пользовательница с историей длиннее окна из 6,
    /// в которой самый старый цикл — выброс.
    ///
    /// 35 — не круглое число: подобрано так, что при ОШИБОЧНОМ вычислении
    /// (если бы regularityFactor по ошибке читал то же окно «вся история»,
    /// что и dataFactor, вместо отфильтрованных последних 6) популяционное σ
    /// по всем 8 значениям попадает ровно в промежуток (2, 3] — тот самый
    /// разрыв, который закрыла правка SPEC (commit 5e0e466). До этой правки
    /// такая ошибка окна тихо давала бы неопределённое поведение; после —
    /// тихо давала бы 0.7 вместо корректных 1.0, и по возвращаемому числу
    /// одно от другого не отличить без явного теста на это расхождение.
    func test_earlyOutlierBeyondFilteredWindowCountsInDataFactorButNotRegularity() {
        // Цикл длиной 35 — самый старый (первый интервал); за ним 7 циклов
        // ровно по 28 дней. Итого 8 измеренных циклов, окно regularityFactor
        // — только последние 6, все они чистые 28.
        let events = starts([35, 28, 28, 28, 28, 28, 28, 28])
        let lengths = Cycle.measuredLengths(from: events)
        XCTAssertEqual(lengths, [35, 28, 28, 28, 28, 28, 28, 28], "выброс — самый старый, не выпадает из истории")

        // dataFactor: окно «вся история», выброс входит в счёт как один из 8.
        XCTAssertEqual(Cycle.dataFactor(measuredCount: lengths.count), 1.0)

        // regularityFactor / expectedLength: окно «последние 6, минус IQR-выбросы»
        // — выброс вне этого окна ЧИСТО ПОЗИЦИОННО (он 3-й с конца среди 8, за
        // пределами последних 6), IQR здесь даже не успевает сработать.
        let window = Cycle.recentWindow(lengths)
        XCTAssertEqual(window.lengths, [28, 28, 28, 28, 28, 28], "выброс вне окна из 6 самых свежих")
        XCTAssertFalse(window.excludedOutlier, "он не отфильтрован, а просто вне окна — потолок не применяется")
        XCTAssertEqual(Cycle.regularityFactor(window: window, declaredRegularity: nil), 1.0,
            "корректное окно — регулярность идеальная, выброс не виден вовсе")

        // Тот же выброс, если бы он оказался ВНУТРИ окна (а не только вне его
        // позиционно), всё равно был бы отфильтрован IQR — «отфильтрованный бы
        // 1.5 IQR» не полагается только на удачную позицию в истории.
        XCTAssertEqual(Cycle.rejectingOutliers([35, 28, 28, 28, 28, 28, 28]).lengths, [28, 28, 28, 28, 28, 28],
            "35 — выброс и по IQR, не только по позиции")

        // Контраст — ОШИБОЧНОЕ вычисление, окно «вся история» вместо
        // отфильтрованных последних 6: другой, более низкий бакет (σ по всем
        // 8 значениям ≈2.32 — ровно в промежутке (2,3], который закрыла
        // правка SPEC 5e0e466). Расхождение 1.0 → 0.7 — то самое молчаливое
        // расхождение, о которое эта функция обязана не спотыкаться.
        XCTAssertEqual(Cycle.regularityFactor(window: Cycle.CycleWindow(lengths: lengths, excludedOutlier: false), declaredRegularity: nil), 0.7,
            "если бы окна не различались — другой, заниженный результат")
    }

    // MARK: - Контракт: потолок для окна с исключённым выбросом (SPEC §11.3)

    /// Вырожденный случай, ради которого потолок и введён: пять одинаковых
    /// циклов и один сильный выброс. После фильтра остаётся ПЯТЬ ОДИНАКОВЫХ
    /// значений, то есть σ = 0.00 — арифметический максимум регулярности,
    /// неотличимый от той, у кого цикл не сдвигался ни на день. Без потолка
    /// приложение говорило бы уверенно ровно после промаха на двенадцать дней.
    func test_windowWithExcludedOutlierIsNeverMaximallyRegular() {
        let window = Cycle.recentWindow([28, 28, 28, 28, 28, 40])
        XCTAssertEqual(window.lengths, [28, 28, 28, 28, 28], "40 отброшен как выброс")
        XCTAssertTrue(window.excludedOutlier)
        XCTAssertEqual(Cycle.standardDeviation(of: window.lengths), 0, accuracy: 0.0001,
            "механизм: остаток теснее обычного, σ ровно ноль")

        XCTAssertEqual(Cycle.regularityFactor(window: window, declaredRegularity: nil), 0.7,
            "потолок: окно с выбросом не бывает максимально регулярным")
        // Без потолка та же σ дала бы верхнюю ступень — вот с чем сравниваем.
        XCTAssertEqual(
            Cycle.regularityFactor(
                window: Cycle.CycleWindow(lengths: window.lengths, excludedOutlier: false),
                declaredRegularity: nil
            ),
            1.0,
            "та же σ без исключённого выброса — по-прежнему 1.0"
        )
    }

    /// Пол полосы: при почти одинаковом окне IQR = 0, и без пола границы
    /// схлопывались бы в медиану — 27 и 29 объявлялись бы выбросами, хотя
    /// разброс в один день §11.3 называет регулярным.
    func test_rejectionBandIsNeverNarrowerThanMedianPlusMinusTwo() {
        let window = Cycle.recentWindow([28, 28, 29, 27, 28, 28])
        XCTAssertEqual(window.lengths, [28, 28, 29, 27, 28, 28], "ничего не отброшено")
        XCTAssertFalse(window.excludedOutlier, "полоса не схлопнулась на медиану")
        XCTAssertEqual(Cycle.regularityFactor(window: window, declaredRegularity: nil), 1.0,
            "потолок не применяется — применять его тут было бы наказанием за регулярность")
    }

    /// Контрольные случаи: каждая история на своей ступени, и ровно по той
    /// причине, которая за неё отвечает.
    func test_regularityLadderAcrossRealisticHistories() {
        func factor(_ lengths: [Int]) -> Double {
            Cycle.regularityFactor(window: Cycle.recentWindow(lengths), declaredRegularity: nil)
        }

        // Ничего не исключено — работает σ.
        XCTAssertFalse(Cycle.recentWindow([28, 31, 27, 30, 28, 29]).excludedOutlier)
        XCTAssertEqual(factor([28, 31, 27, 30, 28, 29]), 1.0, "мягкая вариативность")

        XCTAssertFalse(Cycle.recentWindow([45, 20, 44, 21, 46, 19]).excludedOutlier)
        XCTAssertEqual(factor([45, 20, 44, 21, 46, 19]), 0.4,
            "по-настоящему нерегулярная: разброс так широк, что выбросов нет — σ сама доносит")

        // Исключён выброс — работает потолок.
        XCTAssertTrue(Cycle.recentWindow([27, 28, 28, 29, 45]).excludedOutlier)
        XCTAssertEqual(factor([27, 28, 28, 29, 45]), 0.7, "пример из SPEC §11.3")

        XCTAssertTrue(Cycle.recentWindow([45, 20, 44, 41]).excludedOutlier)
        XCTAssertEqual(factor([45, 20, 44, 41]), 0.7,
            "случай из вчерашнего фикса: 20 отброшен, остаток 45/44/41 читался как σ≈1.7")
    }

    // MARK: - Контракт: exerciseBias (овуляторное ограничение, SPEC §11.2)

    func test_exerciseBiasOnlyPenalizesHighImpactInOvulatory() {
        XCTAssertEqual(Cycle.exerciseBias(phase: .ovulatory, cycleConfidence: 1.0, impact: .low).value, 0)
        XCTAssertNil(Cycle.exerciseBias(phase: .ovulatory, cycleConfidence: 1.0, impact: .low).reason)
        XCTAssertEqual(Cycle.exerciseBias(phase: .earlyLuteal, cycleConfidence: 1.0, impact: .high).value, 0,
            "только овуляторная фаза")

        let (value, reason) = Cycle.exerciseBias(phase: .ovulatory, cycleConfidence: 0.5, impact: .high)
        XCTAssertLessThan(value, 0, "штраф, не фильтр — знак отрицательный, не удаление")
        if case .ovulatoryImpactCaution(let confidence)? = reason {
            XCTAssertEqual(confidence, 0.5, accuracy: 0.0001)
        } else {
            XCTFail("причина обязана нести cycleConfidence (SPEC §14.6)")
        }
    }

    /// SPEC §11.2: `exerciseBias` — величина НЕПРЕРЫВНАЯ, как объём и RIR, а не
    /// категория, поэтому порог 0.3 к ней не применяется вовсе. Тест смотрит
    /// именно ПОД порогом: выше него отличить «масштабируется» от «гейтится»
    /// нельзя, а копипаста гейта из `effectiveBlockType` (он рядом, в том же
    /// файле) — самый вероятный способ это сломать.
    func test_exerciseBiasScalesBelowCategoricalThresholdInsteadOfGating() {
        let low = Cycle.exerciseBias(phase: .ovulatory, cycleConfidence: 0.12, impact: .high)
        XCTAssertEqual(low.value, -0.3 * 0.12, accuracy: 0.0001,
            "0.12 < 0.3, но штраф масштабируется, а не обнуляется")
        XCTAssertNotNil(low.reason, "причина выдаётся и под порогом — показывать её решает слой представления")

        // Непрерывность в самой точке порога: соседние значения отличаются на
        // столько же, на сколько отличаются сами уверенности, без скачка.
        let below = Cycle.exerciseBias(phase: .ovulatory, cycleConfidence: 0.29, impact: .high).value
        let above = Cycle.exerciseBias(phase: .ovulatory, cycleConfidence: 0.31, impact: .high).value
        XCTAssertNotEqual(below, 0, "под порогом штраф не исчезает")
        XCTAssertEqual(above / below, 0.31 / 0.29, accuracy: 0.0001,
            "отношение равно отношению уверенностей — значит скачка в точке 0.3 нет")
    }

    // MARK: - Контракт: холодный старт, состояние «один измеренный цикл»
    //
    // Четыре состояния холодного старта (cycle-phase-domain, SPEC §11.3):
    // опорной даты нет (сценарий 15a), ноль измеренных циклов (15/15b),
    // ОДИН измеренный цикл (здесь), просрочка (16/17). Своего номера в §18 у
    // этого состояния нет, поэтому тест контрактный, а не `test_scenarioN`.

    /// Один измеренный цикл — это ДВЕ отметки `period_start`, и он отличается
    /// от «ноля измеренных» (одна отметка, сценарий 15b) значением
    /// `dataFactor`, но НЕ источником регулярности: σ на одной длине не
    /// существует, поэтому регулярность всё ещё заявленная.
    ///
    /// Проверяется через полный конвейер (события → `Cycle.state`), а не
    /// вызовом `dataFactor(measuredCount: 1)` с числом на руках: подстановка
    /// готового числа не поймала бы ошибку в самой связке
    /// событие → интервал → счёт.
    func test_oneMeasuredCycleUsesDeclaredRegularityAndHalfDataFactor() {
        let events = starts([28])
        XCTAssertEqual(Cycle.measuredLengths(from: events).count, 1,
            "две отметки = один измеренный цикл")

        let profile = CycleProfile(declaredRegularity: .variable)
        let state = Cycle.state(events: events, profile: profile, responseProfiles: [:], asOf: day(35))

        // dataFactor 0.5 (один цикл) × regularityFactor 0.7 (заявленная
        // 'variable', потому что σ на одной длине не существует) × recency 1.0.
        XCTAssertEqual(state.cycleConfidence!, 0.5 * 0.7, accuracy: 0.0001)
        XCTAssertNotEqual(state.cycleConfidence!, 0.3 * 0.7, accuracy: 0.0001,
            "это НЕ ноль измеренных циклов")
        XCTAssertNotEqual(state.cycleConfidence!, 0.5 * 1.0, accuracy: 0.0001,
            "и НЕ σ-ветка: на одной длине σ не существует")
    }

    // MARK: - Контракт: period_end — последний день кровотечения (SPEC §11.1)

    func test_menstrualEndCountsPeriodEndDayInclusively() {
        let start = CycleEvent(kind: .periodStart, occurredOn: day(0))
        let end = CycleEvent(kind: .periodEnd, occurredOn: day(3))
        let profile = CycleProfile(typicalPeriodLengthDays: 5)

        XCTAssertEqual(Cycle.menstrualEnd(events: [start, end], profile: profile), 4,
            "день 0 по день 3 включительно — четыре дня кровотечения, а не три")
        XCTAssertEqual(Cycle.menstrualEnd(events: [start], profile: profile), 5,
            "без события period_end — заявленная длительность")
        XCTAssertEqual(Cycle.menstrualEnd(events: [start], profile: CycleProfile()), 5,
            "без события и без заявленной — дефолт 5")

        // Граница фаз съезжает вместе с menstrualEnd: фолликулярная начинается
        // на следующий день после конца менструации (SPEC §11.1).
        XCTAssertEqual(Cycle.phase(forDay: 4, expectedLength: 28, menstrualEnd: 4), .menstrual)
        XCTAssertEqual(Cycle.phase(forDay: 5, expectedLength: 28, menstrualEnd: 4), .follicular)
    }

    // MARK: - Контракт: low_confidence_streak — переход в режим без фаз и обратно (SPEC §11.5)

    func test_lowConfidenceStreakAutoTransition() {
        var profile = CycleProfile()
        profile = Cycle.applyingCycleClose(confidence: 0.12, to: profile)
        XCTAssertEqual(profile.lowConfidenceStreak, 1)
        XCTAssertEqual(profile.phaseMode, .phases)

        profile = Cycle.applyingCycleClose(confidence: 0.12, to: profile)
        XCTAssertEqual(profile.lowConfidenceStreak, 2)
        XCTAssertEqual(profile.phaseMode, .phases, "ещё не третий подряд")

        profile = Cycle.applyingCycleClose(confidence: 0.12, to: profile)
        XCTAssertEqual(profile.lowConfidenceStreak, 3)
        XCTAssertEqual(profile.phaseMode, .noPhases)
        XCTAssertEqual(profile.noPhaseReason, .lowConfidence)

        profile = Cycle.applyingCycleClose(confidence: 0.8, to: profile)
        XCTAssertEqual(profile.lowConfidenceStreak, 0, "закрытие с confidence ≥ 0.3 обнуляет счётчик")
        XCTAssertEqual(profile.phaseMode, .phases, "и снимает режим без фаз автоматически")
        XCTAssertNil(profile.noPhaseReason)
    }

    func test_lowConfidenceStreakNeverOverridesManualReason() {
        var profile = CycleProfile()
        profile.phaseMode = .noPhases
        profile.noPhaseReason = .contraception

        for _ in 0..<5 {
            profile = Cycle.applyingCycleClose(confidence: 0.1, to: profile)
        }
        XCTAssertEqual(profile.noPhaseReason, .contraception, "низкая уверенность не подменяет ручную причину")

        profile = Cycle.applyingCycleClose(confidence: 0.9, to: profile)
        XCTAssertEqual(profile.noPhaseReason, .contraception, "и хорошее закрытие тоже не снимает ручную причину")
        XCTAssertEqual(profile.phaseMode, .noPhases)
    }

    // MARK: - Контракт: applyingClosedCycles — публичный вход механизма (SPEC §11.5)

    /// Тот же переход, что и `test_lowConfidenceStreakAutoTransition`, но через
    /// публичную точку входа: уверенность закрытия считается внутри, из
    /// событий, а не подставляется вызывающим. Это и есть проверка того, что
    /// механизм §11.5 подключён, а не собирается из двух функций вручную.
    ///
    /// Длины 45 / 20 / 44 — цикл, который каждый раз промахивается мимо
    /// собственного прогноза: 45 при ожидаемых 28, потом 44 при ожидаемых 32.
    /// Именно на такой пользовательнице правило §11.5 и должно срабатывать.
    func test_applyingClosedCyclesDrivesStreakFromEventsAlone() {
        var profile = CycleProfile(declaredRegularity: .irregular)

        // Ничего ещё не закрылось — no-op, счётчик не двигается.
        let oneMark = [CycleEvent(kind: .periodStart, occurredOn: day(0))]
        profile = Cycle.applyingClosedCycles(events: oneMark, profile: profile)
        XCTAssertEqual(profile.lowConfidenceStreak, 0, "одна отметка не закрывает цикл")
        XCTAssertEqual(profile.phaseMode, .phases)

        var events = oneMark
        for (i, gap) in [45, 20, 44].enumerated() {
            events.append(CycleEvent(kind: .periodStart, occurredOn: events.last!.occurredOn.adding(days: gap)))
            profile = Cycle.applyingClosedCycles(events: events, profile: profile)
            XCTAssertEqual(profile.lowConfidenceStreak, i + 1, "закрытие \(i + 1)")
        }
        XCTAssertEqual(profile.phaseMode, .noPhases, "три подряд ниже 0.3 — режим без фаз")
        XCTAssertEqual(profile.noPhaseReason, .lowConfidence)
    }

    /// Регрессия на мёртвое правило: при `recencyFactor = 1` на закрытии серия
    /// не могла дойти до трёх ВООБЩЕ (с третьего цикла dataFactor = 1.0,
    /// regularityFactor ≥ 0.4, произведение ≥ 0.40). Тест фиксирует, что
    /// достижимо именно закрытие ниже порога при полной истории — то, чего
    /// старая формула не допускала.
    func test_closeConfidenceCanFallBelowThresholdWithFullHistory() {
        let events = starts([45, 20, 44, 21, 46])
        let confidences = Cycle.confidenceAtEachClose(events: events, profile: CycleProfile(declaredRegularity: .irregular))

        XCTAssertEqual(confidences.count, 5)
        XCTAssertLessThan(confidences[2], 0.3, "третье закрытие — с полным dataFactor = 1.0 — обязано быть достижимо ниже порога")
        XCTAssertLessThan(confidences[4], 0.3)
    }

    /// Ради чего промах на закрытии считается ПО МОДУЛЮ (SPEC §11.5).
    ///
    /// Чередование 20 / 45 / 20 / 45 — ни одного позднего цикла, но прогноз не
    /// сбывается ни разу. Односторонняя мера (только перебор над прогнозом)
    /// читала короткие закрытия как «пришло вовремя»: на третьем закрытии
    /// (длина 20 при прогнозе 32) она давала 0.40, обнуляла серию, и режим без
    /// фаз не включался НИКОГДА — при живой, ровно той самой непредсказуемости,
    /// ради которой правило §11.5 и написано. По модулю промах там равен 12
    /// дням → 0.0, и серия доходит до трёх.
    ///
    /// Тест удерживает именно это: вернуть одностороннюю версию — значит
    /// уронить его.
    func test_alternatingShortCyclesTripLowConfidenceMode() {
        var profile = CycleProfile(declaredRegularity: .irregular)
        var events = [CycleEvent(kind: .periodStart, occurredOn: day(0))]

        for (i, gap) in [20, 45, 20].enumerated() {
            events.append(CycleEvent(kind: .periodStart, occurredOn: events.last!.occurredOn.adding(days: gap)))
            profile = Cycle.applyingClosedCycles(events: events, profile: profile)
            XCTAssertEqual(profile.lowConfidenceStreak, i + 1,
                "закрытие \(i + 1): промах мимо прогноза в любую сторону копит серию")
        }
        XCTAssertEqual(profile.phaseMode, .noPhases)
        XCTAssertEqual(profile.noPhaseReason, .lowConfidence)

        // Ни одно из трёх закрытий не было поздним — серия набралась целиком
        // на коротких и на одном длинном, то есть на промахах как таковых.
        let confidences = Cycle.confidenceAtEachClose(
            events: events,
            profile: CycleProfile(declaredRegularity: .irregular)
        )
        XCTAssertTrue(confidences.allSatisfy { $0 < 0.3 },
            "все три закрытия ниже порога: \(confidences)")
    }

    // MARK: - Контракт: промах по модулю vs просрочка в одну сторону (SPEC §11.5, §11.3)

    func test_predictionMissFactorIsSymmetric() {
        XCTAssertEqual(Cycle.predictionMissFactor(actualLength: 28, predictedLength: 28), 1.0)
        XCTAssertEqual(Cycle.predictionMissFactor(actualLength: 33, predictedLength: 28),
                       Cycle.predictionMissFactor(actualLength: 23, predictedLength: 28),
                       "промах +5 и −5 — один и тот же промах")
        XCTAssertEqual(Cycle.predictionMissFactor(actualLength: 23, predictedLength: 28), 0.3)
        XCTAssertEqual(Cycle.predictionMissFactor(actualLength: 30, predictedLength: 28), 0.6)
        XCTAssertEqual(Cycle.predictionMissFactor(actualLength: 12, predictedLength: 28), 0.0)
    }

    /// Живой путь остаётся ОДНОСТОРОННИМ, и это не то, что нужно «унифицировать»
    /// со сценарием закрытия: у ещё открытого цикла «раньше» не наблюдаемо —
    /// день просто не дошёл до прогноза. По модулю пятый день цикла при прогнозе
    /// 28 дал бы промах 23 дня и уверенность 0 почти у всех и почти всегда.
    func test_recencyFactorStaysOneDirectionalForOpenCycle() {
        XCTAssertEqual(Cycle.recencyFactor(cycleDay: 5, expectedLength: 28), 1.0,
            "пятый день нормального цикла — это не промах")
        XCTAssertEqual(Cycle.recencyFactor(cycleDay: 20, expectedLength: 28), 1.0)
        XCTAssertEqual(Cycle.recencyFactor(cycleDay: 28, expectedLength: 28), 1.0)
        // Просрочка по-прежнему считается.
        XCTAssertEqual(Cycle.recencyFactor(cycleDay: 31, expectedLength: 28), 0.6)
        XCTAssertEqual(Cycle.recencyFactor(cycleDay: 38, expectedLength: 28), 0.0)
    }

    /// Обратная сторона того же правила: у предсказуемого цикла закрытия
    /// стабильно выше порога, и режим без фаз не включается никогда.
    func test_regularUserNeverTripsLowConfidenceMode() {
        var profile = CycleProfile(declaredRegularity: .regular)
        var events = [CycleEvent(kind: .periodStart, occurredOn: day(0))]

        for gap in [28, 28, 29, 27, 28, 28] {
            events.append(CycleEvent(kind: .periodStart, occurredOn: events.last!.occurredOn.adding(days: gap)))
            profile = Cycle.applyingClosedCycles(events: events, profile: profile)
            XCTAssertEqual(profile.lowConfidenceStreak, 0, "предсказуемый цикл не копит серию")
        }
        XCTAssertEqual(profile.phaseMode, .phases)
        XCTAssertNil(profile.noPhaseReason)
    }

    /// Просрочка ЕЩЁ ОТКРЫТОГО цикла в счётчик не идёт (SPEC §11.5:
    /// «считается по закрытым циклам, а не по дням»): сегодняшний
    /// `cycleConfidence` при задержке равен нулю, но пока цикл не закрылся,
    /// `applyingClosedCycles` считает по закрывшимся циклам, а он пришёл
    /// точно в прогноз.
    func test_openOverdueCycleDoesNotAdvanceStreak() {
        let events = starts([28, 28])
        let profile = CycleProfile()

        let today = Cycle.state(events: events, profile: profile, responseProfiles: [:], asOf: day(93))
        XCTAssertEqual(today.cycleConfidence!, 0, accuracy: 0.0001, "просрочка 10 дней роняет recencyFactor в 0")

        let closed = Cycle.applyingClosedCycles(events: events, profile: profile)
        XCTAssertEqual(closed.lowConfidenceStreak, 0, "но открытая просрочка счётчик не двигает")
        XCTAssertEqual(closed.phaseMode, .phases)
    }

    // MARK: - Контракт: каждое закрытие учитывается ровно один раз (SPEC §11.5)

    /// Перерыв длиннее 90 дней не должен ничего досчитывать. `measuredLengths`
    /// выбрасывает такой интервал (§11.3), поэтому «последний измеренный цикл»
    /// после перерыва — это ДОперерывный, уже учтённый: раньше он попадал в
    /// серию второй раз именно у вернувшейся после паузы пользовательницы,
    /// ради которой правило 90 дней и написано.
    func test_breakLongerThanNinetyDaysCountsNothingTwice() {
        var profile = CycleProfile(declaredRegularity: .irregular)

        // Один настоящий цикл: 45 дней при прогнозе 28 — промах, серия = 1.
        var events = [
            CycleEvent(kind: .periodStart, occurredOn: day(0)),
            CycleEvent(kind: .periodStart, occurredOn: day(45)),
        ]
        profile = Cycle.applyingClosedCycles(events: events, profile: profile)
        XCTAssertEqual(profile.lowConfidenceStreak, 1)
        XCTAssertEqual(profile.lowConfidenceCountedThrough, day(45), "учтено по день закрытия")

        // Пауза на 120 дней, потом отметка. Интервал — перерыв, не цикл.
        events.append(CycleEvent(kind: .periodStart, occurredOn: day(165)))
        profile = Cycle.applyingClosedCycles(events: events, profile: profile)
        XCTAssertEqual(profile.lowConfidenceStreak, 1,
            "перерыв не цикл: досчитывать нечего, и доперерывный цикл не считается снова")
        XCTAssertEqual(profile.lowConfidenceCountedThrough, day(45), "отметка учёта не двигалась")
        XCTAssertEqual(profile.phaseMode, .phases)
    }

    /// Отметка задним числом раньше отметки учёта пропускается, а не
    /// пересчитывается. Плюс простая идемпотентность: тот же вызов на тех же
    /// событиях второй раз не меняет ничего (§4.3 — offline-first, одно и то же
    /// событие приходит дважды).
    func test_backdatedMarkAndRepeatedCallCountNothingTwice() {
        var profile = CycleProfile(declaredRegularity: .irregular)
        let events = starts([45, 20])
        profile = Cycle.applyingClosedCycles(events: events, profile: profile)
        let afterFirstPass = profile
        XCTAssertEqual(profile.lowConfidenceStreak, 2)

        // Повторный вызов на тех же событиях.
        profile = Cycle.applyingClosedCycles(events: events, profile: profile)
        XCTAssertEqual(profile, afterFirstPass, "повторный вызов — no-op")

        // Отметка задним числом ВНУТРИ уже учтённой истории.
        let backdated = events + [CycleEvent(kind: .periodStart, occurredOn: day(20))]
        profile = Cycle.applyingClosedCycles(events: backdated, profile: profile)
        XCTAssertEqual(profile.lowConfidenceStreak, afterFirstPass.lowConfidenceStreak,
            "закрытия раньше отметки учёта уже посчитаны")
        XCTAssertEqual(profile.lowConfidenceCountedThrough, afterFirstPass.lowConfidenceCountedThrough)
    }

    /// Несколько закрытий, накопившихся между вызовами (офлайн), досчитываются
    /// все и в хронологическом порядке — а не только последнее.
    func test_severalPendingClosesAreAllCounted() {
        let events = starts([45, 20, 44])
        let profile = Cycle.applyingClosedCycles(
            events: events,
            profile: CycleProfile(declaredRegularity: .irregular)
        )
        XCTAssertEqual(profile.lowConfidenceStreak, 3, "три накопившихся закрытия учтены разом")
        XCTAssertEqual(profile.phaseMode, .noPhases)
        XCTAssertEqual(profile.noPhaseReason, .lowConfidence)
    }

    // MARK: - Контракт: ручное переключение режима сбрасывает серию (SPEC §11.5)

    /// Пользовательница, которую автоматика увела в режим без фаз, включает
    /// фазы обратно. Серия должна начинаться заново: одно плохое закрытие после
    /// переключения не имеет права отменить её выбор — нужны те же три подряд.
    func test_manualSwitchToPhasesRestartsTheStreak() {
        var profile = CycleProfile(declaredRegularity: .irregular)
        var events = [CycleEvent(kind: .periodStart, occurredOn: day(0))]
        for gap in [45, 20, 44] {
            events.append(CycleEvent(kind: .periodStart, occurredOn: events.last!.occurredOn.adding(days: gap)))
            profile = Cycle.applyingClosedCycles(events: events, profile: profile)
        }
        XCTAssertEqual(profile.phaseMode, .noPhases, "исходное состояние: автоматика увела в режим без фаз")
        XCTAssertEqual(profile.lowConfidenceStreak, 3)

        profile = Cycle.switchingPhaseMode(to: .phases, reason: nil, in: profile, asOf: day(109))
        XCTAssertEqual(profile.lowConfidenceStreak, 0, "серия начинается заново")
        XCTAssertNil(profile.noPhaseReason)
        XCTAssertEqual(profile.lowConfidenceCountedThrough, day(109))

        // Одно плохое закрытие после переключения — выбор пользовательницы держится.
        events.append(CycleEvent(kind: .periodStart, occurredOn: events.last!.occurredOn.adding(days: 20)))
        profile = Cycle.applyingClosedCycles(events: events, profile: profile)
        XCTAssertEqual(profile.lowConfidenceStreak, 1)
        XCTAssertEqual(profile.phaseMode, .phases, "одно закрытие — не три")

        // А три подряд после переключения правило по-прежнему включают: оно не
        // отключено ручным переключением, просто отсчитывается заново.
        for gap in [45, 20] {
            events.append(CycleEvent(kind: .periodStart, occurredOn: events.last!.occurredOn.adding(days: gap)))
            profile = Cycle.applyingClosedCycles(events: events, profile: profile)
        }
        XCTAssertEqual(profile.lowConfidenceStreak, 3)
        XCTAssertEqual(profile.phaseMode, .noPhases, "правило не выключено — просто отсчитывается заново")
    }

    // MARK: - Многосессионная симуляция (implement-feature §5а):
    // phase_response_profile копится по дням — точечных тестов недостаточно.

    func test_simulation30DaysPhaseResponseProfileNeverDriftsBeyondClamp() {
        var profile = PhaseResponseProfile()
        var path: [Double] = []
        var notifiedCount = 0

        // Пользовательница почти всегда «отлично», изредка «тяжело» —
        // адаптивный сигнал, не захардкоженная последовательность: каждый
        // следующий день строится из состояния, оставленного предыдущим.
        for day in 0..<30 {
            let override: Override = day % 7 == 6 ? .ease : .push
            let (next, justNotified) = Cycle.applyingOverride(override, to: profile)
            profile = next
            path.append(profile.adjustment)
            if justNotified { notifiedCount += 1 }
        }

        XCTAssertEqual(profile.sampleSize, 30)
        for value in path {
            XCTAssertGreaterThanOrEqual(value, Cycle.phaseAdjustmentClampRange.lowerBound - 0.0001)
            XCTAssertLessThanOrEqual(value, Cycle.phaseAdjustmentClampRange.upperBound + 0.0001)
        }
        XCTAssertEqual(profile.adjustment, Cycle.phaseAdjustmentClampRange.upperBound, accuracy: 0.0001,
            "мостли push — упирается в потолок клэмпа, не улетает выше")
        XCTAssertEqual(notifiedCount, 1, "уведомление сработало ровно один раз за все 30 дней")
    }

    func test_simulation30CycleClosesLowConfidenceStreakStaysBounded() {
        var profile = CycleProfile()
        // Чередование хороших/плохих закрытий — стриковый счётчик обязан
        // отражать только ПОДРЯД идущие плохие, не общее их число.
        let confidences: [Double] = (0..<30).map { i in
            (i % 5 == 4) ? 0.9 : 0.1
        }
        for confidence in confidences {
            profile = Cycle.applyingCycleClose(confidence: confidence, to: profile)
            XCTAssertLessThanOrEqual(profile.lowConfidenceStreak, 4,
                "хорошее закрытие каждый 5-й раз не даёт стрику убежать дальше 4 (3 плохих подряд + сам сброс на следующем шаге)")
            if profile.phaseMode == .noPhases {
                XCTAssertEqual(profile.noPhaseReason, .lowConfidence)
            }
        }
    }
}
