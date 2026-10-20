//  Локальный день и зона клиента, проверенные до любой записи (SPEC §20.7).
//
//  §20.7: клиент присылает локальную дату и IANA-зону в каждом запросе, где
//  день имеет значение; сервер вычисляет дату из СВОИХ часов в присланной зоне
//  и отклоняет запрос, если присланная отличается больше чем на сутки. Сервер
//  не берёт день из своих часов ни в одном пути.
//
//  Допуск ровно в сутки, и он не запас: §20.7 называет оба случая, ради
//  которых он существует, — полночь и запись вчерашней тренировки. Больший
//  разрыв — сбитые часы, и молча считать по ним нельзя (тест 20d).
//
//  С перекосом §20.5 путать нельзя, и величины расходятся на три порядка: там
//  сверяются часы сервера с Supabase, обе машины по NTP, и минуты хватает; тут
//  — часы телефона с сервером, и сутки берутся из поведения пользователя, а не
//  из сети.
//
//  ── Почему проверка отдельным типом, а не строкой в каждом роуте ───────────
//
//  «Сервер их валидирует ДО любой записи» — утверждение о порядке, то есть ровно
//  того рода, которое `DB/` уже один раз перевёл из дисциплины в свойство типа
//  (§20.4). Здесь то же самое в меньшем масштабе: день в роут попадает только
//  разобранным, потому что другого конструктора у `RequestDay` нет, а сырые
//  `date`/`tz` дальше не ходят.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import FitAPI
import FitCore
import Vapor

/// День запроса, прошедший проверку §20.7.
public struct RequestDay: Sendable, Equatable {

    /// Локальная дата клиента на шкале FitCore.
    public let date: CalendarDay

    /// Зона клиента. Нужна дальше `Mapping/`: конверсия настоящих моментов в
    /// шкалу FitCore делается один раз, при записи, именно в ней (§20.7).
    public let timeZone: TimeZone

    /// Фактический момент запроса на шкале FitCore, в зоне клиента.
    ///
    /// Не украшение: §20.3 разводит момент оценки по роли числа, и
    /// `weight_readiness`, `prescribed_kg` и `target_rir` считаются на
    /// фактическом моменте старта, а не на 12:00.
    public let now: Timestamp

    /// Дата по часам СЕРВЕРА в зоне клиента — то, с чем сверялась присланная.
    public let serverDate: CalendarDay
}

extension RequestDay {

    /// Символы, из которых состоят имена зон IANA.
    static let zoneAlphabet: Set<Unicode.Scalar> = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/_+-".unicodeScalars)

    /// Допуск §20.7, в днях. Расхождение больше него — `date_skew` и 422.
    public static let maxSkewDays = 1

    /// Разбор и проверка пары `date`/`tz`.
    ///
    /// Три отказа, и они разные по смыслу: зона не IANA и дата не `yyyy-mm-dd`
    /// — это `validation_failed` с полем в `details`, то есть тело не прошло
    /// схему; расхождение с серверной датой — `date_skew`, тело верное, а часы
    /// нет.
    ///
    /// `skewDays` — допуск этого пути. Общий — сутки; старт сессии растяжки
    /// задаёт ноль (§20.3): сессия стартует сейчас, и вчерашняя или завтрашняя
    /// дата переносила бы её `performed_on` в чужой день стрика.
    public static func validated(date: String, tz: String, at instant: Date = Date(),
                                 skewDays: Int = maxSkewDays) throws -> RequestDay {
        // Зона разбирается первой: без неё «дата по часам сервера» не
        // существует, и сравнивать было бы не с чем. Аббревиатуры (`MSK`,
        // `PST`) идентификаторами не являются и сюда не проходят — §20.7
        // говорит именно про IANA-зону.
        // Алфавит имён IANA (§20.7): латиница, цифры, `/ _ + -`. Foundation
        // принимает `Europe/Moscow\0` за Москву и сохраняет NUL в `identifier`,
        // а падает уже запрос к базе — ответом 500. Совпадения с разобранным
        // именем не требуется: `UTC` Foundation переписывает в `GMT`, а браузер
        // в зоне UTC присылает именно `UTC`. Дальше в запросы идёт
        // `zone.identifier`, а не присланная строка.
        guard !tz.isEmpty, tz.unicodeScalars.allSatisfy(Self.zoneAlphabet.contains),
              let zone = TimeZone(identifier: tz) else {
            throw APIError(.validationFailed, details: ["field": .string("tz")])
        }
        guard let sent = Mapping.LocalTime.day(iso: date) else {
            throw APIError(.validationFailed, details: ["field": .string("date")])
        }

        let server = Mapping.LocalTime.day(of: instant, in: zone)
        let skew = sent.days(until: server)
        guard abs(skew) <= skewDays else {
            // `details` машинный и клиенту показывается только машиной:
            // обе даты и зона — то, из чего клиент может понять, чьи часы
            // сбиты, не показывая пользовательнице ни одного из этих чисел.
            throw APIError(.dateSkew, details: [
                "sent": .string(date),
                "server": .string(Mapping.LocalTime.iso(server)),
                "tz": .string(zone.identifier),
                "skew_days": .int(skew)
            ])
        }

        return RequestDay(date: sent, timeZone: zone,
                          now: Mapping.LocalTime.timestamp(of: instant, in: zone),
                          serverDate: server)
    }

    /// Пара из query — форма путей `GET` (`/v1/today?date=&tz=`, §20.3).
    ///
    /// Отсутствие параметра — то же `validation_failed`, что и его непригодная
    /// форма: для клиента это один случай («тело/запрос не прошли схему»), и
    /// §20.3 велит заводить код по различимому поведению, а не по различимой
    /// причине.
    public static func fromQuery(_ request: Request, at instant: Date = Date()) throws -> RequestDay {
        guard let date: String = request.query["date"] else {
            throw APIError(.validationFailed, details: ["field": .string("date")])
        }
        guard let tz: String = request.query["tz"] else {
            throw APIError(.validationFailed, details: ["field": .string("tz")])
        }
        return try validated(date: date, tz: tz, at: instant)
    }
}
