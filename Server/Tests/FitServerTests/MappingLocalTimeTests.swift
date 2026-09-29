//  Шкала FitCore против настоящих моментов (SPEC §20.7).
//
//  Номер §20.15 у этой темы есть — 20i, — но он про другое и здесь не
//  закрывается: 20i требует, чтобы утомление, записанное в одной зоне и
//  прочитанное в другой, дало тот же распад, а это утверждение о колонках
//  `muscle_fatigue.updated_at` и `exercise_states.last_performed_at`, то есть
//  о живой базе и о срезах `Mapping/`, которых ещё нет.
//
//  Здесь проверяется только примитив, на котором 20i будет стоять: перевод
//  момента и зоны в местные день и `Timestamp`, и разбор ISO-даты. Ошибка
//  ровно здесь не падает и не видна в ответе — она проявляется весом,
//  посчитанным от неверного утомления, поэтому примитив проверяется отдельно,
//  а не «заодно» внутри 20d.

import Testing
import Foundation
import FitCore
@testable import FitServer

@Suite("Mapping/LocalTime: шкала FitCore (§20.7)")
struct MappingLocalTimeTests {

    typealias LocalTime = Mapping.LocalTime

    static let moscow = TimeZone(identifier: "Europe/Moscow")!
    static let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    static let utc = TimeZone(identifier: "UTC")!

    // MARK: - Контракт эпохи

    @Test("полночь дня d — это d × 24 часа (контракт Planner.evaluationMoment)")
    func midnightIsDayTimes24() {
        // 2026-09-29, 00:00 в Москве — то есть 2026-09-28, 21:00 UTC.
        let midnight = Date(timeIntervalSince1970: 1_790_629_200)
        let day = LocalTime.day(of: midnight, in: Self.moscow)
        let stamp = LocalTime.timestamp(of: midnight, in: Self.moscow)
        #expect(day == CalendarDay(year: 2026, month: 9, day: 29))
        #expect(abs(stamp.hoursSinceEpoch - Double(day.dayNumber) * 24) < 1e-9)
        // И тот же день в контракте момента оценки §7.1.
        #expect(Planner.evaluationMoment(for: day).hoursSinceEpoch == Double(day.dayNumber) * 24 + 12)
    }

    @Test("эпоха — 1970-01-01")
    func epochIsUnix() {
        #expect(CalendarDay(year: 1970, month: 1, day: 1).dayNumber == 0)
        #expect(LocalTime.day(of: Date(timeIntervalSince1970: 0), in: Self.utc).dayNumber == 0)
    }

    // MARK: - Зона решает день

    @Test("один момент — разные дни в разных зонах")
    func zoneDecidesTheDay() {
        // 2026-09-29, 23:30 UTC.
        let instant = Date(timeIntervalSince1970: 1_790_724_600)
        #expect(LocalTime.day(of: instant, in: Self.utc) == CalendarDay(year: 2026, month: 9, day: 29))
        #expect(LocalTime.day(of: instant, in: Self.moscow) == CalendarDay(year: 2026, month: 9, day: 30))
        #expect(LocalTime.day(of: instant, in: Self.losAngeles) == CalendarDay(year: 2026, month: 9, day: 29))
    }

    @Test("смещение берётся НА момент, а не постоянное для зоны")
    func offsetFollowsDaylightSaving() {
        // Лос-Анджелес: 1 июля — UTC−7, 1 января — UTC−8. Оба момента взяты
        // в 07:30 UTC, то есть по разные стороны от полуночи по местному
        // времени ровно из-за перехода на летнее время.
        let july = Date(timeIntervalSince1970: 1_782_891_000)   // 2026-07-01 07:30Z
        let january = Date(timeIntervalSince1970: 1_767_252_600) // 2026-01-01 07:30Z
        #expect(Self.losAngeles.secondsFromGMT(for: july) == -7 * 3600)
        #expect(Self.losAngeles.secondsFromGMT(for: january) == -8 * 3600)
        #expect(LocalTime.day(of: july, in: Self.losAngeles) == CalendarDay(year: 2026, month: 7, day: 1))
        #expect(LocalTime.day(of: january, in: Self.losAngeles) == CalendarDay(year: 2025, month: 12, day: 31))
    }

    @Test("зона со смещением в полчаса не теряет его")
    func handlesHalfHourOffsets() {
        let kolkata = TimeZone(identifier: "Asia/Kolkata")!
        let instant = Date(timeIntervalSince1970: 1_790_724_600) // 2026-09-29 23:30Z
        let stamp = LocalTime.timestamp(of: instant, in: kolkata)
        let utcStamp = LocalTime.timestamp(of: instant, in: Self.utc)
        #expect(abs(stamp.hoursSinceEpoch - utcStamp.hoursSinceEpoch - 5.5) < 1e-9)
    }

    // MARK: - ISO-дата

    @Test("разбор и запись — обратные друг другу", arguments: [
        "1970-01-01", "2026-09-29", "2024-02-29", "2000-02-29", "2026-12-31"
    ])
    func isoRoundTrips(text: String) throws {
        let day = try #require(LocalTime.day(iso: text))
        #expect(LocalTime.iso(day) == text)
    }

    @Test("несуществующая дата не разбирается", arguments: [
        "2026-02-31", "2025-02-29", "2026-13-01", "2026-00-10", "2026-04-31", "2026-09-00"
    ])
    func rejectsImpossibleDates(text: String) {
        #expect(LocalTime.day(iso: text) == nil)
    }

    @Test("форма строгая: ровно 4-2-2 цифры", arguments: [
        "2026-9-29", "26-09-29", "2026-09-29T00:00:00Z", "2026/09/29",
        " 2026-09-29", "2026-09-29 ", "", "2026-09", "20260929", "2026-0９-29"
    ])
    func rejectsMalformedForms(text: String) {
        #expect(LocalTime.day(iso: text) == nil)
    }

    @Test("високосность считается календарём, а не таблицей длин месяцев")
    func leapYearsFollowGregorianRules() {
        // 1900 не високосный (делится на 100, не на 400), 2000 — високосный.
        #expect(LocalTime.day(iso: "1900-02-29") == nil)
        #expect(LocalTime.day(iso: "2000-02-29") != nil)
    }

    @Test("civil(from:) обратна CalendarDay(year:month:day:) на длинном прогоне")
    func civilIsInverseOfConstructor() {
        // Пятьдесят лет подряд: ошибка в алгоритме Хиннанта живёт не в
        // отдельной дате, а в границе века или эры, и одиночными примерами
        // она не ловится.
        for dayNumber in stride(from: 0, through: 20_000, by: 1) {
            let day = CalendarDay(dayNumber: dayNumber)
            let civil = LocalTime.civil(from: day)
            #expect(CalendarDay(year: civil.year, month: civil.month, day: civil.day) == day)
        }
    }
}
