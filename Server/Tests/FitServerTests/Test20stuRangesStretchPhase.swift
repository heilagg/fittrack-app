//  20s, 20t, 20u (SPEC §3.1, §3.2, §11.2, §20.3, §20.15).
//
//    20s. Профиль: поле вне диапазона — 422 с полем, строка не меняется; check'и
//         схемы отклоняют то же при прямой записи; веса инвентаря и вес тела
//         вне диапазона отклоняет база (таблицы пишет фронтенд напрямую).
//    20t. `stretch_sessions`: владелица через REST Supabase читает, но не пишет;
//         старт сессии со вчерашней или завтрашней датой — `date_skew`.
//    20u. Причина фазы — по знаку эффективной поправки; при нулевой её нет.
//         Без базы: правило живёт в FitCore и FitAPI, а сервер кладёт в
//         ответ то, что они дали.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import FitAPI
import FitCore
import PostgresNIO
import Vapor
import VaporTesting
@testable import FitServer

@Suite("20s/20t: диапазоны профиля и запись stretch_sessions (§20.15)", .enabled(if: Live.enabled), .serialized)
struct Test20stRangesAndStretchWrites {

    private func patch(_ app: Application, _ user: Live.User, json: String) async throws -> (Int, Data) {
        var captured: (Int, Data) = (0, Data())
        try await app.testing().test(.PATCH, "/v1/profile", headers: user.headers, beforeRequest: { request in
            request.headers.contentType = .json
            request.body = ByteBuffer(string: json)
        }) { response in
            captured = (Int(response.status.code), Data(buffer: response.body))
        }
        return captured
    }

    private func profileRow(_ database: Database, _ user: Live.User) async throws -> String {
        try await database.withUserTransaction(authorization: "Bearer \(user.token)") { tx in
            for try await row in try await tx.query("""
                select concat_ws('|', sex_at_birth, birth_year, height_cm, session_minutes) from profiles
                """) {
                return try row.decode(String.self)
            }
            return ""
        }
    }

    /// Владельцем базы, мимо сервера: check — последняя линия, и проверяется он сам.
    private func ownerExpectsCheckViolation(_ sql: String, logger: Logger) async throws {
        let client = Live.ownerClient(logger)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            group.addTask {
                do {
                    _ = try await client.query(PostgresQuery(unsafeSQL: sql), logger: logger)
                    Issue.record("записано мимо check: \(sql)")
                } catch let error as PSQLError {
                    #expect(error.serverInfo?[.sqlState] == "23514", "\(sql): \(String(reflecting: error))")
                }
            }
            try await group.next()
            group.cancelAll()
        }
    }

    @Test("20s: поле профиля вне диапазона — 422 с полем, строка не меняется")
    func profileRanges() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("20s.profile")
        try await Live.withServer("20s.profile") { app, database in
            try await Live.seed(app, user, logger: logger)
            let before = try await self.profileRow(database, user)
            let year = ProfileRoutes.currentYear(Date())
            let cases: [(String, String)] = [
                (#"{"sex_at_birth":"xyz"}"#, "sex_at_birth"),
                (#"{"birth_year":1935}"#, "birth_year"),
                ("{\"birth_year\":\(year - 13)}", "birth_year"),
                (#"{"height_cm":99.9}"#, "height_cm"),
                (#"{"height_cm":250.5}"#, "height_cm"),
                (#"{"session_minutes":9}"#, "session_minutes"),
                (#"{"session_minutes":181}"#, "session_minutes"),
            ]
            for (json, field) in cases {
                let (status, raw) = try await self.patch(app, user, json: json)
                #expect(status == 422, "\(json): \(String(decoding: raw, as: UTF8.self))")
                let body = try JSONDecoder().decode(APIErrorEnvelope.self, from: raw)
                #expect(body.error.details?["field"] == .string(field), "\(json)")
            }
            #expect(try await self.profileRow(database, user) == before, "отказ ничего не записал")

            // Границы включены.
            for json in ["{\"birth_year\":\(year - 14)}", #"{"birth_year":1936}"#, #"{"height_cm":100}"#,
                         #"{"height_cm":250}"#, #"{"session_minutes":10}"#, #"{"session_minutes":180}"#,
                         #"{"sex_at_birth":"undisclosed"}"#] {
                let (status, raw) = try await self.patch(app, user, json: json)
                #expect(status == 200, "\(json): \(String(decoding: raw, as: UTF8.self))")
            }
        }
    }

    @Test("20s: check'и схемы отклоняют профиль, инвентарь и вес тела вне диапазона")
    func schemaChecks() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("20s.checks")
        try await Live.withServer("20s.checks") { app in
            try await Live.seed(app, user, logger: logger)
            let id = user.id.uuidString.lowercased()
            for set in ["sex_at_birth = 'xyz'", "birth_year = 1900", "height_cm = 10", "session_minutes = 600"] {
                try await self.ownerExpectsCheckViolation("update profiles set \(set) where id = '\(id)'", logger: logger)
            }
            for set in ["dumbbells_kg = '{0,4}'", "plates_kg = '{501}'", "kettlebells_kg = '{-1}'",
                        "barbell_kg = 0", "machine_step_kg = 0", "machine_step_kg = 501"] {
                try await self.ownerExpectsCheckViolation(
                    "update equipment_profiles set \(set) where user_id = '\(id)'", logger: logger)
            }
            for kg in ["19.9", "300.5"] {
                try await self.ownerExpectsCheckViolation("""
                    insert into body_weight_entries (id, user_id, weight_kg, measured_on)
                    values (gen_random_uuid(), '\(id)', \(kg), current_date)
                    """, logger: logger)
            }
        }
    }

    /// Запрос к REST Supabase с токеном пользовательницы — путь браузера, а не сервера.
    private func rest(_ method: String, _ path: String, _ user: Live.User, body: String? = nil) async throws -> Int {
        let base = Live.issuer!.replacingOccurrences(of: "/auth/v1", with: "/rest/v1")
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = method
        request.setValue(Live.anonKey!, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(user.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = body.map { Data($0.utf8) }
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    private func start(_ app: Application, _ user: Live.User, id: String, day: DayContext) async throws -> (Int, Data) {
        var captured: (Int, Data) = (0, Data())
        let body = StartStretchSessionRequest(id: id, kind: "standalone", templateSlug: "hip_opening", day: day)
        try await app.testing().test(.POST, "/v1/stretch-sessions", headers: user.headers,
                                     beforeRequest: { try $0.content.encode(body) }) { response in
            captured = (Int(response.status.code), Data(buffer: response.body))
        }
        return captured
    }

    @Test("20t: владелица читает stretch_sessions через REST, а insert и update ей запрещены")
    func stretchSessionsAreReadOnlyOverREST() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("20t.rest")
        try await Live.withServer("20t.rest") { app, database in
            try await Live.seed(app, user, logger: logger)
            let id = UUID().uuidString.lowercased()
            let (started, raw) = try await self.start(app, user, id: id, day: Live.today)
            #expect(started == 201, Comment(rawValue: String(decoding: raw, as: UTF8.self)))

            #expect(try await self.rest("GET", "/stretch_sessions?select=id", user) == 200)
            let forged = """
                {"id":"\(UUID().uuidString.lowercased())","user_id":"\(user.id.uuidString.lowercased())",
                 "kind":"standalone","template_slug":"hip_opening","performed_on":"2099-12-31",
                 "started_at":"2020-01-01T00:00:00Z","finished_at":"2026-10-20T00:00:00Z"}
                """
            let insert = try await self.rest("POST", "/stretch_sessions", user, body: forged)
            #expect([401, 403].contains(insert), "insert через REST: \(insert)")
            _ = try await self.rest("PATCH", "/stretch_sessions?id=eq.\(id)", user,
                                    body: #"{"performed_on":"2099-12-31"}"#)
            _ = try await self.rest("DELETE", "/stretch_sessions?id=eq.\(id)", user)

            // Строка сервера на месте и не изменилась, поддельной нет.
            let rows = try await database.withUserTransaction(authorization: "Bearer \(user.token)") { tx in
                var out: [String] = []
                for try await row in try await tx.query(
                    "select id::text || '|' || performed_on::text from stretch_sessions") {
                    out.append(try row.decode(String.self))
                }
                return out
            }
            #expect(rows == ["\(id)|\(Live.today.date)"])
        }
    }

    @Test("20t: старт сессии со вчерашней или завтрашней датой — date_skew; сегодняшней — 201")
    func stretchStartHasNoSkew() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("20t.date")
        try await Live.withServer("20t.date") { app in
            try await Live.seed(app, user, logger: logger)
            let today = try #require(Mapping.LocalTime.day(iso: Live.today.date))
            for shift in [-1, 1] {
                let day = DayContext(date: Mapping.LocalTime.iso(today.adding(days: shift)), tz: Live.today.tz)
                let (status, raw) = try await self.start(app, user, id: UUID().uuidString, day: day)
                #expect(status == 422, "\(shift): \(String(decoding: raw, as: UTF8.self))")
                #expect(try JSONDecoder().decode(APIErrorEnvelope.self, from: raw).error.code == .dateSkew)
            }
            let (ok, raw) = try await self.start(app, user, id: UUID().uuidString, day: Live.today)
            #expect(ok == 201, Comment(rawValue: String(decoding: raw, as: UTF8.self)))
        }
    }
}

@Suite("20u: причина фазы по знаку поправки (§11.2)")
struct Test20uPhaseReason {

    @Test("20u: причина есть ровно при ненулевой поправке, и текст — по её знаку")
    func reasonFollowsTheSign() {
        for phase in Phase.allCases {
            for step in 0...20 {
                let confidence = Double(step) / 20
                let periodization = Cycle.periodization(phase: phase, cycleConfidence: confidence)
                let direction = Cycle.adjustmentDirection(phase: phase, cycleConfidence: confidence)
                let neutral = periodization.volumeMultiplier == 1.0 && periodization.rirShift == 0
                #expect((periodization.reason == nil) == neutral, "\(phase) \(confidence)")
                guard let reason = periodization.reason else { continue }
                let dto = ReasonDTO(reason)
                #expect(ReasonDTO.code(for: reason) == "phase_periodization")
                switch direction {
                case .lighter: #expect(dto.message.contains("чуть легче"), "\(phase) \(confidence): \(dto.message)")
                case .heavier: #expect(dto.message.contains("больше нагрузки"), "\(phase) \(confidence): \(dto.message)")
                case nil: Issue.record("причина без знака: \(phase) \(confidence)")
                }
            }
        }
    }
}
