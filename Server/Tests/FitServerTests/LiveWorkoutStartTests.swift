//  `POST /v1/workouts` через HTTP против живой базы (SPEC §7.1, §9.8, §20.3,
//  §20.6).
//
//  Проверяется то, что добавляет сам путь: состав приходит из плана, числа
//  пересчитаны на момент старта, строки легли куда должны, повтор не создаёт
//  второй тренировки, а просьба пересобрать на другом инвентаре отклоняется.
//
//  Часть утверждений стоит на СТРОКАХ, а не на теле ответа: `exercise_states
//  .current_rep_*` в ответ не едут вовсе (§20.6 называет их снимком последней
//  сессии), и проверить их можно только чтением. Читаются они транзакцией той
//  же пользовательницы — через RLS §3.2, а не владельцем базы.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Testing
import FitAPI
import FitCore
import Vapor
import VaporTesting
@testable import FitServer

@Suite("POST /v1/workouts: старт тренировки (§20.3)", .enabled(if: Live.enabled), .serialized)
struct LiveWorkoutStartTests {

    private var today: CalendarDay {
        Mapping.LocalTime.day(of: Date(), in: TimeZone(identifier: "Europe/Moscow")!)
    }
    private var weekStart: CalendarDay { Mapping.LocalTime.mondayOfWeek(today) }
    private var todayISOWeekday: Int { (today.dayNumber + 3) % 7 + 1 }

    private var day: DayContext {
        DayContext(date: Mapping.LocalTime.iso(today), tz: "Europe/Moscow")
    }

    /// Неделя из одного дня — сегодняшнего: только его можно начать, и
    /// утверждения не зависят от того, в какой день недели идёт прогон.
    private func seedAndGenerate(_ app: Application, _ user: Live.User,
                                 logger: Logger) async throws -> String {
        try await Live.seed(app, user, logger: logger, weekdays: [todayISOWeekday])
        let body = GenerateWeekPlanRequest(weekStart: Mapping.LocalTime.iso(weekStart), day: day)
        var dayID: String?
        try await app.testing().test(.POST, "/v1/week-plans", headers: user.headers,
                                     beforeRequest: { try $0.content.encode(body) }) { response in
            #expect(response.status == .created, Comment(rawValue: String(buffer: response.body)))
            let plan = try JSONDecoder().decode(WeekPlanResponseDTO.self,
                                                from: Data(buffer: response.body))
            dayID = plan.plan.days.first?.dayID
        }
        return try #require(dayID)
    }

    private func start(_ app: Application, _ user: Live.User, dayID: String,
                       equipment: String? = nil) async throws -> (Int, WorkoutDTO?, Data) {
        let body = StartWorkoutRequest(plannedDayID: dayID, equipmentProfileID: equipment,
                                       day: day)
        var captured: (Int, WorkoutDTO?, Data) = (0, nil, Data())
        try await app.testing().test(.POST, "/v1/workouts", headers: user.headers,
                                     beforeRequest: { try $0.content.encode(body) }) { response in
            let data = Data(buffer: response.body)
            captured = (Int(response.status.code),
                        try? JSONDecoder().decode(WorkoutDTO.self, from: data), data)
        }
        return captured
    }

    // MARK: - Состав, числа и строки

    @Test("старт отдаёт 201, состав из плана и дерево на каждое упражнение")
    func startsTheDay() async throws {
        let user = try await Live.signUpLinked()
        let logger = Live.quietLogger("workout.start")

        try await Live.withServer("workout.start") { app, database in
            let dayID = try await self.seedAndGenerate(app, user, logger: logger)
            let (status, workout, raw) = try await self.start(app, user, dayID: dayID)
            #expect(status == 201, Comment(rawValue: String(decoding: raw, as: UTF8.self)))
            let w = try #require(workout)

            #expect(w.plannedDayID == dayID)
            #expect(!w.exercises.isEmpty, "состав пришёл из плана")
            #expect(w.finishedAt == nil)
            #expect(w.readiness > 0)
            #expect(w.exercises.allSatisfy { $0.sets.isEmpty }, "подходов ещё нет")
            #expect(w.exercises.allSatisfy { $0.decisionTree != nil },
                    "подходы ещё остались — дерево обязано быть (§20.3)")
            #expect(w.exercises.map(\.orderIndex) == w.exercises.indices.map { $0 },
                    "порядок сохранён")

            // §20.6: диапазоны `exercise_states` пишутся из того же вызова
            // `repRange`, что дал `target_rep_*`. Это половина 20c про сам
            // диапазон — без неё сверка дерева с `nextSet` к нему слепа.
            let stored = try await database.withUserTransaction(
                authorization: "Bearer \(user.token)"
            ) { tx -> [String: ClosedRange<Int>] in
                var result: [String: ClosedRange<Int>] = [:]
                let rows = try await tx.query("""
                    select exercise_slug, current_rep_min, current_rep_max from exercise_states
                    """)
                for try await row in rows {
                    let (slug, lo, hi) = try row.decode((String, Int, Int).self)
                    result[slug] = lo...hi
                }
                return result
            }
            #expect(stored.count == w.exercises.count, "строка на каждое упражнение сессии")
            for exercise in w.exercises {
                #expect(stored[exercise.slug] == exercise.targetRepMin...exercise.targetRepMax,
                        Comment(rawValue: "диапазон разошёлся на \(exercise.slug)"))
                let tree = try #require(exercise.decisionTree)
                #expect(!tree.nodes.isEmpty)
            }
        }
    }

    // MARK: - Идемпотентность (§20.3)

    @Test("повтор отдаёт 200 и ТУ ЖЕ тренировку, второй строки не появляется")
    func repeatIsIdempotent() async throws {
        let user = try await Live.signUpLinked()
        let logger = Live.quietLogger("workout.repeat")

        try await Live.withServer("workout.repeat") { app, database in
            let dayID = try await self.seedAndGenerate(app, user, logger: logger)
            let (first, created, _) = try await self.start(app, user, dayID: dayID)
            #expect(first == 201)
            let one = try #require(created)

            let (second, again, raw) = try await self.start(app, user, dayID: dayID)
            #expect(second == 200, Comment(rawValue: String(decoding: raw, as: UTF8.self)))
            let two = try #require(again)
            #expect(two.id == one.id, "та же тренировка, а не новая")
            #expect(two.startedAt == one.startedAt, "и не перезапущенная")
            #expect(two.exercises.map(\.slug) == one.exercises.map(\.slug))

            let count = try await database.withUserTransaction(
                authorization: "Bearer \(user.token)"
            ) { tx -> Int in
                let rows = try await tx.query("select count(*)::int from workouts")
                for try await row in rows { return try row.decode(Int.self) }
                return -1
            }
            #expect(count == 1, "вторая строка не появилась")
        }
    }

    @Test("повтор с другим инвентарём — 409 day_not_planned с workout_id")
    func repeatWithOtherEquipmentIsRefused() async throws {
        let user = try await Live.signUpLinked()
        let logger = Live.quietLogger("workout.equipment")

        try await Live.withServer("workout.equipment") { app, database in
            let dayID = try await self.seedAndGenerate(app, user, logger: logger)
            let (status, created, _) = try await self.start(app, user, dayID: dayID)
            #expect(status == 201)
            let one = try #require(created)

            // Второй профиль — его фронтенд пишет напрямую (§20.6).
            let other = UUID()
            try await database.withUserTransaction(
                authorization: "Bearer \(user.token)"
            ) { tx -> Void in
                try await tx.query("""
                    insert into equipment_profiles (id, user_id, name, is_default, dumbbells_kg)
                    values (\(other), \(user.id), 'Дом', false, '{4,6,8,10}')
                    """)
            }

            let (refused, _, raw) = try await self.start(app, user, dayID: dayID,
                                                         equipment: other.uuidString)
            #expect(refused == 409, Comment(rawValue: String(decoding: raw, as: UTF8.self)))
            let envelope = try JSONDecoder().decode(APIErrorEnvelope.self, from: raw)
            #expect(envelope.error.code == .dayNotPlanned)
            #expect(envelope.error.details?["workout_id"] == .string(one.id),
                    "клиент обязан доехать до идущей тренировки отсюда")
        }
    }

    // MARK: - Отказы

    @Test("день со статусом skipped не начинается — 409 day_not_planned")
    func skippedDayIsRefused() async throws {
        let user = try await Live.signUpLinked()
        let logger = Live.quietLogger("workout.skipped")

        try await Live.withServer("workout.skipped") { app in
            let dayID = try await self.seedAndGenerate(app, user, logger: logger)
            let patch = PatchPlannedDayRequest(status: .skipped, day: self.day)
            try await app.testing().test(
                .PATCH, "/v1/week-plans/\(Mapping.LocalTime.iso(self.weekStart))/days/\(dayID)",
                headers: user.headers, beforeRequest: { try $0.content.encode(patch) }
            ) { response in
                #expect(response.status == .ok, Comment(rawValue: String(buffer: response.body)))
            }

            let (status, _, raw) = try await self.start(app, user, dayID: dayID)
            #expect(status == 409, Comment(rawValue: String(decoding: raw, as: UTF8.self)))
            let envelope = try JSONDecoder().decode(APIErrorEnvelope.self, from: raw)
            #expect(envelope.error.code == .dayNotPlanned)
            #expect(envelope.error.details?["status"] == .string("skipped"))
        }
    }

    @Test("чужой день начать нельзя — 404, а не чужая тренировка")
    func anotherUsersDayIsNotFound() async throws {
        let alice = try await Live.signUpLinked()
        let bob = try await Live.signUpLinked()
        let logger = Live.quietLogger("workout.isolation")

        try await Live.withServer("workout.isolation") { app in
            let dayID = try await self.seedAndGenerate(app, alice, logger: logger)
            try await Live.seed(app, bob, logger: logger, weekdays: [self.todayISOWeekday])

            let (status, _, raw) = try await self.start(app, bob, dayID: dayID)
            #expect(status == 404, Comment(rawValue: String(decoding: raw, as: UTF8.self)))
        }
    }
}
