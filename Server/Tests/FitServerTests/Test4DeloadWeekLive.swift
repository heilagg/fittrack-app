//  Разгрузочная неделя при генерации (SPEC §11.5, §19.2 п.4).
//
//  Правило проверяется в FitCore (`DeloadWeekTests`); здесь — то, что у него
//  есть только на сервере: откуда берутся дни тренировок, режим из профиля цикла
//  и что признак попадает в строку недели. Историю тренировок посев кладёт
//  прямым SQL: пройти её честным путём значило бы выполнить три недели подряд.

import Testing
import Foundation
import FitAPI
import FitCore
import Logging
import PostgresNIO
import Vapor
import VaporTesting
@testable import FitServer

@Suite("Разгрузочная неделя на сервере (§11.5)", .enabled(if: Live.enabled), .serialized)
struct Test4DeloadWeekLive {

    private let zone = TimeZone(identifier: "Europe/Moscow")!
    private var today: CalendarDay { Mapping.LocalTime.day(of: Date(), in: zone) }
    private var thisMonday: CalendarDay { today.mondayOfWeek }
    private var day: DayContext { DayContext(date: Mapping.LocalTime.iso(today), tz: zone.identifier) }

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

    /// Завершённая (или нет) тренировка с одним подходом в день `date`.
    private func workout(_ user: Live.User, on date: CalendarDay, finished: Bool = true,
                         logger: Logger) async throws {
        let client = Live.ownerClient(logger)
        let iso = Mapping.LocalTime.iso(date)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            group.addTask {
                let workoutID = UUID(), exerciseID = UUID()
                _ = try await client.query("""
                    insert into workouts (id, user_id, started_at, finished_at, session_kind, readiness)
                    values (\(workoutID), \(user.id), \(iso)::date + time '12:00',
                            case when \(finished) then \(iso)::date + time '13:00' else null end,
                            'full_body', 1.0)
                    """, logger: logger)
                _ = try await client.query("""
                    insert into workout_exercises (id, workout_id, exercise_slug, order_index,
                        target_sets, target_rep_min, target_rep_max, target_rir, weight_readiness)
                    values (\(exerciseID), \(workoutID), 'goblet-squat', 0, 3, 8, 12, 2, 1.0)
                    """, logger: logger)
                _ = try await client.query("""
                    insert into sets (id, workout_exercise_id, set_index, prescribed_reps,
                                      exercise_slug, is_calibration, weight_readiness, performed_on)
                    values (\(UUID()), \(exerciseID), 0, 12, 'goblet-squat', false, 1.0, \(iso)::date)
                    """, logger: logger)
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func setDeload(_ user: Live.User, weekStart: CalendarDay, logger: Logger) async throws {
        let client = Live.ownerClient(logger)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            group.addTask {
                _ = try await client.query("""
                    insert into week_plans (id, user_id, week_start, generated_at, is_deload, input_digest)
                    values (\(UUID()), \(user.id), \(Mapping.LocalTime.iso(weekStart))::date, now(),
                            true, '{"v": 1}'::jsonb)
                    """, logger: logger)
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func generate(_ app: Application, _ user: Live.User) async throws {
        let body = GenerateWeekPlanRequest(weekStart: Mapping.LocalTime.iso(thisMonday), day: day)
        try await app.testing().test(.POST, "/v1/week-plans", headers: user.headers,
                                     beforeRequest: { try $0.content.encode(body) }) { response in
            guard response.status == .created else {
                throw Live.Failure.seed("POST /v1/week-plans → \(response.status.code): "
                                        + String(buffer: response.body))
            }
        }
    }

    /// `is_deload` недели, которую только что записал сервер.
    private func isDeload(_ user: Live.User, logger: Logger) async throws -> Bool? {
        enum Outcome: Sendable { case pool, result(Bool?) }
        let client = Live.ownerClient(logger)
        let monday = Mapping.LocalTime.iso(thisMonday)
        return try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask { await client.run(); return .pool }
            group.addTask {
                let rows = try await client.query("""
                    select is_deload from week_plans
                     where user_id = \(user.id) and week_start = \(monday)::date
                    """, logger: logger)
                for try await row in rows { return .result(try row.decode(Bool.self)) }
                return .result(nil)
            }
            var found: Bool?
            for try await outcome in group {
                if case .result(let value) = outcome { found = value; break }
            }
            group.cancelAll()
            return found
        }
    }

    /// Три выполненные недели накопления перед текущей.
    private func threeWeeks(_ user: Live.User, logger: Logger) async throws {
        for back in [3, 2, 1] {
            try await workout(user, on: thisMonday.adding(days: -7 * back + 2), logger: logger)
        }
    }

    // MARK: Тесты

    @Test("после трёх выполненных недель в режиме без фаз неделя разгрузочная")
    func fourthWeekIsDeload() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("t4.deload")
        try await Live.withServer("t4.deload") { app in
            // Без `cycle_profiles` и с tracking off: режим подставляет Mapping.
            try await self.seed(app, user, tracking: .off, cycle: nil, logger: logger)
            try await self.threeWeeks(user, logger: logger)
            try await self.generate(app, user)
            #expect(try await self.isDeload(user, logger: logger) == true)
        }
    }

    @Test("недели без тренировок не считаются, а незавершённая тренировка — не выполненная")
    func emptyAndUnfinishedWeeksDoNotCount() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("t4.empty")
        try await Live.withServer("t4.empty") { app in
            try await self.seed(app, user, tracking: .off, cycle: nil, logger: logger)
            // Две выполненные недели, пропуск и незавершённая тренировка.
            try await self.workout(user, on: self.thisMonday.adding(days: -28 + 2), logger: logger)
            try await self.workout(user, on: self.thisMonday.adding(days: -21 + 2), logger: logger)
            try await self.workout(user, on: self.thisMonday.adding(days: -7 + 2),
                                   finished: false, logger: logger)
            try await self.generate(app, user)
            #expect(try await self.isDeload(user, logger: logger) == false)
        }
    }

    @Test("выполненная разгрузочная неделя обнуляет счёт")
    func executedDeloadResets() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("t4.reset")
        try await Live.withServer("t4.reset") { app in
            try await self.seed(app, user, tracking: .off, cycle: nil, logger: logger)
            // Четыре выполненные недели, последняя из них записана разгрузочной.
            for back in [4, 3, 2, 1] {
                try await self.workout(user, on: self.thisMonday.adding(days: -7 * back + 2),
                                       logger: logger)
            }
            try await self.setDeload(user, weekStart: self.thisMonday.adding(days: -7), logger: logger)
            try await self.generate(app, user)
            #expect(try await self.isDeload(user, logger: logger) == false)
        }
    }

    @Test("перерыв в 22 дня и больше обнуляет счёт")
    func breakResets() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("t4.break")
        try await Live.withServer("t4.break") { app in
            try await self.seed(app, user, tracking: .off, cycle: nil, logger: logger)
            // Три недели накопления, но последняя тренировка — 22 дня назад.
            let last = self.today.adding(days: -22)
            for back in [14, 7, 0] {
                try await self.workout(user, on: last.adding(days: -back), logger: logger)
            }
            try await self.generate(app, user)
            #expect(try await self.isDeload(user, logger: logger) == false)
        }
    }

    @Test("в фазовом режиме признак всегда false, сколько бы недель ни было")
    func phasesModeNeverDeloads() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("t4.phases")
        try await Live.withServer("t4.phases") { app in
            try await self.seed(app, user, tracking: .manual,
                                cycle: CycleProfileDTO(phaseMode: .phases), logger: logger)
            try await self.threeWeeks(user, logger: logger)
            try await self.generate(app, user)
            #expect(try await self.isDeload(user, logger: logger) == false)
        }
    }

    @Test("повторный POST недели признак не пересчитывает")
    func repeatKeepsTheStoredFlag() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("t4.frozen")
        try await Live.withServer("t4.frozen") { app in
            try await self.seed(app, user, tracking: .off, cycle: nil, logger: logger)
            try await self.threeWeeks(user, logger: logger)
            try await self.generate(app, user)
            // Ещё одна выполненная неделя не меняет уже записанное.
            try await self.workout(user, on: self.today, logger: logger)
            let body = GenerateWeekPlanRequest(weekStart: Mapping.LocalTime.iso(self.thisMonday),
                                               day: self.day)
            try await app.testing().test(.POST, "/v1/week-plans", headers: user.headers,
                                         beforeRequest: { try $0.content.encode(body) }) { response in
                #expect(response.status == .ok)
            }
            #expect(try await self.isDeload(user, logger: logger) == true)
        }
    }
}
