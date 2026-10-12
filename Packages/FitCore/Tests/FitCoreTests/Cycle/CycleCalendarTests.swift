//  CycleCalendar — сетка §11.6: свёртка фаз, дни месячных, прогноз с
//  диапазоном, оценка овуляции, `overdue`, даты дней.

import XCTest
@testable import FitCore

final class CycleCalendarTests: XCTestCase {

    private func d(_ n: Int) -> CalendarDay { CalendarDay(dayNumber: 30_000 + n) }
    private func start(_ n: Int) -> CycleEvent { CycleEvent(kind: .periodStart, occurredOn: d(n)) }
    private func end(_ n: Int) -> CycleEvent { CycleEvent(kind: .periodEnd, occurredOn: d(n)) }

    /// Три ровных цикла по 28 дней, текущий начался в день 84.
    private let regular = [0, 28, 56, 84].map { CycleEvent(kind: .periodStart, occurredOn: CalendarDay(dayNumber: 30_000 + $0)) }

    private func entry(_ calendar: CycleCalendar, _ n: Int) -> CycleCalendarEntry {
        calendar.days.first { $0.date == d(n) }!
    }

    // MARK: - Свёртка

    func test_fiveSegmentsFoldIntoFour() {
        XCTAssertEqual(Phase.menstrual.displayPhase, .menstrual)
        XCTAssertEqual(Phase.follicular.displayPhase, .follicular)
        XCTAssertEqual(Phase.ovulatory.displayPhase, .ovulatory)
        XCTAssertEqual(Phase.earlyLuteal.displayPhase, .luteal)
        XCTAssertEqual(Phase.lateLuteal.displayPhase, .luteal)
    }

    // MARK: - Диапазон

    func test_halfWidthStepsByRegularityFactor() {
        XCTAssertEqual(Cycle.forecastHalfWidthDays(regularityFactor: 1.0), 2)
        XCTAssertEqual(Cycle.forecastHalfWidthDays(regularityFactor: 0.7), 5)
        XCTAssertEqual(Cycle.forecastHalfWidthDays(regularityFactor: 0.4), 7)
    }

    func test_regularHistory_forecastFromExpectedLengthWithNarrowRange() {
        let calendar = Cycle.calendar(events: regular, profile: CycleProfile(), from: d(84), to: d(120), asOf: d(94))
        let next = calendar.nextPeriod!
        XCTAssertEqual(next.expected, d(112))
        XCTAssertEqual(next.rangeStart, d(110))
        XCTAssertEqual(next.rangeEnd, d(114))
        let state = Cycle.state(events: regular, profile: CycleProfile(), responseProfiles: [:], asOf: d(94))
        XCTAssertEqual(next.cycleConfidence, state.cycleConfidence!, accuracy: 1e-9)
        XCTAssertFalse(calendar.overdue)
    }

    func test_irregularHistory_widerRangeAndLowerConfidence() {
        // Длины 22, 35, 24, 36: σ > 5 → regularityFactor 0.4 → ±7.
        let events = [0, 22, 57, 81, 117].map(start)
        let calendar = Cycle.calendar(events: events, profile: CycleProfile(), from: d(117), to: d(130), asOf: d(120))
        let next = calendar.nextPeriod!
        XCTAssertEqual(next.expected.days(until: next.rangeEnd), 7)
        XCTAssertEqual(next.rangeStart.days(until: next.expected), 7)
        let regularConfidence = Cycle.calendar(events: regular, profile: CycleProfile(), from: d(84), to: d(84),
                                               asOf: d(87)).nextPeriod!.cycleConfidence
        XCTAssertLessThan(next.cycleConfidence, regularConfidence)
    }

    func test_declaredVariable_beforeTwoMeasurements_givesMiddleStep() {
        let calendar = Cycle.calendar(events: [start(0)], profile: CycleProfile(declaredRegularity: .variable),
                                      from: d(0), to: d(0), asOf: d(3))
        XCTAssertEqual(calendar.nextPeriod!.expected.days(until: calendar.nextPeriod!.rangeEnd), 5)
    }

    func test_forecastUsesDeclaredLengthBeforeFirstMeasurement() {
        let calendar = Cycle.calendar(events: [start(0)], profile: CycleProfile(typicalCycleLengthDays: 32),
                                      from: d(0), to: d(0), asOf: d(3))
        XCTAssertEqual(calendar.nextPeriod!.expected, d(32))
    }

    // MARK: - overdue

    func test_overdueFromTheExpectedDateOn() {
        let before = Cycle.calendar(events: regular, profile: CycleProfile(), from: d(84), to: d(84), asOf: d(111))
        let on = Cycle.calendar(events: regular, profile: CycleProfile(), from: d(84), to: d(84), asOf: d(112))
        XCTAssertFalse(before.overdue)
        XCTAssertTrue(on.overdue)
    }

    // MARK: - Дни месячных

    func test_markedEnd_marksTheWholeRange() {
        let periods = Cycle.periodDays(events: [start(0), end(3)], profile: CycleProfile())
        XCTAssertEqual((0...3).map { periods[d($0)] }, Array(repeating: .marked, count: 4))
        XCTAssertNil(periods[d(4)])
    }

    func test_noEnd_startMarkedRestEstimatedFromDeclaredLength() {
        let periods = Cycle.periodDays(events: [start(0)], profile: CycleProfile(typicalPeriodLengthDays: 4))
        XCTAssertEqual(periods[d(0)], .marked)
        XCTAssertEqual((1...3).map { periods[d($0)] }, Array(repeating: .estimated, count: 3))
        XCTAssertNil(periods[d(4)])
    }

    func test_noEndNoDeclared_fiveDays() {
        let periods = Cycle.periodDays(events: [start(0)], profile: CycleProfile())
        XCTAssertEqual(periods[d(4)], .estimated)
        XCTAssertNil(periods[d(5)])
    }

    func test_periodNeverCrossesTheNextStart() {
        let periods = Cycle.periodDays(events: [start(0), start(3), end(5)], profile: CycleProfile())
        XCTAssertEqual(periods[d(0)], .marked)
        XCTAssertEqual(periods[d(2)], .estimated, "конец 5 относится ко второму началу, не к первому")
        XCTAssertEqual((3...5).map { periods[d($0)] }, Array(repeating: .marked, count: 3))

        // Второй период короче хвоста первого: хвост не переживает новое начало.
        let short = Cycle.periodDays(events: [start(0), start(3), end(3)], profile: CycleProfile())
        XCTAssertEqual(short[d(3)], .marked)
        XCTAssertNil(short[d(4)], "расчётные дни первого периода обрываются на следующем начале")
    }

    // MARK: - Даты дней

    func test_everyDayOfTheRangeExactlyOnceInOrder() {
        let calendar = Cycle.calendar(events: regular, profile: CycleProfile(), from: d(80), to: d(100), asOf: d(94))
        XCTAssertEqual(calendar.days.map(\.date), (80...100).map(d))
    }

    func test_todayMatchesTheDayCard() {
        for today in [86, 94, 99, 105] {
            let calendar = Cycle.calendar(events: regular, profile: CycleProfile(), from: d(84), to: d(111), asOf: d(today))
            let state = Cycle.state(events: regular, profile: CycleProfile(), responseProfiles: [:], asOf: d(today))
            XCTAssertEqual(entry(calendar, today).phase, state.phase?.displayPhase, "день \(today)")
            XCTAssertEqual(entry(calendar, today).cycleConfidence, state.cycleConfidence, "день \(today)")
        }
    }

    func test_pastDayIsComputedOnItsOwnDate() {
        // Заявлено 35: на день 20 по событиям не позже него ожидаемая длина
        // 35, овуляция ~21, день 20 — овуляторный. Отметка в день 28 случилась
        // позже: по всем событиям день 20 считался бы от неё и вышел бы другим.
        let profile = CycleProfile(typicalCycleLengthDays: 35)
        let events = [start(0), start(28)]
        let calendar = Cycle.calendar(events: events, profile: profile, from: d(0), to: d(30), asOf: d(30))
        let asOfThen = Cycle.state(events: [start(0)], profile: profile, responseProfiles: [:], asOf: d(20))
        XCTAssertEqual(asOfThen.phase, .ovulatory)
        XCTAssertEqual(entry(calendar, 20).phase, .ovulatory)
        XCTAssertTrue(entry(calendar, 21).ovulationEstimate, "овуляция того цикла — по его прогнозу: 35 − 14")
    }

    func test_ovulationEstimateIsFourteenDaysBeforeExpectedStart() {
        let calendar = Cycle.calendar(events: regular, profile: CycleProfile(), from: d(84), to: d(111), asOf: d(90))
        let marked = calendar.days.filter(\.ovulationEstimate).map(\.date)
        XCTAssertEqual(marked, [calendar.nextPeriod!.expected.adding(days: -14)])
        XCTAssertNotNil(entry(calendar, 98).phase, "оценка только там, где фаза показывается")
    }

    func test_expectedPeriodIsForecastWithoutPhase_andNothingBeyond() {
        let calendar = Cycle.calendar(events: regular, profile: CycleProfile(), from: d(84), to: d(130), asOf: d(94))
        XCTAssertNotNil(entry(calendar, 111).phase, "до ожидаемой даты фаза считается")
        for n in 112...116 {
            XCTAssertEqual(entry(calendar, n).period, .forecast, "день \(n)")
            XCTAssertNil(entry(calendar, n).phase, "день \(n)")
        }
        for n in 117...130 {
            XCTAssertEqual(entry(calendar, n), CycleCalendarEntry(date: d(n)), "за концом ожидаемых месячных — ничего: \(n)")
        }
    }

    func test_forecastLengthFollowsDeclaredPeriodLength() {
        let calendar = Cycle.calendar(events: regular, profile: CycleProfile(typicalPeriodLengthDays: 3),
                                      from: d(84), to: d(120), asOf: d(94))
        XCTAssertEqual(calendar.days.filter { $0.period == .forecast }.map(\.date), (112...114).map(d))
    }

    func test_horizonIsNinetyThreeDaysFromToday() {
        // Измеренные циклы по 85 дней (меньше порога перерыва 90) и месячные
        // по 14: ожидаемые месячные 255…268, а горизонт — сегодня (170) + 93 =
        // 263. Дальше горизонта ничего, даже внутри ожидаемых месячных.
        let events = [0, 85, 170].map(start)
        let profile = CycleProfile(typicalPeriodLengthDays: 14)
        let calendar = Cycle.calendar(events: events, profile: profile, from: d(250), to: d(270), asOf: d(170))
        XCTAssertEqual(calendar.nextPeriod!.expected, d(255))
        XCTAssertEqual(entry(calendar, 263).period, .forecast)
        XCTAssertEqual(entry(calendar, 264), CycleCalendarEntry(date: d(264)))
    }

    func test_overdue_todayOnItsDate_restOfExpectedPeriodForecast() {
        // Прогноз 112, сегодня 113: сегодня считается на свою дату (поздняя
        // лютеиновая, уверенность 0.6 от просрочки на день), 114…116 —
        // прогнозные месячные, дальше ничего.
        let calendar = Cycle.calendar(events: regular, profile: CycleProfile(), from: d(112), to: d(120), asOf: d(113))
        XCTAssertTrue(calendar.overdue)
        XCTAssertEqual(entry(calendar, 113).phase, .luteal)
        XCTAssertEqual(entry(calendar, 113).cycleConfidence!, 0.6, accuracy: 1e-9)
        XCTAssertEqual((114...116).map { entry(calendar, $0).period }, [.forecast, .forecast, .forecast])
        XCTAssertEqual(entry(calendar, 117), CycleCalendarEntry(date: d(117)))
    }

    func test_overdueBeyondExpectedPeriod_futureEmpty_todayFadesOnItsOwn() {
        let calendar = Cycle.calendar(events: regular, profile: CycleProfile(), from: d(118), to: d(125), asOf: d(120))
        XCTAssertTrue(calendar.overdue)
        XCTAssertNil(entry(calendar, 120).phase, "просрочка на 8 дней — recencyFactor 0, фаза не называется")
        XCTAssertEqual(entry(calendar, 121), CycleCalendarEntry(date: d(121)))
    }

    // MARK: - Порог и режимы

    func test_belowThresholdNoPhaseNoOvulation_forecastStays() {
        let profile = CycleProfile(declaredRegularity: .irregular) // 0.3 × 0.4 = 0.12
        let calendar = Cycle.calendar(events: [start(0)], profile: profile, from: d(0), to: d(27), asOf: d(5))
        XCTAssertTrue(calendar.days.allSatisfy { $0.phase == nil && $0.cycleConfidence == nil && !$0.ovulationEstimate })
        XCTAssertEqual(calendar.nextPeriod!.cycleConfidence, 0.12, accuracy: 1e-9)
    }

    func test_noPhasesMode_periodsOnly() {
        let profile = CycleProfile(phaseMode: .noPhases, noPhaseReason: .contraception)
        let calendar = Cycle.calendar(events: regular, profile: profile, from: d(84), to: d(120), asOf: d(94))
        XCTAssertNil(calendar.nextPeriod)
        XCTAssertFalse(calendar.overdue)
        XCTAssertTrue(calendar.days.allSatisfy { $0.phase == nil && $0.period != .forecast })
        XCTAssertEqual(entry(calendar, 84).period, .marked)
    }

    func test_noAnchor_nothingButEmptyDays() {
        let calendar = Cycle.calendar(events: [], profile: CycleProfile(), from: d(0), to: d(5), asOf: d(3))
        XCTAssertNil(calendar.nextPeriod)
        XCTAssertFalse(calendar.overdue)
        XCTAssertEqual(calendar.days, (0...5).map { CycleCalendarEntry(date: d($0)) })
    }

    func test_futureDatedStartIsShownButNotUsed() {
        var events = regular
        events.append(start(97))
        let calendar = Cycle.calendar(events: events, profile: CycleProfile(), from: d(84), to: d(120), asOf: d(94))
        XCTAssertEqual(entry(calendar, 97).period, .marked, "отметка — факт и видна")
        XCTAssertEqual(calendar.nextPeriod!.expected, d(112), "в прогноз событие позже сегодня не входит")
    }
}
