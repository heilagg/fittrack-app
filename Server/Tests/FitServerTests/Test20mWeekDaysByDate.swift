//  20m. Дни недели несут дату, тип и название типа (SPEC §7.2, §20.3, §20.15).
//
//  Утверждения ставятся против строк `planned_days`, прочитанных владельцем
//  базы, а не против второго ответа того же сервера: ответ, сверенный с самим
//  собой, не поймал бы ни перепутанных дат, ни чужого типа у дня.
//
//  Неделя — шесть дней: сетка §7.2 даёт на ней пять типов из шести названных
//  (жимовая, тяговая, низ тела, верх тела, растяжка), и `lower` встречается
//  дважды — то самое место, где раньше одно значение называлось двумя словами.

import Testing
import Foundation
import FitAPI
import FitCore
import PostgresNIO
import Vapor
import VaporTesting
@testable import FitServer

@Suite("20m: дни недели по датам, тип дня и его название (§20.3)", .enabled(if: Live.enabled), .serialized)
struct Test20mWeekDaysByDate {

    private let zone = "Europe/Moscow"

    private var today: CalendarDay {
        Mapping.LocalTime.day(of: Date(), in: TimeZone(identifier: "Europe/Moscow")!)
    }
    private var weekStart: CalendarDay { Mapping.LocalTime.mondayOfWeek(today) }
    /// Следующая неделя: в ней нет прошедших дней, и проверка «хотя бы один
    /// день собран» не зависит от того, в какой день недели идёт прогон. По
    /// воскресеньям все шесть дней текущей недели уже прошли, а прошедший день
    /// планировщик не собирает (§7.1). `POST` принимает ближайшую следующую
    /// неделю (§20.3).
    private var nextWeekStart: CalendarDay { weekStart.adding(days: 7) }
    private var todayISOWeekday: Int { (today.dayNumber + 3) % 7 + 1 }
    private var day: DayContext { DayContext(date: Mapping.LocalTime.iso(today), tz: zone) }
    private var query: String { "date=\(Mapping.LocalTime.iso(today))&tz=Europe%2FMoscow" }

    private func generate(_ app: Application, as user: Live.User, week: CalendarDay? = nil) async throws {
        let body = GenerateWeekPlanRequest(weekStart: Mapping.LocalTime.iso(week ?? weekStart), day: day)
        try await app.testing().test(.POST, "/v1/week-plans", headers: user.headers,
                                     beforeRequest: { try $0.content.encode(body) }) { response in
            #expect(response.status == .created, Comment(rawValue: String(buffer: response.body)))
        }
    }

    /// Строки недели, как они лежат в базе: (id, planned_date, session_kind).
    private func plannedRows(_ user: Live.User, logger: Logger) async throws -> [(String, String, String)] {
        let client = Live.ownerClient(logger)
        return try await withThrowingTaskGroup(of: [(String, String, String)]?.self) { group in
            group.addTask { await client.run(); return nil }
            group.addTask {
                let rows = try await client.query("""
                    select d.id::text, d.planned_date::text, d.session_kind
                    from planned_days d join week_plans w on w.id = d.week_plan_id
                    where w.user_id = \(user.id)
                    order by d.planned_date
                    """, logger: logger)
                var out: [(String, String, String)] = []
                for try await row in rows.decode((String, String, String).self) { out.append(row) }
                return out
            }
            var result: [(String, String, String)] = []
            for try await value in group {
                if let value { result = value; group.cancelAll(); break }
            }
            return result
        }
    }

    @Test("20m: каждый день недели — своя строка planned_days с её датой и типом, по дате")
    func weekDaysMatchTheirRows() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("20m.week")

        try await Live.withServer("20m.week") { app in
            try await Live.seed(app, user, logger: logger, weekdays: [1, 2, 3, 4, 5, 6])
            try await self.generate(app, as: user, week: self.nextWeekStart)

            var captured: WeekPlanResponseDTO?
            var raw: [[String: Any]] = []
            try await app.testing().test(
                .GET, "/v1/week-plans/\(Mapping.LocalTime.iso(self.nextWeekStart))?\(self.query)",
                headers: user.headers
            ) { response in
                #expect(response.status == .ok, Comment(rawValue: String(buffer: response.body)))
                captured = try? JSONDecoder().decode(WeekPlanResponseDTO.self, from: Data(buffer: response.body))
                let json = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                raw = ((json?["plan"] as? [String: Any])?["days"] as? [[String: Any]]) ?? []
            }
            let days = try #require(captured).plan.days
            let rows = try await self.plannedRows(user, logger: logger)

            #expect(rows.count == 6)
            #expect(days.map(\.dayID) == rows.map(\.0), "день недели — ровно своя строка, в порядке дат")
            #expect(days.map(\.date) == rows.map(\.1))
            #expect(days.map(\.sessionKind) == rows.map(\.2))
            #expect(days.map(\.date) == days.map(\.date).sorted())

            // §7.2: шесть дней — жимовая / тяговая / низ тела / верх тела / низ тела + растяжка.
            #expect(days.map(\.sessionKind) == ["push", "pull", "lower", "upper", "lower", "stretch"])
            #expect(days.map(\.sessionKindName)
                    == ["Жимовая", "Тяговая", "Низ тела", "Верх тела", "Низ тела", "Растяжка"])

            // Сессия собранного дня несёт тип своего дня, а не соседнего.
            for day in days {
                if let session = day.session {
                    #expect(session.sessionKind == day.sessionKind)
                    #expect(session.sessionKindName == day.sessionKindName)
                }
            }
            #expect(days.contains { $0.session != nil }, "хотя бы один день недели собран")

            // Форма на проводе: ключи `date`, `session_kind`, `session_kind_name` есть у каждого дня.
            #expect(raw.count == 6)
            for day in raw {
                #expect(day["date"] is String)
                #expect(day["session_kind"] is String)
                #expect(day["session_kind_name"] is String)
                #expect(day["day_id"] is String)
            }
        }
    }

    @Test("20m: сессия /today несёт тип своего дня и его название, а даты в дне нет")
    func todaySessionCarriesItsType() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("20m.today")

        try await Live.withServer("20m.today") { app in
            // Три дня со вчерашним и завтрашним, когда они в этой неделе: сетка
            // §7.2 даёт среднему уровню верх тела / низ тела / всё тело, и у
            // сегодняшнего тип свой, а не первого или последнего дня недели.
            let t = self.todayISOWeekday
            let weekdays = t == 1 ? [1, 2, 3] : t == 7 ? [5, 6, 7] : [t - 1, t, t + 1]
            let expected: (String, String) = [("upper", "Верх тела"), ("lower", "Низ тела"),
                                              ("full_body", "Всё тело")][weekdays.firstIndex(of: t)!]
            try await Live.seed(app, user, logger: logger, weekdays: weekdays)
            try await self.generate(app, as: user)

            var card: TodayCardDTO?
            var rawDay: [String: Any]?
            try await app.testing().test(.GET, "/v1/today?\(self.query)", headers: user.headers) { response in
                #expect(response.status == .ok, Comment(rawValue: String(buffer: response.body)))
                card = try? JSONDecoder().decode(TodayCardDTO.self, from: Data(buffer: response.body))
                let json = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
                rawDay = json?["day"] as? [String: Any]
            }
            let session = try #require(card?.day.session)
            #expect(session.sessionKind == expected.0)
            #expect(session.sessionKindName == expected.1)
            #expect(rawDay?["date"] == nil, "TodayCard не меняется: дата — в card.date (§20.3)")
        }
    }
}
