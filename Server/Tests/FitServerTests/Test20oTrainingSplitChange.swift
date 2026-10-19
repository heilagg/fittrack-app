//  20o. Смена схемы тренировок (SPEC §7.1, §7.2, §20.15).
//
//  Схема ведёт себя как смена дней недели: уже сгенерированная текущая неделя
//  не трогается, новая схема действует со следующей генерации. Утверждения —
//  против строк `planned_days` и `week_plans.input_digest`, прочитанных
//  владельцем базы, а не против второго ответа того же сервера: ответ, сверенный
//  с самим собой, не поймал бы переписанной задним числом недели.
//
//  Четыре дня выбраны потому, что на них три схемы дают три разные сетки:
//  «Авто» — верх / низ / верх / низ, «Пуш пулл ноги» — жимовая / тяговая /
//  низ тела / всё тело. Совпади они, тест не отличил бы схему от её отсутствия.

import Testing
import Foundation
import FitAPI
import FitCore
import PostgresNIO
import Vapor
import VaporTesting
@testable import FitServer

@Suite("20o: смена training_split — со следующей генерации (§7.1)", .enabled(if: Live.enabled), .serialized)
struct Test20oTrainingSplitChange {

    private let zone = "Europe/Moscow"

    private var today: CalendarDay {
        Mapping.LocalTime.day(of: Date(), in: TimeZone(identifier: "Europe/Moscow")!)
    }
    private var thisWeek: CalendarDay { Mapping.LocalTime.mondayOfWeek(today) }
    private var nextWeek: CalendarDay { thisWeek.adding(days: 7) }
    private var day: DayContext { DayContext(date: Mapping.LocalTime.iso(today), tz: zone) }

    private func generate(_ app: Application, as user: Live.User, week: CalendarDay) async throws -> (Int, String) {
        let body = GenerateWeekPlanRequest(weekStart: Mapping.LocalTime.iso(week), day: day)
        var captured: (Int, String) = (0, "")
        try await app.testing().test(.POST, "/v1/week-plans", headers: user.headers,
                                     beforeRequest: { try $0.content.encode(body) }) { response in
            captured = (Int(response.status.code), String(buffer: response.body))
        }
        return captured
    }

    /// Строки одной недели, как они лежат в базе: (id, planned_date, session_kind).
    private func plannedRows(_ user: Live.User, week: CalendarDay,
                             logger: Logger) async throws -> [(String, String, String)] {
        try await owner(logger) { client in
            let rows = try await client.query("""
                select d.id::text, d.planned_date::text, d.session_kind
                from planned_days d join week_plans w on w.id = d.week_plan_id
                where w.user_id = \(user.id) and w.week_start = \(Mapping.LocalTime.iso(week))::date
                order by d.planned_date
                """, logger: logger)
            var out: [(String, String, String)] = []
            for try await row in rows.decode((String, String, String).self) { out.append(row) }
            return out
        }
    }

    private func digest(_ user: Live.User, week: CalendarDay, logger: Logger) async throws -> [String: Any] {
        let text: String = try await owner(logger) { client in
            let rows = try await client.query("""
                select input_digest::text from week_plans
                where user_id = \(user.id) and week_start = \(Mapping.LocalTime.iso(week))::date
                """, logger: logger)
            for try await row in rows.decode(String.self) { return row }
            return "{}"
        }
        return (try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
    }

    private func owner<T: Sendable>(_ logger: Logger,
                                    _ body: @escaping @Sendable (PostgresClient) async throws -> T) async throws -> T {
        let client = Live.ownerClient(logger)
        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { await client.run(); return nil }
            group.addTask { try await body(client) }
            var result: T?
            for try await value in group {
                if let value { result = value; group.cancelAll(); break }
            }
            return try #require(result)
        }
    }

    @Test("20o: текущая неделя не тронута, следующая — по новой схеме")
    func splitChangeAppliesFromNextGeneration() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("20o.split")

        try await Live.withServer("20o.split") { app in
            try await Live.seed(app, user, logger: logger, weekdays: [1, 2, 4, 5])
            let first = try await self.generate(app, as: user, week: self.thisWeek)
            #expect(first.0 == 201, Comment(rawValue: first.1))
            let before = try await self.plannedRows(user, week: self.thisWeek, logger: logger)
            #expect(before.map(\.2) == ["upper", "lower", "upper", "lower"], "«Авто», 4 дня (§7.2)")
            #expect(try await self.digest(user, week: self.thisWeek, logger: logger)["training_split"] as? String
                    == "auto")

            // Смена схемы — через существующий путь записи профиля.
            var patched: ProfileDTO?
            try await app.testing().test(.PATCH, "/v1/profile", headers: user.headers, beforeRequest: {
                try $0.content.encode(PatchProfileRequest(trainingSplit: .pushPullLegs))
            }) { response in
                #expect(response.status == .ok, Comment(rawValue: String(buffer: response.body)))
                patched = try? JSONDecoder().decode(ProfileDTO.self, from: Data(buffer: response.body))
            }
            #expect(patched?.trainingSplit == .pushPullLegs)
            #expect(patched?.trainingWeekdays == [1, 2, 4, 5], "остальные поля не тронуты")

            // Текущая неделя — те же строки с теми же типами (§7.1).
            let after = try await self.plannedRows(user, week: self.thisWeek, logger: logger)
            #expect(after.map(\.0) == before.map(\.0))
            #expect(after.map(\.2) == before.map(\.2))
            // Повтор генерации на неё — `week_exists`, как после смены дней:
            // сетка профиля теперь другая, а перекраивать неделю §7.1 запрещает.
            let repeatOnThisWeek = try await self.generate(app, as: user, week: self.thisWeek)
            #expect(repeatOnThisWeek.0 == 409)
            #expect(repeatOnThisWeek.1.contains("week_exists"))
            #expect(try await self.plannedRows(user, week: self.thisWeek, logger: logger).map(\.0) == before.map(\.0))

            // Следующая неделя — по новой схеме, и снимок входа её называет.
            let next = try await self.generate(app, as: user, week: self.nextWeek)
            #expect(next.0 == 201, Comment(rawValue: next.1))
            let nextRows = try await self.plannedRows(user, week: self.nextWeek, logger: logger)
            #expect(nextRows.map(\.2) == ["push", "pull", "lower", "full_body"], "«Пуш пулл ноги», 4 дня (§7.2)")
            let digest = try await self.digest(user, week: self.nextWeek, logger: logger)
            #expect(digest["training_split"] as? String == "push_pull_legs")
            #expect(digest["v"] as? Int == 2)
        }
    }

    @Test("20o: значение вне словаря — validation_failed, профиль не тронут")
    func unknownSplitIsRejected() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("20o.unknown")

        try await Live.withServer("20o.unknown") { app in
            try await Live.seed(app, user, logger: logger, weekdays: [1, 3, 5])
            try await app.testing().test(.PATCH, "/v1/profile", headers: user.headers, beforeRequest: {
                try $0.content.encode(["training_split": "bro_split"])
            }) { response in
                #expect(response.status == .unprocessableEntity, Comment(rawValue: String(buffer: response.body)))
                #expect(String(buffer: response.body).contains("validation_failed"))
            }
            try await app.testing().test(.GET, "/v1/profile", headers: user.headers) { response in
                let profile = try? JSONDecoder().decode(ProfileDTO.self, from: Data(buffer: response.body))
                #expect(profile?.trainingSplit == .auto)
            }
        }
    }
}
