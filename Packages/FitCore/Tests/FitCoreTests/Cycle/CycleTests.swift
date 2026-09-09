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
        let state = Cycle.state(events: events, profile: profile, asOf: day(0))

        XCTAssertEqual(state.cycleConfidence!, 0.30, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(state.cycleConfidence!, Cycle.categoricalConfidenceThreshold,
            "заявлена regular — фаза показывается")
        XCTAssertEqual(state.periodization?.blockType, .recovery, "категория включена на пороге")
    }

    func test_scenario15_zeroMeasuredCyclesIrregularDeclared() {
        let events = [CycleEvent(kind: .periodStart, occurredOn: day(0))]
        let profile = CycleProfile(declaredRegularity: .irregular)
        let state = Cycle.state(events: events, profile: profile, asOf: day(0))

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
        let state = Cycle.state(events: [], profile: CycleProfile(), asOf: day(0))

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
        let onTime = Cycle.state(events: events, profile: profile, asOf: day(56 + 27))
        let delayed = Cycle.state(events: events, profile: profile, asOf: day(56 + 30))

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
        let state = Cycle.state(events: events, profile: CycleProfile(), asOf: day(56 + 37))
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
        let before = Cycle.state(events: events, profile: profile, asOf: day(60))

        profile.phaseMode = .noPhases
        profile.noPhaseReason = .userChoice
        let inNoPhases = Cycle.state(events: events, profile: profile, asOf: day(60))
        XCTAssertNil(inNoPhases.phase)
        XCTAssertTrue(inNoPhases.hasAnchor, "события никуда не делись")

        profile.phaseMode = .phases
        profile.noPhaseReason = nil
        let after = Cycle.state(events: events, profile: profile, asOf: day(60))
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
        let a = Cycle.state(events: inOrder, profile: profile, asOf: day(90))
        let b = Cycle.state(events: backdated, profile: profile, asOf: day(90))

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
        let noAnchor = Cycle.state(events: [], profile: CycleProfile(), asOf: day(0))
        XCTAssertNil(noAnchor.phase, "оверрайд в этот день не может обучить ни один профиль")

        var noPhaseProfile = CycleProfile()
        noPhaseProfile.phaseMode = .noPhases
        noPhaseProfile.noPhaseReason = .contraception
        let noPhases = Cycle.state(events: starts([28]), profile: noPhaseProfile, asOf: day(35))
        XCTAssertNil(noPhases.phase)
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
        let state = Cycle.state(events: starts([28]), profile: profile, asOf: day(35))
        XCTAssertNil(state.phase)
        XCTAssertNil(state.periodization)
        XCTAssertEqual(state.noPhaseReason, .pregnancy)
    }

    // MARK: - Контракт: квартили/IQR (SPEC §11.3 worked example), не входит в номерные сценарии

    func test_quartilesMatchSpecWorkedExample() {
        let sorted = [27.0, 28, 28, 29, 45]
        XCTAssertEqual(Cycle.quantile(0.25, of: sorted), 28, accuracy: 0.0001)
        XCTAssertEqual(Cycle.quantile(0.75, of: sorted), 29, accuracy: 0.0001)
        XCTAssertEqual(Cycle.rejectingOutliers([27, 28, 28, 29, 45]), [27, 28, 28, 29])
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
        XCTAssertEqual(Cycle.regularityFactor(filteredLengths: [28, 28, 28], declaredRegularity: nil), 1.0)
        // σ ровно на границе 2 включена в верхний бакет.
        XCTAssertEqual(Cycle.regularityFactor(filteredLengths: [26, 30], declaredRegularity: nil), 1.0,
            "σ([26,30]) = 2 ровно")
        // σ в открытом раньше промежутке (2,3] — закрытая правка.
        XCTAssertEqual(Cycle.regularityFactor(filteredLengths: [25, 31], declaredRegularity: nil), 0.7,
            "σ([25,31]) = 3")
        XCTAssertEqual(Cycle.regularityFactor(filteredLengths: [15, 45], declaredRegularity: nil), 0.4,
            "σ([15,45]) = 15 > 5")
    }

    func test_regularityFactorFallsBackToDeclaredBelowTwoMeasuredLengths() {
        XCTAssertEqual(Cycle.regularityFactor(filteredLengths: [], declaredRegularity: .regular), 1.0)
        XCTAssertEqual(Cycle.regularityFactor(filteredLengths: [28], declaredRegularity: .variable), 0.7)
        XCTAssertEqual(Cycle.regularityFactor(filteredLengths: [28], declaredRegularity: .irregular), 0.4)
        XCTAssertEqual(Cycle.regularityFactor(filteredLengths: [], declaredRegularity: nil), 1.0,
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
        let window = Cycle.recentFilteredLengths(lengths)
        XCTAssertEqual(window, [28, 28, 28, 28, 28, 28], "выброс вне окна из 6 самых свежих")
        XCTAssertEqual(Cycle.regularityFactor(filteredLengths: window, declaredRegularity: nil), 1.0,
            "корректное окно — регулярность идеальная, выброс не виден вовсе")

        // Тот же выброс, если бы он оказался ВНУТРИ окна (а не только вне его
        // позиционно), всё равно был бы отфильтрован IQR — «отфильтрованный бы
        // 1.5 IQR» не полагается только на удачную позицию в истории.
        XCTAssertEqual(Cycle.rejectingOutliers([35, 28, 28, 28, 28, 28, 28]), [28, 28, 28, 28, 28, 28],
            "35 — выброс и по IQR, не только по позиции")

        // Контраст — ОШИБОЧНОЕ вычисление, окно «вся история» вместо
        // отфильтрованных последних 6: другой, более низкий бакет (σ по всем
        // 8 значениям ≈2.32 — ровно в промежутке (2,3], который закрыла
        // правка SPEC 5e0e466). Расхождение 1.0 → 0.7 — то самое молчаливое
        // расхождение, о которое эта функция обязана не спотыкаться.
        XCTAssertEqual(Cycle.regularityFactor(filteredLengths: lengths, declaredRegularity: nil), 0.7,
            "если бы окна не различались — другой, заниженный результат")
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
