//  Срез `profiles` (SPEC §3.1, §20.6).
//
//  ── Почему слой разделён надвое ────────────────────────────────────────────
//
//  У каждого среза две половины: `Row` — то, что лежит в колонках, и чистая
//  функция из `Row` в типы FitCore. Пополам они разрезаны затем, чтобы вторая
//  половина проверялась без живого Postgres: правила §20.6 («флаг главнее своей
//  колонки», «только активные ограничения», «режим без фаз по умолчанию») —
//  это условия НАД значениями, а не запросы, и ошибка в них не падает и не
//  видна в ответе. Первая половина остаётся тонкой: `select`, и больше ничего.
//
//  ── Неполный профиль — тип, а не проверка ─────────────────────────────────
//
//  После миграции `0010` четыре колонки nullable, и «профиль есть» больше не
//  означает «планировщику есть с чем работать» (§20.6). Правило выражено
//  типами: `ProfileSlice` несёт то, что прочитано, а `CompleteProfile` —
//  четыре обязательных значения вместе. Роут, которому нужна генерация недели,
//  требует второй; забыть проверку он не может, потому что взять `goal` из
//  первого негде.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import FitAPI
import FitCore

// Имя модуля `FitAPI` занято одноимённым пространством имён внутри него, так что
// `FitAPI.CycleTracking` разрешается не туда. Псевдоним на файловом уровне
// снимает двусмысленность до того, как вложенное имя объявлено.
public typealias WireCycleTracking = CycleTracking

extension Mapping {

    public typealias CycleTracking = WireCycleTracking

    /// Источник данных о цикле — `profiles.cycle_tracking` (§3.1).
    ///
    /// Псевдоним, а не своё объявление: тот же словарь едет на проводе в
    /// `ProfileDTO` (§20.3), и два одинаковых enum'а в двух модулях — это два
    /// описания одного, обязанные совпадать и ничем не связанные. Живёт он в
    /// `FitAPI` по общему правилу §20.2: форму границы описывает он.
    ///
    /// НЕ режим фаз: режим живёт в `cycle_profiles.phase_mode`, и путать их
    /// нельзя — «отслеживаю вручную» и «работаю по фазам» независимы.

    /// Четыре значения, без которых планировщик не работает (§20.6).
    ///
    /// Вместе, а не по отдельности: `Planner.weekGrid` требует и даты, и
    /// уровень, а `days_per_week` без `training_weekdays` схема не допускает
    /// (`profiles_weekdays_paired`, миграция `0010`).
    public struct CompleteProfile: Sendable, Equatable {
        public var level: ExperienceLevel
        public var goal: Goal
        /// ISO-номера дней недели, 1 = понедельник, отсортированы (§3.1).
        public var trainingWeekdays: [Int]

        public init(level: ExperienceLevel, goal: Goal, trainingWeekdays: [Int]) {
            self.level = level
            self.goal = goal
            self.trainingWeekdays = trainingWeekdays
        }

        /// `days_per_week` отдельным полем не хранится: он равен длине набора
        /// дней, и схема это проверяет (`cardinality(...) = days_per_week`).
        /// Второе поле здесь означало бы возможность их рассогласовать.
        public var daysPerWeek: Int { trainingWeekdays.count }
    }

    public struct ProfileSlice: Sendable, Equatable {
        public var level: ExperienceLevel?
        public var goal: Goal?
        public var trainingWeekdays: [Int]?
        public var sessionMinutes: Int
        public var cycleTracking: CycleTracking
        public var sexAtBirth: String?

        public init(level: ExperienceLevel?, goal: Goal?, trainingWeekdays: [Int]?,
                    sessionMinutes: Int, cycleTracking: CycleTracking, sexAtBirth: String?) {
            self.level = level
            self.goal = goal
            self.trainingWeekdays = trainingWeekdays
            self.sessionMinutes = sessionMinutes
            self.cycleTracking = cycleTracking
            self.sexAtBirth = sexAtBirth
        }

        /// `nil` — профиль неполон, и `POST /v1/week-plans` обязан ответить
        /// `profile_incomplete` (§20.6). Больше нигде эта проверка не стоит:
        /// остальные пути требуют недели, а недели без генерации нет.
        public var complete: CompleteProfile? {
            guard let level, let goal, let trainingWeekdays, !trainingWeekdays.isEmpty else { return nil }
            return CompleteProfile(level: level, goal: goal, trainingWeekdays: trainingWeekdays)
        }
    }

    /// Строка `profiles` в том виде, в каком её отдаёт `select` (§3.1).
    public struct ProfileRow: Sendable, Equatable {
        public var experienceLevel: String?
        public var goal: String?
        public var trainingWeekdays: [Int]?
        public var sessionMinutes: Int
        public var cycleTracking: String
        public var sexAtBirth: String?

        public init(experienceLevel: String?, goal: String?, trainingWeekdays: [Int]?,
                    sessionMinutes: Int, cycleTracking: String, sexAtBirth: String?) {
            self.experienceLevel = experienceLevel
            self.goal = goal
            self.trainingWeekdays = trainingWeekdays
            self.sessionMinutes = sessionMinutes
            self.cycleTracking = cycleTracking
            self.sexAtBirth = sexAtBirth
        }
    }

    /// `Row` → срез.
    ///
    /// Неизвестное значение колонки — `nil`, а не отказ: колонки текстовые и
    /// без `check`, так что значение вне словаря означает рассогласование
    /// схемы с кодом, и вести себя оно обязано как незаполненное. Уронить
    /// запрос здесь значило бы сделать профиль нечитаемым целиком из-за одного
    /// поля — в том числе на `GET /v1/profile`, которым его и чинят.
    public static func profile(from row: ProfileRow) -> ProfileSlice {
        ProfileSlice(
            level: row.experienceLevel.flatMap(ExperienceLevel.init(rawValue:)),
            goal: row.goal.flatMap(Goal.init(rawValue:)),
            trainingWeekdays: row.trainingWeekdays.map { $0.sorted() },
            sessionMinutes: row.sessionMinutes,
            // `cycle_tracking` — `not null default 'off'`, поэтому неизвестное
            // значение схлопывается в `off`: источник данных, которого мы не
            // понимаем, — это отсутствие источника.
            cycleTracking: CycleTracking(rawValue: row.cycleTracking) ?? .off,
            sexAtBirth: row.sexAtBirth
        )
    }

    /// Незаполненные из четырёх обязательных — в `details` конверта §20.3.
    ///
    /// `details` машинный и клиенту нужен для одного: понять, на какой экран
    /// онбординга возвращать. Пользовательнице он не показывается никогда,
    /// поэтому имена здесь колоночные, а не человеческие.
    public static func missingProfileFields(_ slice: ProfileSlice) -> [String] {
        var missing: [String] = []
        if slice.level == nil { missing.append("experience_level") }
        if slice.goal == nil { missing.append("goal") }
        if slice.trainingWeekdays?.isEmpty ?? true { missing.append("training_weekdays") }
        return missing
    }

    /// Даты тренировочных дней недели, начинающейся в `weekStart` (§7.2).
    ///
    /// `Planner.weekGrid` принимает даты, а не номера: набор дней задаёт и типы
    /// дней, потому что сетка раздаёт их в календарном порядке. Перевод —
    /// здесь, потому что он про схему (`training_weekdays` хранит ISO-номера),
    /// а не про планирование.
    ///
    /// Дубликаты не схлопываются и не проверяются: уникальность обязана
    /// держаться схемой (`weekdays_canonical`, §3.1), а `weekGrid` схлопнет их
    /// молча — то есть ошибка здесь была бы невидима дважды.
    public static func trainingDates(weekStart: CalendarDay, weekdays: [Int]) -> [CalendarDay] {
        weekdays.map { weekStart.adding(days: $0 - 1) }
    }
}
