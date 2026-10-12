//  Тест 20n (§20.15): календарь цикла `GET /v1/cycle/calendar` (§11.6, §20.3).
//
//  Сетка — второй путь к тому же состоянию цикла, что у карточки дня, и
//  расхождение двух путей молчаливо: карточка и календарь назовут разные фазы,
//  и ни один ответ не будет похож на ошибку. Поэтому главное утверждение —
//  совпадение сегодняшнего дня с `/today`; остальное — порог, режим без фаз,
//  окно и то, что путь ничего не пишет.
//
//  События пишутся прямым SQL, как их пишет фронтенд (§20.6): пути к
//  `cycle_events` нет.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Testing
import FitAPI
import FitCore
import Logging
import Vapor
import VaporTesting
@testable import FitServer

@Suite("20n: календарь цикла (§11.6, §20.3)", .enabled(if: Live.enabled), .serialized)
struct Test20nCycleCalendar {

    private var today: CalendarDay {
        Mapping.LocalTime.day(of: Date(), in: TimeZone(identifier: "Europe/Moscow")!)
    }
    private var dayQuery: String { "date=\(Mapping.LocalTime.iso(today))&tz=Europe%2FMoscow" }
    private func iso(_ offset: Int) -> String { Mapping.LocalTime.iso(today.adding(days: offset)) }

    // MARK: Посев

    private func seed(_ app: Application, _ user: Live.User, tracking: CycleTracking,
                      cycle: CycleProfileDTO?, logger: Logger) async throws {
        let body = PatchProfileRequest(
            sexAtBirth: .some("female"), birthYear: .some(1994), heightCm: .some(168),
            experienceLevel: .some(.intermediate), goal: .some(.hypertrophy),
            trainingWeekdays: .some([1, 3, 5]), sessionMinutes: 60,
            cycleTracking: tracking, cycle: cycle)
        try await app.testing().test(.PATCH, "/v1/profile", headers: user.headers,
                                     beforeRequest: { try $0.content.encode(body) }) { response in
            guard response.status == .ok else {
                throw Live.Failure.seed("PATCH /v1/profile → \(response.status.code)")
            }
        }
        try await Live.seedClientOwnedTables(user, logger: logger)
    }

    private func insertStarts(_ user: Live.User, offsets: [Int], logger: Logger) async throws {
        let client = Live.ownerClient(logger)
        let base = today
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            group.addTask {
                for offset in offsets {
                    let date = Mapping.LocalTime.iso(base.adding(days: offset))
                    _ = try await client.query("""
                        insert into cycle_events (id, user_id, kind, occurred_on)
                        values (\(UUID()), \(user.id), 'period_start', \(date)::date)
                        """, logger: logger)
                }
            }
            try await group.next()
            group.cancelAll()
        }
    }

    struct Row: Sendable, Equatable {
        var mode: String
        var reason: String?
        var streak: Int
        var through: String?
        var updatedAt: String
        var syncSeq: Int64
    }

    private func row(_ user: Live.User, logger: Logger) async throws -> Row? {
        enum Outcome: Sendable { case pool, result(Row?) }
        let client = Live.ownerClient(logger)
        return try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask { await client.run(); return .pool }
            group.addTask {
                let rows = try await client.query("""
                    select phase_mode, no_phase_reason, low_confidence_streak,
                           to_char(low_confidence_counted_through, 'YYYY-MM-DD'), updated_at::text,
                           sync_seq
                      from cycle_profiles where user_id = \(user.id)
                    """, logger: logger)
                for try await r in rows {
                    let (mode, reason, streak, through, updated, seq) =
                        try r.decode((String, String?, Int, String?, String, Int64).self)
                    return .result(Row(mode: mode, reason: reason, streak: streak,
                                       through: through, updatedAt: updated, syncSeq: seq))
                }
                return .result(nil)
            }
            var found: Row?
            for try await outcome in group {
                if case .result(let value) = outcome { found = value; break }
            }
            group.cancelAll()
            return found
        }
    }

    // MARK: Запросы

    private func get(_ app: Application, _ path: String, _ user: Live.User) async throws -> (Int, Data) {
        var captured: (Int, Data) = (0, Data())
        try await app.testing().test(.GET, path, headers: user.headers) {
            captured = (Int($0.status.code), Data(buffer: $0.body))
        }
        return captured
    }

    private func calendar(_ app: Application, _ user: Live.User, from: Int, to: Int) async throws -> CycleCalendarDTO {
        let (status, raw) = try await get(
            app, "/v1/cycle/calendar?\(dayQuery)&from=\(iso(from))&to=\(iso(to))", user)
        #expect(status == 200, "\(String(decoding: raw, as: UTF8.self))")
        return try JSONDecoder().decode(CycleCalendarDTO.self, from: raw)
    }

    private func card(_ app: Application, _ user: Live.User) async throws -> TodayCardDTO {
        let (status, raw) = try await get(app, "/v1/today?\(dayQuery)", user)
        #expect(status == 200)
        return try JSONDecoder().decode(TodayCardDTO.self, from: raw)
    }

    private func writingRequest(_ app: Application, _ user: Live.User) async throws {
        let monday = Mapping.LocalTime.mondayOfWeek(today)
        let body = GenerateWeekPlanRequest(weekStart: Mapping.LocalTime.iso(monday),
                                           day: DayContext(date: Mapping.LocalTime.iso(today), tz: "Europe/Moscow"))
        try await app.testing().test(.POST, "/v1/week-plans", headers: user.headers,
                                     beforeRequest: { try $0.content.encode(body) }) { response in
            guard response.status == .created || response.status == .ok else {
                throw Live.Failure.seed("POST /v1/week-plans → \(response.status.code)")
            }
        }
    }

    /// Свёртка пяти значений карточки в четыре календаря (§11.6) — для
    /// сравнения двух путей, а не для показа.
    private func folded(_ phase: String?) -> String? {
        switch phase {
        case "early_luteal", "late_luteal": return "luteal"
        default: return phase
        }
    }

    // MARK: Тесты

    @Test("20n: сегодня в календаре — та же фаза и уверенность, что на /today")
    func test20n_todayMatchesTheDayCard() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("t20n.match")
        try await Live.withServer("t20n.match") { app in
            try await self.seed(app, user, tracking: .manual,
                                cycle: CycleProfileDTO(declaredRegularity: .regular, phaseMode: .phases),
                                logger: logger)
            // Три ровных цикла по 28, текущий начался 10 дней назад.
            try await self.insertStarts(user, offsets: [-94, -66, -38, -10], logger: logger)

            let card = try await self.card(app, user)
            let grid = try await self.calendar(app, user, from: -12, to: 25)
            #expect(grid.cycle == card.cycle, "состояние цикла — то же, что у карточки")
            let todayEntry = try #require(grid.days.first { $0.date == self.iso(0) })
            #expect(card.cycle.phase != nil, "уверенность выше порога — фаза названа")
            #expect(todayEntry.phase == self.folded(card.cycle.phase))
            #expect(todayEntry.cycleConfidence == card.cycle.cycleConfidence)

            let next = try #require(grid.nextPeriod)
            #expect(next.expected == self.iso(18))
            #expect(next.rangeStart == self.iso(16) && next.rangeEnd == self.iso(20))
            #expect(grid.days.filter(\.ovulationEstimate).map(\.date) == [self.iso(4)],
                    "оценка овуляции — за 14 дней до ожидаемого начала")
            #expect(grid.days.first { $0.date == self.iso(-10) }?.period == "marked")
            #expect(grid.days.first { $0.date == self.iso(18) }?.period == "forecast")
            #expect(grid.days.first { $0.date == self.iso(18) }?.phase == nil)
            #expect(grid.days.count == 38)
            #expect(grid.phases.count == 4)
            #expect(!grid.overdue)
        }
    }

    @Test("20n: ниже порога 0.3 фаза не отдаётся ни в cycle, ни в днях")
    func test20n_belowThresholdNoPhase() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("t20n.threshold")
        try await Live.withServer("t20n.threshold") { app in
            try await self.seed(app, user, tracking: .manual,
                                cycle: CycleProfileDTO(declaredRegularity: .irregular, phaseMode: .phases),
                                logger: logger)
            try await self.insertStarts(user, offsets: [-5], logger: logger) // 0.3 × 0.4 = 0.12
            let grid = try await self.calendar(app, user, from: -5, to: 20)
            #expect(grid.cycle.phase == nil)
            #expect(grid.days.allSatisfy { $0.phase == nil && $0.cycleConfidence == nil && !$0.ovulationEstimate })
            #expect(grid.nextPeriod != nil, "прогноз с уверенностью есть и ниже порога")
        }
    }

    @Test("20n: путь ничего не пишет — cycle_profiles и её sync_seq те же; пишущий путь сохраняет")
    func test20n_writesNothing() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("t20n.nowrite")
        try await Live.withServer("t20n.nowrite") { app in
            // Три закрытия с низкой уверенностью — применение двигает счётчик
            // и режим (как в 17): без этого «не пишет» было бы пустым.
            try await self.seed(app, user, tracking: .manual,
                                cycle: CycleProfileDTO(declaredRegularity: .irregular, phaseMode: .phases),
                                logger: logger)
            try await self.insertStarts(user, offsets: [-100, -80, -35, -15], logger: logger)
            let before = try #require(try await self.row(user, logger: logger))
            #expect(before.streak == 0)

            let grid = try await self.calendar(app, user, from: -20, to: 10)
            #expect(grid.cycle.noPhaseReason == "low_confidence", "календарь видит применённый режим")
            #expect(try await self.row(user, logger: logger) == before, "календарь не пишет")

            try await self.writingRequest(app, user)
            #expect(try await self.row(user, logger: logger)?.streak == 3, "контроль: пишущий путь сохраняет")
        }
    }

    @Test("20n: режим без фаз — отметки есть, прогноза и фаз нет")
    func test20n_noPhases() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("t20n.nophases")
        try await Live.withServer("t20n.nophases") { app in
            try await self.seed(app, user, tracking: .off, cycle: nil, logger: logger)
            try await self.insertStarts(user, offsets: [-3], logger: logger)
            let grid = try await self.calendar(app, user, from: -5, to: 5)
            #expect(grid.cycle.phaseMode == "no_phases")
            #expect(grid.nextPeriod == nil)
            #expect(!grid.overdue)
            #expect(grid.days.allSatisfy { $0.phase == nil && $0.period != "forecast" })
            let marked = try #require(grid.days.first { $0.date == self.iso(-3) })
            #expect(marked.marks.map(\.kind) == ["period_start"])
            #expect(marked.marks.first.flatMap { UUID(uuidString: $0.id) } != nil, "id строки — для правки")
            #expect(marked.period == "marked")
        }
    }

    @Test("20n: окно — from ≤ to, не больше 93 дней, обе даты обязательны")
    func test20n_window() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("t20n.window")
        try await Live.withServer("t20n.window") { app in
            try await self.seed(app, user, tracking: .off, cycle: nil, logger: logger)
            func status(_ query: String) async throws -> (Int, String?) {
                let (code, raw) = try await self.get(app, "/v1/cycle/calendar?\(self.dayQuery)\(query)", user)
                let field = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: raw))
                    .flatMap { envelope -> String? in
                        if case .string(let value)? = envelope.error.details?["field"] { return value }
                        return nil
                    }
                return (code, field)
            }
            #expect(try await status("&to=\(self.iso(0))") == (422, "from"))
            #expect(try await status("&from=\(self.iso(0))") == (422, "to"))
            #expect(try await status("&from=\(self.iso(1))&to=\(self.iso(0))") == (422, "to"))
            #expect(try await status("&from=\(self.iso(0))&to=\(self.iso(93))") == (422, "to"), "94 дня")
            #expect(try await status("&from=\(self.iso(0))&to=\(self.iso(92))").0 == 200, "93 дня")
        }
    }
}
