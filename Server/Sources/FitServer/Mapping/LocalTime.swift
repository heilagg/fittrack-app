//  Шкала FitCore против настоящих моментов времени (SPEC §20.7).
//
//  Контракт ядра: `CalendarDay` и `Timestamp` отсчитываются от одной эпохи
//  (1970-01-01 = день 0) В МЕСТНОМ времени, то есть полночь дня `d` — это
//  `d × 24` часа, а момент оценки дня — `d × 24 + 12`
//  (`Planner.evaluationMoment`). Сервер живёт в UTC, пользовательница — нет.
//
//  Отсюда единственная операция этого файла: настоящий момент + IANA-зона →
//  местные секунды от эпохи, а из них уже день и `Timestamp`. Делается она ОДИН
//  РАЗ, при записи, в зоне присланного запроса, и не повторяется при чтении.
//  Цена повторения замерена в §20.7: утомление, посчитанное на 22:00 по
//  московскому времени и прочитанное в нью-йоркской зоне, даёт до момента
//  оценки не 14 часов, а 21 — около 21% по мышце с полураспадом 20 ч, а пороги
//  §8.2 стоят на 0.8 и 1.8. Ошибка не падает и не видна в ответе (тест 20i).
//
//  ── Почему без `Calendar` ──────────────────────────────────────────────────
//
//  Нужна ровно одна величина — смещение зоны в конкретный момент, и её отдаёт
//  `TimeZone.secondsFromGMT(for:)`. Дальше арифметика целочисленная и совпадает
//  с контрактом ядра буквально, тогда как `Calendar` вводит второй календарь
//  рядом с проленптическим григорианским из `CalendarDay` — и расхождение этих
//  двух было бы видно только сдвинутым на сутки днём тренировки.
//
//  Перевод дня обратно в (год, месяц, день) — алгоритм Хауарда Хиннанта
//  (`civil_from_days`), то есть та же пара, что уже стоит в
//  `CalendarDay(year:month:day:)`. Второй реализации календаря не заводится.
//
//  ── Что сюда НЕ входит ─────────────────────────────────────────────────────
//
//  Переход на летнее время — принятая погрешность (§20.7): сдвиг на час внутри
//  одной зоны меняет разность меток на час, и на полураспаде 20–40 ч это
//  единицы процентов. Точный учёт потребовал бы хранить зону у каждой строки —
//  колонку, от которой §20.7 отказался сознательно.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import FitCore

extension Mapping {

    /// Перевод между настоящими моментами и шкалой FitCore (§20.7).
    public enum LocalTime {

        // MARK: - Момент → шкала

        /// Секунды от эпохи по настенным часам зоны `zone`.
        ///
        /// Основа обоих преобразований ниже: смещение берётся НА ЭТОТ момент,
        /// а не постоянное для зоны, иначе летнее время сдвигало бы результат
        /// на час в одну сторону полгода.
        public static func localSeconds(of instant: Date, in zone: TimeZone) -> Double {
            instant.timeIntervalSince1970 + Double(zone.secondsFromGMT(for: instant))
        }

        /// День шкалы FitCore, в котором находится `instant` по часам зоны.
        ///
        /// Округление вниз, а не усечение: до 1970 года секунды отрицательны, и
        /// усечение к нулю положило бы 31 декабря 1969-го в день 0 вместе с
        /// 1 января 1970-го. Дат до эпохи у продукта не бывает, но правило
        /// «день — это пол от деления» обязано выполняться без оговорок:
        /// оговорка здесь невидима, а ошибка в сутки включает ступень
        /// детренированности §9.7 не тогда.
        public static func day(of instant: Date, in zone: TimeZone) -> CalendarDay {
            CalendarDay(dayNumber: Int((localSeconds(of: instant, in: zone) / 86_400).rounded(.down)))
        }

        /// Момент шкалы FitCore (часы от эпохи по часам зоны).
        public static func timestamp(of instant: Date, in zone: TimeZone) -> Timestamp {
            Timestamp(hoursSinceEpoch: localSeconds(of: instant, in: zone) / 3_600)
        }

        // MARK: - ISO-дата ↔ день шкалы

        /// Разбор `yyyy-mm-dd` — формы, в которой день приезжает и в теле
        /// запроса (§20.3), и из колонки `date` (§3.1).
        ///
        /// Строгий: ровно `4-2-2` цифры с двумя дефисами. Мягкий разбор принял
        /// бы `2026-9-3` и `2026-09-03T00:00:00Z`, то есть завёл бы два
        /// написания одного дня в границе, версия которой обещана неизменной
        /// (§20.3).
        ///
        /// `nil` — не разобралось. Несуществующая дата (`2026-02-31`)
        /// отсеивается проверкой обратного перевода, а не таблицей длин
        /// месяцев: високосный год у второй реализации — классическое место
        /// разойтись с первой.
        public static func day(iso: String) -> CalendarDay? {
            let parts = iso.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 3,
                  parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
                  parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
                  let year = Int(parts[0]), let month = Int(parts[1]), let dayOfMonth = Int(parts[2]),
                  (1...12).contains(month), (1...31).contains(dayOfMonth)
            else { return nil }

            let day = CalendarDay(year: year, month: month, day: dayOfMonth)
            let back = civil(from: day)
            guard back.year == year, back.month == month, back.day == dayOfMonth else { return nil }
            return day
        }

        /// Запись дня в `yyyy-mm-dd`. Используется и в ответах, и в `details`
        /// конверта ошибки (§20.3).
        public static func iso(_ day: CalendarDay) -> String {
            let civil = civil(from: day)
            return "\(padded(civil.year, 4))-\(padded(civil.month, 2))-\(padded(civil.day, 2))"
        }

        /// Ведущие нули без `String(format:)`: она живёт в полной Foundation,
        /// которой на Linux в `FoundationEssentials` нет, а пакет существует
        /// ради Linux (та же причина, по которой `AuthConfiguration` срезает
        /// пробелы руками).
        private static func padded(_ value: Int, _ width: Int) -> String {
            let digits = String(value.magnitude)
            let zeros = String(repeating: "0", count: max(0, width - digits.count))
            return (value < 0 ? "-" : "") + zeros + digits
        }

        /// Обратная к `CalendarDay(year:month:day:)` — `civil_from_days`
        /// Хиннанта. Проленптический григорианский календарь, целочисленно, без
        /// обращения к системному календарю.
        ///
        /// http://howardhinnant.github.io/date_algorithms.html
        public static func civil(from day: CalendarDay) -> (year: Int, month: Int, day: Int) {
            let z = day.dayNumber + 719_468
            let era = (z >= 0 ? z : z - 146_096) / 146_097
            let dayOfEra = z - era * 146_097                                          // [0, 146096]
            let yearOfEra =
                (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365  // [0, 399]
            let year = yearOfEra + era * 400
            let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)    // [0, 365]
            let monthIndex = (5 * dayOfYear + 2) / 153                                // [0, 11]
            let dayOfMonth = dayOfYear - (153 * monthIndex + 2) / 5 + 1               // [1, 31]
            let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9             // [1, 12]
            return (month <= 2 ? year + 1 : year, month, dayOfMonth)
        }
    }
}
