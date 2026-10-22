//  `POST /v1/workouts/{id}/finish` через HTTP против живой базы (SPEC §7.1,
//  §8.1, §20.3, §20.6, §20.7).
//
//  Что проверяется и почему каждое утверждение не слепое:
//
//    — день плана закрывается `done`, без выполненных подходов — `skipped`
//      (§7.1); проверяется строка, а не только ответ;
//    — утомление ложится на момент КАЖДОГО подхода в зоне запроса: метка
//      `muscle_fatigue.updated_at` сверяется с местным временем
//      `completed_at`, а значение — с прямым вызовом `Recovery.applying`.
//      Один момент на `finished_at` или запись в UTC дают другую метку;
//    — повтор отвечает 200 тем же телом с `notice = null`, и утомление после
//      него РАВНО утомлению после первого вызова (не удвоено);
//    — нет тренировки — 409 `workout_not_started` (путь пишущий);
//    — нет недели — ключа `week` нет (общее правило FitAPI: опускать);
//    — закрытие двигает `sync_seq` тренировки (20g).

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Testing
import FitAPI
import FitContent
import FitCore
import Vapor
import VaporTesting
@testable import FitServer

@Suite("POST /v1/workouts/{id}/finish (§20.3)", .enabled(if: Live.enabled), .serialized)
struct LiveFinishTests {

    private let moscow = TimeZone(identifier: "Europe/Moscow")!

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    private func finish(_ app: Application, _ user: Live.User,
                        workout: String) async throws -> (Int, Data) {
        var captured: (Int, Data) = (0, Data())
        try await app.testing().test(
            .POST, "/v1/workouts/\(workout)/finish", headers: user.headers,
            beforeRequest: { try $0.content.encode(FinishWorkoutRequest(day: Live.today)) }
        ) { response in
            captured = (Int(response.status.code), Data(buffer: response.body))
        }
        return captured
    }

    private func logSet(_ app: Application, _ user: Live.User, workout: String,
                        exercise: WorkoutExerciseDTO, index: Int, at moment: Date,
                        skipped: Bool = false) async throws {
        let body = skipped
            ? LogSetRequest(id: UUID().uuidString, setIndex: index, completedAt: iso(moment),
                            skipped: true, day: Live.today)
            : LogSetRequest(id: UUID().uuidString, setIndex: index, prescribedKg: exercise.prescribedKg,
                            actualKg: exercise.prescribedKg ?? (exercise.weighted ? 20 : nil), actualReps: exercise.targetRepMin,
                            feedback: .ok, completedAt: iso(moment), day: Live.today)
        try await app.testing().test(
            .POST, "/v1/workouts/\(workout)/exercises/\(exercise.id)/sets",
            headers: user.headers, beforeRequest: { try $0.content.encode(body) }
        ) { response in
            #expect(response.status == .ok, Comment(rawValue: String(buffer: response.body)))
        }
    }

    private func sql<T: Sendable>(_ database: Database, _ user: Live.User,
                                  _ body: @escaping @Sendable (UserTransaction) async throws -> T)
        async throws -> T {
        try await database.withUserTransaction(authorization: "Bearer \(user.token)", body)
    }

    private func dayStatus(_ database: Database, _ user: Live.User, dayID: String) async throws -> String? {
        try await sql(database, user) { tx in
            for try await row in try await tx.query(
                "select status from planned_days where id = \(UUID(uuidString: dayID)!)") {
                return try row.decode(String.self)
            }
            return nil
        }
    }

    private func fatigueRows(_ database: Database, _ user: Live.User)
        async throws -> [String: (value: Double, hours: Double)] {
        try await sql(database, user) { tx in
            var result: [String: (value: Double, hours: Double)] = [:]
            for try await row in try await tx.query("""
                select muscle, value::float8, extract(epoch from updated_at)::float8 / 3600
                  from muscle_fatigue
                """) {
                let (m, v, h) = try row.decode((String, Double, Double).self)
                result[m] = (v, h)
            }
            return result
        }
    }

    private func dropCalibration(_ database: Database, _ user: Live.User, exercise: String) async throws {
        try await sql(database, user) { tx -> Void in
            try await tx.query("""
                update workout_exercises set is_calibration = false
                 where id = \(UUID(uuidString: exercise)!)
                """)
        }
    }

    // MARK: - День плана

    @Test("выполненный подход — день done; ответ несёт закрытую тренировку и неделю")
    func finishMarksTheDayDone() async throws {
        let user = try await Live.signUpLinked()
        let logger = Live.quietLogger("finish.done")
        try await Live.withServer("finish.done") { app, database in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            let exercise = try #require(workout.exercises.first)
            try await self.logSet(app, user, workout: workout.id, exercise: exercise,
                                  index: 1, at: Date())

            let (status, raw) = try await self.finish(app, user, workout: workout.id)
            #expect(status == 200, Comment(rawValue: String(decoding: raw, as: UTF8.self)))
            let dto = try JSONDecoder().decode(FinishWorkoutResponseDTO.self, from: raw)
            #expect(dto.workout.finishedAt != nil)
            #expect(dto.week != nil, "неделя дня тренировки сгенерирована — она обязана приехать")
            let dayID = try #require(workout.plannedDayID)
            #expect(try await self.dayStatus(database, user, dayID: dayID) == "done")
            // Закрытый день больше не собирается (§7.1): итог дня — `done`.
            let outcome = try #require(dto.week?.plan.days.first { $0.dayID == dayID })
            #expect(outcome.cause?.cause == .done, "закрытый день собран заново")
            // Неделя из одного дня: уход дня по факту исполнения изменением
            // плана не считается, и §7.1 требует молчать (сценарий 32b).
            #expect(dto.week?.notice == nil, "строка о закрытии единственного дня")
        }
    }

    @Test("ни одного выполненного подхода — день skipped (§7.1)")
    func finishWithoutPerformedSetsSkipsTheDay() async throws {
        let user = try await Live.signUpLinked()
        let logger = Live.quietLogger("finish.skipped")
        try await Live.withServer("finish.skipped") { app, database in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            let exercise = try #require(workout.exercises.first)
            // Пропущенный подход есть, выполненного нет.
            try await self.logSet(app, user, workout: workout.id, exercise: exercise,
                                  index: 1, at: Date(), skipped: true)
            let (status, raw) = try await self.finish(app, user, workout: workout.id)
            #expect(status == 200, Comment(rawValue: String(decoding: raw, as: UTF8.self)))
            let dayID = try #require(workout.plannedDayID)
            #expect(try await self.dayStatus(database, user, dayID: dayID) == "skipped")
            let dto = try JSONDecoder().decode(FinishWorkoutResponseDTO.self, from: raw)
            #expect(dto.week?.notice == nil, "строка о закрытии единственного дня")
        }
    }

    // MARK: - Утомление (§8.1, §20.7)

    @Test("утомление — на момент подхода в зоне запроса, значение как у Recovery.applying")
    func fatigueLandsOnEachSetsMoment() async throws {
        let user = try await Live.signUpLinked()
        let logger = Live.quietLogger("finish.fatigue")
        let library = try Content.loadBundled()
        try await Live.withServer("finish.fatigue") { app, database in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            let exercise = try #require(workout.exercises.first)
            try await self.dropCalibration(database, user, exercise: exercise.id)

            // Секунды целые: completed_at едет строкой ISO без долей.
            let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            let early = now.addingTimeInterval(-3 * 3600), late = now.addingTimeInterval(-3600)
            try await self.logSet(app, user, workout: workout.id, exercise: exercise, index: 1, at: early)
            try await self.logSet(app, user, workout: workout.id, exercise: exercise, index: 2, at: late)
            let (status, _) = try await self.finish(app, user, workout: workout.id)
            #expect(status == 200)

            let candidate = try #require(library.candidates.first { $0.slug == exercise.slug })
            let load = candidate.muscleContributions.mapValues { $0 * candidate.fatigueCost }
            let one = FatigueSet(muscleLoad: load, feedback: .ok)
            let t1 = Mapping.LocalTime.timestamp(of: early, in: self.moscow)
            let t2 = Mapping.LocalTime.timestamp(of: late, in: self.moscow)
            let expected = Recovery.applying([one], at: t2,
                                             to: Recovery.applying([one], at: t1, to: [:]))

            let stored = try await self.fatigueRows(database, user)
            #expect(!stored.isEmpty, "утомление не записано")
            for (muscle, state) in expected where state.value > 0 {
                let row = try #require(stored[muscle.rawValue], "\(muscle.rawValue) не записана")
                #expect(abs(row.value - state.value) < 0.001,
                        "\(muscle.rawValue): \(row.value) против \(state.value)")
                #expect(abs(row.hours - t2.hoursSinceEpoch) < 1e-6,
                        "\(muscle.rawValue): метка не на местном моменте последнего подхода")
            }
        }
    }

    // MARK: - Повтор (§20.3)

    @Test("повтор — 200 тем же телом, notice null, утомление не удвоено, день done")
    func repeatedFinishAppliesNothing() async throws {
        let user = try await Live.signUpLinked()
        let logger = Live.quietLogger("finish.repeat")
        try await Live.withServer("finish.repeat") { app, database in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            let exercise = try #require(workout.exercises.first)
            try await self.dropCalibration(database, user, exercise: exercise.id)
            try await self.logSet(app, user, workout: workout.id, exercise: exercise,
                                  index: 1, at: Date())

            let (first, firstRaw) = try await self.finish(app, user, workout: workout.id)
            #expect(first == 200)
            let afterFirst = try await self.fatigueRows(database, user)
            #expect(!afterFirst.isEmpty, "иначе неудвоение проверять не на чем")

            let (second, secondRaw) = try await self.finish(app, user, workout: workout.id)
            #expect(second == 200, Comment(rawValue: String(decoding: secondRaw, as: UTF8.self)))
            let a = try JSONDecoder().decode(FinishWorkoutResponseDTO.self, from: firstRaw)
            let b = try JSONDecoder().decode(FinishWorkoutResponseDTO.self, from: secondRaw)
            #expect(b.workout == a.workout, "повтор отдал другую тренировку")
            #expect(b.week?.notice == nil)
            #expect(b.week?.plan == a.week?.plan)

            let afterSecond = try await self.fatigueRows(database, user)
            #expect(afterSecond.mapValues(\.value) == afterFirst.mapValues(\.value),
                    "повтор применил утомление второй раз")
            #expect(try await self.dayStatus(database, user, dayID: try #require(workout.plannedDayID))
                    == "done")
        }
    }

    // MARK: - Адресация и неделя

    @Test("нет тренировки (или она чужая) — 409 workout_not_started")
    func missingWorkoutIsNotStarted() async throws {
        let alice = try await Live.signUpLinked()
        let bob = try await Live.signUpLinked()
        let logger = Live.quietLogger("finish.missing")
        try await Live.withServer("finish.missing") { app, database in
            let workout = try await Live.startedWorkout(app, alice, logger: logger)
            for (user, id) in [(alice, UUID().uuidString), (bob, workout.id)] {
                let (status, raw) = try await self.finish(app, user, workout: id)
                #expect(status == 409)
                let envelope = try JSONDecoder().decode(APIErrorEnvelope.self, from: raw)
                #expect(envelope.error.code == .workoutNotStarted)
            }
            // Чужой запрос тренировку не закрыл.
            let open = try await self.sql(database, alice) { tx -> Bool in
                for try await row in try await tx.query(
                    "select finished_at is null from workouts where id = \(UUID(uuidString: workout.id)!)") {
                    return try row.decode(Bool.self)
                }
                return false
            }
            #expect(open)
        }
    }

    @Test("без дня и без сгенерированной недели — ключа week нет, тренировка есть")
    func noWeekGivesExplicitNull() async throws {
        let user = try await Live.signUpLinked()
        let logger = Live.quietLogger("finish.noweek")
        try await Live.withServer("finish.noweek") { app, database in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            // Неделя удалена: день уходит каскадом, `planned_day_id` — в null.
            try await self.sql(database, user) { tx -> Void in
                try await tx.query("delete from week_plans")
            }
            let (status, raw) = try await self.finish(app, user, workout: workout.id)
            #expect(status == 200, Comment(rawValue: String(decoding: raw, as: UTF8.self)))
            // Общее правило FitAPI: отсутствующее опускается, а не едет null.
            let object = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
            #expect(!object.keys.contains("week"), "неделя приехала, хотя её нет")
            #expect(object.keys.contains("workout"))
        }
    }

    @Test("20g: закрытие двигает sync_seq тренировки")
    func test20g_finishMovesSyncSeq() async throws {
        let user = try await Live.signUpLinked()
        let logger = Live.quietLogger("finish.20g")
        try await Live.withServer("finish.20g") { app, database in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            let id = try #require(UUID(uuidString: workout.id))
            let seq = { @Sendable () async throws -> Int64 in
                try await self.sql(database, user) { tx in
                    for try await row in try await tx.query(
                        "select sync_seq from workouts where id = \(id)") {
                        return try row.decode(Int64.self)
                    }
                    return -1
                }
            }
            let before = try await seq()
            let (status, _) = try await self.finish(app, user, workout: workout.id)
            #expect(status == 200)
            #expect(try await seq() > before)
        }
    }
}
