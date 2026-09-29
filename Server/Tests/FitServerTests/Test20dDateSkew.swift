//  Тест 20d (§20.15): присланная дата расходится с серверной больше чем на
//  сутки → 422.
//
//  Базы тест не требует: §20.7 велит валидировать `date`/`tz` ДО любой записи,
//  то есть отказ обязан случиться раньше, чем открыта транзакция. Это же
//  свойство делает половину теста проверяемой прямо на `RequestDay` — там, где
//  решение принимается, а не там, где оно доезжает.
//
//  **Вторая половина ждёт первого доменного роута, и её тут нет.** «→ 422»
//  есть утверждение о HTTP-ответе, а из четырнадцати путей §20.3 сегодня
//  смонтированы два, и оба — `/v1/content/*`, которые ни `date`, ни `tz` не
//  принимают вовсе (§20.5, §20.11). Пока это так, 20d закрыт наполовину, и
//  считать его сделанным нельзя — по тому же правилу, по которому §20.4 завёл
//  отдельный номер 20k, чтобы 20a нельзя было отметить сделанным раньше
//  времени.
//
//  Момент «сейчас» инжектируется, а не берётся из часов машины: тест про
//  расхождение часов, который сам зависит от часов, зелёный ровно до полуночи.

import Testing
import Foundation
import FitAPI
import FitCore
@testable import FitServer

@Suite("20d: суточный допуск даты (§20.7, §20.15)")
struct Test20dDateSkew {

    /// 2026-09-29, 12:00 UTC.
    static let noon = Date(timeIntervalSince1970: 1_790_683_200)

    private func validate(_ date: String, _ tz: String, at instant: Date = noon) throws -> RequestDay {
        try RequestDay.validated(date: date, tz: tz, at: instant)
    }

    private func code(_ date: String, _ tz: String, at instant: Date = noon) -> APIErrorCode? {
        do {
            _ = try validate(date, tz, at: instant)
            return nil
        } catch let error as APIError {
            return error.code
        } catch {
            return nil
        }
    }

    // MARK: - Допуск

    @Test("сегодняшняя дата принимается")
    func acceptsToday() throws {
        let day = try validate("2026-09-29", "Europe/Moscow")
        #expect(day.date == CalendarDay(year: 2026, month: 9, day: 29))
        #expect(day.serverDate == day.date)
    }

    @Test("вчера и завтра принимаются — полночь и запись вчерашней тренировки (§20.7)",
          arguments: ["2026-09-28", "2026-09-30"])
    func acceptsOneDaySkew(date: String) throws {
        #expect(throws: Never.self) { try validate(date, "Europe/Moscow") }
    }

    @Test("расхождение в двое суток отклоняется", arguments: ["2026-09-27", "2026-10-01"])
    func rejectsTwoDaySkew(date: String) {
        #expect(code(date, "Europe/Moscow") == .dateSkew)
    }

    @Test("date_skew — это 422, а не 409")
    func skewStatusIs422() {
        #expect(APIErrorCode.dateSkew.httpStatus == 422)
    }

    @Test("details несёт обе даты и зону, без русского текста")
    func detailsCarryBothDates() throws {
        do {
            _ = try validate("2026-10-05", "Europe/Moscow")
            Issue.record("расхождение в неделю обязано отклоняться")
        } catch let error as APIError {
            #expect(error.details?["sent"] == .string("2026-10-05"))
            #expect(error.details?["server"] == .string("2026-09-29"))
            #expect(error.details?["tz"] == .string("Europe/Moscow"))
            #expect(error.details?["skew_days"] == .int(-6))
        }
    }

    // MARK: - Зона считает день, а не просто едет в ответе

    @Test("дата, действительная в одной зоне, может быть недействительна в другой")
    func zoneDecidesTheDay() throws {
        // 2026-09-29, 23:30 UTC: в Москве (UTC+3) уже 30 сентября, в
        // Лос-Анджелесе (UTC−7) ещё 29-е. Одна и та же присланная дата
        // обязана сверяться с разной серверной.
        let lateEvening = Date(timeIntervalSince1970: 1_790_724_600)
        let moscow = try RequestDay.validated(date: "2026-09-30", tz: "Europe/Moscow", at: lateEvening)
        let losAngeles = try RequestDay.validated(date: "2026-09-29", tz: "America/Los_Angeles", at: lateEvening)
        #expect(moscow.serverDate == CalendarDay(year: 2026, month: 9, day: 30))
        #expect(losAngeles.serverDate == CalendarDay(year: 2026, month: 9, day: 29))
    }

    // MARK: - Форма, а не расхождение

    @Test("зона, которой нет, — validation_failed с полем tz",
          arguments: ["MSK", "Moscow", "", "Europe/Moskva", "+03:00", "Europe/Moscow "])
    func rejectsUnknownZone(tz: String) {
        #expect(code("2026-09-29", tz) == .validationFailed)
    }

    @Test("сверх имён IANA принимаются смещения и легаси-аббревиатуры",
          arguments: ["UTC+3", "GMT+3", "Etc/GMT-3", "PST", "CET"])
    func acceptsMoreThanIANANames(tz: String) throws {
        // Утверждение ОПИСЫВАЕТ поведение, а не одобряет его. §20.7 говорит
        // «IANA-зона», а `TimeZone(identifier:)` разбирает сверх неё две вещи:
        // формы с фиксированным смещением (`UTC+3` → `GMT+0300`) и легаси-ссылки
        // базы tz (`PST`, `CET`). `MSK` при этом не разбирается, а `Etc/GMT-3`
        // — настоящее имя IANA, так что простого правила вида «запретить всё с
        // плюсом» или «запретить аббревиатуры» не существует.
        //
        // Цена фиксированного смещения видна не сразу: день считается верно
        // ровно до ближайшего перехода на летнее время, а после — молча мимо,
        // то есть ровно тот класс ошибки, который §20.7 разбирает отдельным
        // абзацем. Но сузить разбор до `TimeZone.knownTimeZoneIdentifiers` —
        // решение о том, что сервер принимает от двух клиентов, а §20.7 его не
        // принимал. Тест закрепляет сегодняшнее поведение, чтобы смена была
        // видна как смена, а не как случайность (server-domain §1).
        #expect(throws: Never.self) { try validate("2026-09-29", tz) }
    }

    @Test("дата не в yyyy-mm-dd — validation_failed с полем date",
          arguments: ["2026-9-29", "29.09.2026", "2026-09-29T00:00:00Z", "2026-09-31", "2025-02-29", ""])
    func rejectsMalformedDate(date: String) {
        #expect(code(date, "Europe/Moscow") == .validationFailed)
    }

    @Test("поле названо в details")
    func namesTheField() {
        func field(_ date: String, _ tz: String) -> APIDetailValue? {
            do {
                _ = try validate(date, tz)
                return nil
            } catch let error as APIError {
                return error.details?["field"]
            } catch {
                return nil
            }
        }
        #expect(field("2026-09-29", "MSK") == .string("tz"))
        #expect(field("29.09.2026", "Europe/Moscow") == .string("date"))
    }

    @Test("зона разбирается раньше даты: без неё сверять не с чем")
    func zoneIsParsedFirst() {
        // Обе половины негодны. Ожидается отказ по зоне, потому что серверная
        // дата без зоны не существует, и порядок здесь не косметика.
        do {
            _ = try validate("29.09.2026", "MSK")
            Issue.record("обязано отклоняться")
        } catch let error as APIError {
            #expect(error.details?["field"] == .string("tz"))
        } catch {
            Issue.record("ожидался APIError")
        }
    }

    // MARK: - Момент запроса

    @Test("now — фактический момент на шкале FitCore в зоне клиента (§20.3)")
    func nowIsOnFitCoreScale() throws {
        let day = try validate("2026-09-29", "Europe/Moscow")
        // 12:00 UTC = 15:00 в Москве, то есть полдень дня плюс три часа.
        let midnight = Double(day.date.dayNumber) * 24
        #expect(abs(day.now.hoursSinceEpoch - (midnight + 15)) < 1e-9)
    }
}
