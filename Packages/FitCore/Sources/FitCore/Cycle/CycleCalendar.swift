//  CycleCalendar — месячная сетка цикла (SPEC §11.6, путь §20.3
//  `GET /v1/cycle/calendar`).
//
//  Новой модели здесь нет: каждый день считается теми же функциями конвейера,
//  что карточка дня (`Cycle.state`, `expectedLength`, `regularityFactor`), и
//  календарь не может назвать фазу, которую не назвала бы карточка того же
//  дня. Своё у календаря только три вещи, и все три — показ, а не расчёт
//  нагрузки:
//
//  - **Свёртка пяти сегментов в четыре** (`DisplayPhase`): лютеиновая на экране
//    одна, в модели — две (§11.2 даёт им разные блоки).
//  - **Дни месячных как факт** (`PeriodDay`): отмеченные, расчётные (конец не
//    отмечен — цепочка `menstrualEnd` §11.1) и прогнозные.
//  - **Прогноз следующего начала с диапазоном** (`NextPeriod`): полуширина
//    ступенями по `regularityFactor` — 2 / 5 / 7 дней.
//
//  Даты дней (§11.6):
//  - прошлые и сегодня — на свою дату, по событиям не позже неё: фаза дня
//    совпадает с той, что `workouts.cycle_phase` записала в тот день;
//  - будущие до ожидаемого начала — на свою дату по событиям, известным
//    сегодня; `recencyFactor` сам гасит уверенность за прогнозом;
//  - дни ожидаемых месячных — `forecast`, без фазы: о них говорит прогноз;
//  - дальше конца ожидаемых месячных и дальше `calendarHorizonDays` от
//    сегодня — ничего.
//
//  Порог 0.3 (`categoricalConfidenceThreshold`) — тот же, что у карточки дня:
//  ниже него фаза и оценка овуляции не отдаются (§11.3, §14.6).

/// Фаза на экране календаря (SPEC §11.6): четыре вместо пяти сегментов модели.
public enum DisplayPhase: String, Sendable, Equatable, Hashable, CaseIterable {
    case menstrual
    case follicular
    case ovulatory
    case luteal
}

extension Phase {
    /// Свёртка §11.6: ранняя и поздняя лютеиновая — одна фаза на экране.
    public var displayPhase: DisplayPhase {
        switch self {
        case .menstrual: return .menstrual
        case .follicular: return .follicular
        case .ovulatory: return .ovulatory
        case .earlyLuteal, .lateLuteal: return .luteal
        }
    }
}

/// День месячных на сетке (SPEC §11.6, §20.3 `period`).
public enum PeriodDay: String, Sendable, Equatable, Hashable {
    /// День `period_start` и дни до отмеченного `period_end` включительно.
    case marked
    /// Остальные дни расчётной длительности, когда конец не отмечен.
    case estimated
    /// Дни ожидаемых месячных — прогноз, не факт.
    case forecast
}

/// Ожидаемое начало следующих месячных и диапазон вокруг него.
public struct NextPeriod: Sendable, Equatable {
    public var expected: CalendarDay
    public var rangeStart: CalendarDay
    public var rangeEnd: CalendarDay
    /// Уверенность на сегодня — та же, что у карточки дня (§14.6).
    public var cycleConfidence: Double

    public init(expected: CalendarDay, rangeStart: CalendarDay, rangeEnd: CalendarDay,
                cycleConfidence: Double) {
        self.expected = expected
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.cycleConfidence = cycleConfidence
    }
}

public struct CycleCalendarEntry: Sendable, Equatable {
    public var date: CalendarDay
    public var period: PeriodDay?
    /// `nil` ниже порога 0.3, на днях `forecast`, за горизонтом и везде, где
    /// фаза не вычисляется.
    public var phase: DisplayPhase?
    /// Едет с каждой не-`nil` фазой и только с ней (§14.6).
    public var cycleConfidence: Double?
    /// Примерный день овуляции: ожидаемое начало следующих месячных минус 14
    /// дней (§11.6). Только там, где показывается фаза.
    public var ovulationEstimate: Bool

    public init(date: CalendarDay, period: PeriodDay? = nil, phase: DisplayPhase? = nil,
                cycleConfidence: Double? = nil, ovulationEstimate: Bool = false) {
        self.date = date
        self.period = period
        self.phase = phase
        self.cycleConfidence = cycleConfidence
        self.ovulationEstimate = ovulationEstimate
    }
}

public struct CycleCalendar: Sendable, Equatable {
    /// `nil` без опорной даты и в режиме без фаз.
    public var nextPeriod: NextPeriod?
    /// Сегодня не раньше ожидаемой даты, а нового `period_start` нет.
    public var overdue: Bool
    /// Каждый день `[from, to]` ровно один раз, по возрастанию.
    public var days: [CycleCalendarEntry]

    public init(nextPeriod: NextPeriod?, overdue: Bool, days: [CycleCalendarEntry]) {
        self.nextPeriod = nextPeriod
        self.overdue = overdue
        self.days = days
    }
}

extension Cycle {

    /// SPEC §11.6: дальше этого числа дней от сегодня сетка ничего не считает.
    /// То же число — предел запроса `from…to` (§20.3).
    public static let calendarHorizonDays = 93

    /// SPEC §11.6: полуширина диапазона ожидаемого начала по ступени
    /// `regularityFactor`. 2 и 5 — верхние границы первых двух полос σ, 7 —
    /// последняя конечная ступень промаха (`recencyFactor`, 4–7 дней).
    public static func forecastHalfWidthDays(regularityFactor: Double) -> Int {
        if regularityFactor >= 1.0 { return 2 }
        if regularityFactor >= variableRegularityFactor { return 5 }
        return 7
    }

    /// Месячная сетка `[from, to]` на сегодня `today`.
    ///
    /// `events` — все известные события, в том числе датированные позже
    /// `today`: дни месячных — факт и показываются по всем событиям, а в
    /// расчёт фаз и прогноза события позже `today` не входят (§20.6).
    public static func calendar(
        events: [CycleEvent],
        profile: CycleProfile,
        from: CalendarDay,
        to: CalendarDay,
        asOf today: CalendarDay
    ) -> CycleCalendar {
        let known = events.filter { $0.occurredOn <= today }
        let periods = periodDays(events: events, profile: profile)

        var nextPeriod: NextPeriod?
        var forecast: ClosedRange<CalendarDay>?
        if profile.phaseMode == .phases, let lastStart = periodStartDays(from: known).last {
            let lengths = measuredLengths(from: known)
            let expectedLen = expectedLength(measuredLengths: lengths, profile: profile)
            let expected = lastStart.adding(days: expectedLen)
            let width = forecastHalfWidthDays(regularityFactor: regularityFactor(
                window: recentWindow(lengths), declaredRegularity: profile.declaredRegularity))
            let current = dayState(events: known, profile: profile, asOf: today)
            nextPeriod = NextPeriod(expected: expected,
                                    rangeStart: expected.adding(days: -width),
                                    rangeEnd: expected.adding(days: width),
                                    cycleConfidence: current.state.cycleConfidence ?? 0)
            let periodLength = profile.typicalPeriodLengthDays ?? defaultPeriodLengthDays
            forecast = expected...expected.adding(days: periodLength - 1)
        }
        let horizon = min(forecast?.upperBound ?? today, today.adding(days: calendarHorizonDays))

        var days: [CycleCalendarEntry] = []
        var day = from
        while day <= to {
            defer { day = day.adding(days: 1) }
            var entry = CycleCalendarEntry(date: day, period: periods[day])
            if day > today {
                guard day <= horizon else { days.append(entry); continue }
                if let forecast, forecast.contains(day) {
                    if entry.period == nil { entry.period = .forecast }
                    days.append(entry)
                    continue
                }
            }
            // Прошлые и сегодня — по событиям не позже дня; будущие — по
            // известным сегодня (они и так не позже `today < day`).
            let basis = day <= today ? known.filter { $0.occurredOn <= day } : known
            let resolved = dayState(events: basis, profile: profile, asOf: day)
            if let phase = resolved.state.phase, let confidence = resolved.state.cycleConfidence,
               confidence >= categoricalConfidenceThreshold {
                entry.phase = phase.displayPhase
                entry.cycleConfidence = confidence
                // Ожидаемое начало — день цикла `expectedLength + 1`, за 14
                // дней до него — день `expectedLength − 13`. Это на день позже
                // `ovulationDay` §11.1 (`expectedLength − 14`) и внутри
                // овуляторной фазы (`ovulationDay − 1 … ovulationDay + 2`).
                entry.ovulationEstimate = resolved.cycleDay.map { $0 + 13 == resolved.expectedLength } ?? false
            }
            days.append(entry)
        }

        return CycleCalendar(nextPeriod: nextPeriod,
                             overdue: nextPeriod.map { today >= $0.expected } ?? false,
                             days: days)
    }

    /// SPEC §11.1: последнее звено цепочки длительности месячных.
    static let defaultPeriodLengthDays = 5

    /// Состояние дня вместе с днём цикла и ожидаемой длиной — их нужно знать
    /// для оценки овуляции, а `CycleState` их не несёт.
    ///
    /// `responseProfiles` пуст намеренно: личный профиль §11.4 сдвигает только
    /// поправку готовности, а календарь её не показывает; фаза и уверенность от
    /// него не зависят.
    private static func dayState(events: [CycleEvent], profile: CycleProfile,
                                 asOf day: CalendarDay) -> (state: CycleState, cycleDay: Int?, expectedLength: Int) {
        let state = Cycle.state(events: events, profile: profile, responseProfiles: [:], asOf: day)
        let expected = expectedLength(measuredLengths: measuredLengths(from: events), profile: profile)
        return (state, cycleDay(events: events, asOf: day), expected)
    }

    /// Дни месячных по всем событиям (SPEC §11.6): от каждого `period_start`
    /// до отмеченного конца (первый `period_end` не раньше начала и раньше
    /// следующего начала) — `marked`; без конца — начало `marked`, остальные
    /// дни цепочки §11.1 (заявленная длительность, иначе 5) — `estimated`.
    /// Ни один день не выходит за следующее начало.
    static func periodDays(events: [CycleEvent], profile: CycleProfile) -> [CalendarDay: PeriodDay] {
        let starts = periodStartDays(from: events)
        let ends = events.filter { $0.kind == .periodEnd }.map(\.occurredOn).sorted()
        var result: [CalendarDay: PeriodDay] = [:]
        for (i, start) in starts.enumerated() {
            let next = i + 1 < starts.count ? starts[i + 1] : nil
            let end = ends.first { $0 >= start && (next == nil || $0 < next!) }
            let last = end ?? start.adding(days: (profile.typicalPeriodLengthDays ?? defaultPeriodLengthDays) - 1)
            var day = start
            while day <= last, next == nil || day < next! {
                result[day] = (end != nil || day == start) ? .marked : .estimated
                day = day.adding(days: 1)
            }
        }
        return result
    }
}
