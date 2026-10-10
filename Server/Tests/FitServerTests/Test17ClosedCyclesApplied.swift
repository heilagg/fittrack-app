//  Закрытые циклы применяются перед расчётом состояния (SPEC §11.5, §20.6,
//  §19.2 п.17).
//
//  До этого `Cycle.applyingClosedCycles` не вызывал никто, и автопереход в
//  режим «без фаз» по низкой уверенности на вебе не срабатывал вовсе. Тесты
//  ставятся на то, что видно снаружи: колонки `cycle_profiles` после запроса и
//  ответ карточки дня. Данные — чередование 20 / 45 / 20 дней: три закрытия
//  подряд с уверенностью ниже 0.3 (тот же набор, что в
//  `test_alternatingShortCyclesTripLowConfidenceMode` ядра).

import Testing
import Foundation
import FitAPI
import FitCore
import Logging
import PostgresNIO
import Vapor
import VaporTesting
@testable import FitServer

// MARK: - Чистая часть

@Suite("Закрытые циклы: чистая часть (§20.6)")
struct Test17ClosedCyclesPure {

    private func start(_ day: CalendarDay) -> CycleEvent {
        CycleEvent(kind: .periodStart, occurredOn: day)
    }

    /// Три закрытия подряд мимо прогноза: 20, 45, 20.
    private func lowConfidenceStarts(endingBefore today: CalendarDay) -> [CycleEvent] {
        let first = today.adding(days: -100)
        return [0, 20, 65, 85].map { start(first.adding(days: $0)) }
    }

    private let today = CalendarDay(year: 2026, month: 10, day: 10)
    private var irregular: CycleProfile { CycleProfile(declaredRegularity: .irregular) }

    @Test("профиль применяется: три плохих закрытия уводят в режим без фаз")
    func appliesClosedCycles() {
        let inputs = CycleInputs(events: lowConfidenceStarts(endingBefore: today), profile: irregular)
        let applied = Mapping.applyingClosedCycles(to: inputs, applies: true, asOf: today)
        #expect(applied.profile.phaseMode == .noPhases)
        #expect(applied.profile.noPhaseReason == .lowConfidence)
        #expect(applied.profile.lowConfidenceStreak == 3)
    }

    @Test("повторное применение ничего не досчитывает")
    func secondApplicationIsNoOp() {
        let inputs = CycleInputs(events: lowConfidenceStarts(endingBefore: today), profile: irregular)
        let once = Mapping.applyingClosedCycles(to: inputs, applies: true, asOf: today)
        let twice = Mapping.applyingClosedCycles(to: once, applies: true, asOf: today)
        #expect(twice == once, "серия не удваивается")
    }

    @Test("нет настоящего профиля — ничего не применяется")
    func notAppliedWithoutRealProfile() {
        let inputs = CycleInputs(events: lowConfidenceStarts(endingBefore: today), profile: irregular)
        #expect(Mapping.applyingClosedCycles(to: inputs, applies: false, asOf: today) == inputs)
    }

    @Test("событие позже дня запроса закрытием не считается")
    func futureEventsAreDropped() {
        // Два прошлых закрытия и одно «завтрашнее»: с ним серия дошла бы до трёх.
        let past = lowConfidenceStarts(endingBefore: today).prefix(3)
        let events = Array(past) + [start(today.adding(days: 5))]
        let applied = Mapping.applyingClosedCycles(
            to: CycleInputs(events: events, profile: irregular), applies: true, asOf: today)
        #expect(applied.profile.lowConfidenceStreak == 2)
        #expect(applied.profile.phaseMode == .phases)
        #expect(applied.profile.lowConfidenceCountedThrough == today.adding(days: -100 + 65),
                "отметка осталась на последнем прошлом закрытии, а не ушла в будущее")
    }

    // MARK: - Переключение режима (§20.6)

    private func stored(streak: Int, through: CalendarDay?, mode: PhaseMode = .phases,
                        reason: NoPhaseReason? = nil) -> CycleProfile {
        CycleProfile(typicalCycleLengthDays: 30, phaseMode: mode, noPhaseReason: reason,
                     lowConfidenceStreak: streak, lowConfidenceCountedThrough: through)
    }

    @Test("тот же режим — не переключение: серия и отметка на месте")
    func sameModeKeepsCounters() {
        let through = today.adding(days: -15)
        let next = Mapping.cycleSettingsApplied(
            CycleProfileDTO(typicalCycleLengthDays: 26, phaseMode: .phases),
            over: stored(streak: 2, through: through), switchDay: today)
        #expect(next.lowConfidenceStreak == 2)
        #expect(next.lowConfidenceCountedThrough == through)
        #expect(next.typicalCycleLengthDays == 26, "заявленные поля пишутся как прежде")
    }

    @Test("смена режима сбрасывает серию и двигает отметку на день переключения")
    func switchResetsStreak() {
        let next = Mapping.cycleSettingsApplied(
            CycleProfileDTO(phaseMode: .phases),
            over: stored(streak: 3, through: today.adding(days: -40),
                         mode: .noPhases, reason: .lowConfidence),
            switchDay: today.adding(days: -15))
        #expect(next.phaseMode == .phases)
        #expect(next.noPhaseReason == nil)
        #expect(next.lowConfidenceStreak == 0)
        #expect(next.lowConfidenceCountedThrough == today.adding(days: -15))
    }

    @Test("строки не было — создание, счётчики по умолчанию")
    func creationIsNotASwitch() {
        let next = Mapping.cycleSettingsApplied(
            CycleProfileDTO(phaseMode: .noPhases, noPhaseReason: .contraception),
            over: nil, switchDay: today)
        #expect(next.noPhaseReason == .contraception)
        #expect(next.lowConfidenceStreak == 0)
        #expect(next.lowConfidenceCountedThrough == nil)
    }

    @Test("день переключения: последняя period_start, а без событий — серверная дата")
    func switchDay() {
        #expect(Mapping.cycleSwitchDay(latestPeriodStart: today.adding(days: -9), serverToday: today)
                == today.adding(days: -9))
        #expect(Mapping.cycleSwitchDay(latestPeriodStart: nil, serverToday: today) == today)
    }

    // MARK: - /rebuild: «до» и «после» (§20.3)

    @Test("автопереход режима, вызванный новым событием, называется сменой фазы")
    func rebuildCauseSeesAutoSwitch() {
        // Сохранённый профиль: два закрытия учтено, режим фазовый. Четвёртая
        // отметка пришла мимо сервера и закрывает третий плохой цикл.
        let events = lowConfidenceStarts(endingBefore: today)
        let storedProfile = CycleProfile(declaredRegularity: .irregular, phaseMode: .phases,
                                         lowConfidenceStreak: 2,
                                         lowConfidenceCountedThrough: today.adding(days: -100 + 65))
        let raw = CycleInputs(events: events, profile: storedProfile)
        let applied = Mapping.applyingClosedCycles(to: raw, applies: true, asOf: today)
        #expect(applied.profile.phaseMode == .noPhases, "предпосылка: новое закрытие переключило режим")

        let cause = WeekPlanRoutes.cause(for: .cycleEventAdded, cycle: applied,
                                         stored: storedProfile, applies: true, on: today)
        guard case .phaseChanged = cause else {
            Issue.record("режим сменился этим событием — причина про фазу, получено: \(cause)")
            return
        }
    }
}

// MARK: - Живая часть

@Suite("Закрытые циклы через HTTP (§20.6)", .enabled(if: Live.enabled), .serialized)
struct Test17ClosedCyclesLive {

    private let zone = TimeZone(identifier: "Europe/Moscow")!
    private var today: CalendarDay { Mapping.LocalTime.day(of: Date(), in: zone) }
    private var day: DayContext { DayContext(date: Mapping.LocalTime.iso(today), tz: zone.identifier) }

    private var todayPath: String {
        "/v1/today?date=\(Mapping.LocalTime.iso(today))&tz=Europe%2FMoscow"
    }

    // MARK: Посев

    /// Профиль, как онбординг: через `PATCH`, плюс то, что пишет фронтенд.
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

    private func patchCycle(_ app: Application, _ user: Live.User, _ cycle: CycleProfileDTO) async throws {
        try await app.testing().test(.PATCH, "/v1/profile", headers: user.headers,
                                     beforeRequest: {
            try $0.content.encode(PatchProfileRequest(cycle: cycle))
        }) { response in
            guard response.status == .ok else {
                throw Live.Failure.seed("PATCH cycle → \(response.status.code)")
            }
        }
    }

    /// Пишущий путь: генерация недели. Любой другой ничем не лучше.
    private func writingRequest(_ app: Application, _ user: Live.User) async throws {
        let monday = Mapping.LocalTime.mondayOfWeek(today)
        let body = GenerateWeekPlanRequest(weekStart: Mapping.LocalTime.iso(monday), day: day)
        try await app.testing().test(.POST, "/v1/week-plans", headers: user.headers,
                                     beforeRequest: { try $0.content.encode(body) }) { response in
            guard response.status == .created || response.status == .ok else {
                throw Live.Failure.seed("POST /v1/week-plans → \(response.status.code): "
                                        + String(buffer: response.body))
            }
        }
    }

    private func card(_ app: Application, _ user: Live.User) async throws -> TodayCardDTO {
        var card: TodayCardDTO?
        try await app.testing().test(.GET, todayPath, headers: user.headers) { response in
            card = try JSONDecoder().decode(TodayCardDTO.self, from: Data(buffer: response.body))
        }
        return try #require(card)
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
    }

    private func row(_ user: Live.User, logger: Logger) async throws -> Row? {
        enum Outcome: Sendable { case pool, result(Row?) }
        let client = Live.ownerClient(logger)
        return try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask { await client.run(); return .pool }
            group.addTask {
                let rows = try await client.query("""
                    select phase_mode, no_phase_reason, low_confidence_streak,
                           to_char(low_confidence_counted_through, 'YYYY-MM-DD'), updated_at::text
                      from cycle_profiles where user_id = \(user.id)
                    """, logger: logger)
                for try await r in rows {
                    let (mode, reason, streak, through, updated) =
                        try r.decode((String, String?, Int, String?, String).self)
                    return .result(Row(mode: mode, reason: reason, streak: streak,
                                       through: through, updatedAt: updated))
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

    private let irregular = CycleProfileDTO(declaredRegularity: .irregular, phaseMode: .phases)

    // MARK: Тесты

    @Test("/today считает применённый режим в памяти и в базу не пишет, пишущий путь сохраняет")
    func todayInMemoryWritingPathPersists() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("t17.persist")
        try await Live.withServer("t17.persist") { app in
            try await self.seed(app, user, tracking: .manual, cycle: self.irregular, logger: logger)
            try await self.insertStarts(user, offsets: [-100, -80, -35, -15], logger: logger)
            let before = try #require(try await self.row(user, logger: logger))
            #expect(before.mode == "phases" && before.streak == 0)

            let card = try await self.card(app, user)
            #expect(card.cycle.phaseMode == "no_phases", "карточка видит применённый режим")
            #expect(card.cycle.noPhaseReason == "low_confidence")
            let afterToday = try #require(try await self.row(user, logger: logger))
            #expect(afterToday == before, "/today не пишет ничего")

            try await self.writingRequest(app, user)
            let saved = try #require(try await self.row(user, logger: logger))
            #expect(saved.mode == "no_phases" && saved.reason == "low_confidence")
            #expect(saved.streak == 3)
            #expect(saved.through == Mapping.LocalTime.iso(self.today.adding(days: -15)))
            #expect(saved.updatedAt == before.updatedAt, "updated_at не трогается (LWW §4.3)")

            // Повторный пишущий запрос серию не удваивает.
            try await self.writingRequest(app, user)
            let again = try #require(try await self.row(user, logger: logger))
            #expect(again == saved)
        }
    }

    @Test("/preview, как и /today, считает в памяти и не пишет; чтение недели — пишет")
    func previewDoesNotPersist() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("t17.preview")
        try await Live.withServer("t17.preview") { app in
            try await self.seed(app, user, tracking: .manual, cycle: self.irregular, logger: logger)
            try await self.writingRequest(app, user)          // неделя есть, событий ещё нет
            try await self.insertStarts(user, offsets: [-100, -80, -35, -15], logger: logger)
            let before = try #require(try await self.row(user, logger: logger))
            #expect(before.streak == 0)

            let week = Mapping.LocalTime.iso(Mapping.LocalTime.mondayOfWeek(self.today))
            let query = "date=\(Mapping.LocalTime.iso(self.today))&tz=Europe%2FMoscow"
            try await app.testing().test(
                .GET, "/v1/week-plans/\(week)/preview?\(query)&day=\(Mapping.LocalTime.iso(self.today))",
                headers: user.headers) { response in
                #expect(response.status == .ok)
            }
            #expect(try await self.row(user, logger: logger) == before, "/preview не пишет")

            try await app.testing().test(.GET, "/v1/week-plans/\(week)?\(query)",
                                         headers: user.headers) { response in
                #expect(response.status == .ok)
            }
            let saved = try #require(try await self.row(user, logger: logger))
            #expect(saved.streak == 3, "GET недели уже пишет снимок и сохраняет счётчик")
        }
    }

    @Test("нет строки cycle_profiles — не создаётся; tracking off — строка не двигается")
    func noRowAndTrackingOffAreLeftAlone() async throws {
        let noRow = try await Live.signUpAnonymous()
        let off = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("t17.norow")
        try await Live.withServer("t17.norow") { app in
            try await self.seed(app, noRow, tracking: .manual, cycle: nil, logger: logger)
            try await self.seed(app, off, tracking: .off, cycle: self.irregular, logger: logger)
            for user in [noRow, off] {
                try await self.insertStarts(user, offsets: [-100, -80, -35, -15], logger: logger)
                try await self.writingRequest(app, user)
            }
            #expect(try await self.row(noRow, logger: logger) == nil, "строку ради счётчика не создают")
            let untouched = try #require(try await self.row(off, logger: logger))
            #expect(untouched.mode == "phases" && untouched.streak == 0 && untouched.through == nil)
        }
    }

    @Test("событие «на завтра» закрытием не считается и отметку в будущее не уводит")
    func futureEventDoesNotCloseACycle() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("t17.future")
        try await Live.withServer("t17.future") { app in
            try await self.seed(app, user, tracking: .manual, cycle: self.irregular, logger: logger)
            try await self.insertStarts(user, offsets: [-100, -80, -35, 5], logger: logger)
            try await self.writingRequest(app, user)
            let saved = try #require(try await self.row(user, logger: logger))
            #expect(saved.streak == 2 && saved.mode == "phases")
            #expect(saved.through == Mapping.LocalTime.iso(self.today.adding(days: -35)))
        }
    }

    @Test("ручное переключение через PATCH сбрасывает серию; тот же режим её не трогает")
    func manualSwitchResetsStreak() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("t17.switch")
        try await Live.withServer("t17.switch") { app in
            try await self.seed(app, user, tracking: .manual, cycle: self.irregular, logger: logger)
            try await self.insertStarts(user, offsets: [-100, -80, -35, -15], logger: logger)
            try await self.writingRequest(app, user)
            let tripped = try #require(try await self.row(user, logger: logger))
            #expect(tripped.mode == "no_phases" && tripped.streak == 3)

            // Включает фазы обратно: три закрытия ДО этого дня не идут в новую серию.
            try await self.patchCycle(app, user, self.irregular)
            try await self.writingRequest(app, user)
            let switched = try #require(try await self.row(user, logger: logger))
            #expect(switched.mode == "phases" && switched.reason == nil)
            #expect(switched.streak == 0, "серия не пережила переключение")
            #expect(switched.through == Mapping.LocalTime.iso(self.today.adding(days: -15)),
                    "день переключения — наибольшая period_start (§20.6)")

            // Тот же режим ещё раз — не переключение.
            try await self.patchCycle(app, user, self.irregular)
            let same = try #require(try await self.row(user, logger: logger))
            #expect(same.streak == 0 && same.through == switched.through)
        }
    }
}
