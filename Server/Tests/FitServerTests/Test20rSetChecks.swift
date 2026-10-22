//  20r. Вес и проверки подхода через HTTP (SPEC §9.8, §19.2 п.23, §20.3,
//  §20.7, §20.15).
//
//  Вес клиент присылает числом, а пишется ближайшая ступень лестницы; ответ
//  несёт записанный подход. Утверждения о записанном ставятся против строки
//  `sets`, прочитанной транзакцией пользовательницы, а не только против тела
//  ответа: ответ, сверенный с самим собой, не поймал бы округления только в
//  ответе.
//
//  Лестница считается здесь же, из того же инвентаря, что сеет обвяз
//  (`Live.insertEquipment`), и той же `WeightLadder.build`: тест сверяет
//  сервер с источником, а не с копией формулы.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Testing
import FitAPI
import FitContent
import FitCore
import PostgresNIO
import Vapor
import VaporTesting
@testable import FitServer

@Suite("20r: вес и проверки подхода (§20.3)", .enabled(if: Live.enabled), .serialized)
struct Test20rSetChecks {

    /// Инвентарь посева обвяза — дословно (`Live.insertEquipment`).
    private let equipment = EquipmentProfile(
        dumbbellsKg: [4, 6, 8, 10, 12, 14, 16, 18, 20, 24, 28, 32], platesKg: [1.25, 2.5, 5, 10, 20],
        barbellKg: 20)
    private let library: ContentLibrary

    init() throws { library = try Content.loadBundled() }

    private func ladder(_ slug: String) throws -> WeightLadder {
        let candidate = try #require(library.candidates.first { $0.slug == slug })
        return WeightLadder.build(loadType: candidate.loadType, profile: equipment)
    }

    private func set(index: Int = 1, kg: Double?, reps: Int? = 8, feedback: Feedback? = .ok,
                     pain: Bool = false, skipped: Bool = false, id: String = UUID().uuidString) -> LogSetRequest {
        LogSetRequest(id: id, setIndex: index, prescribedKg: nil, actualKg: kg, actualReps: reps,
                      feedback: feedback, painFlag: pain, completedAt: "2026-10-08T10:00:00Z",
                      skipped: skipped, day: Live.today)
    }

    private func post(_ app: Application, _ user: Live.User, workout: String, exercise: String,
                      _ body: LogSetRequest) async throws -> (Int, Data) {
        var captured: (Int, Data) = (0, Data())
        try await app.testing().test(
            .POST, "/v1/workouts/\(workout)/exercises/\(exercise)/sets",
            headers: user.headers, beforeRequest: { try $0.content.encode(body) }
        ) { response in
            captured = (Int(response.status.code), Data(buffer: response.body))
        }
        return captured
    }

    private func error(_ raw: Data) throws -> APIErrorEnvelope.Body {
        try JSONDecoder().decode(APIErrorEnvelope.self, from: raw).error
    }

    private func storedKg(_ database: Database, _ user: Live.User, id: String) async throws -> Double? {
        try await database.withUserTransaction(authorization: "Bearer \(user.token)") { tx in
            for try await row in try await tx.query(
                "select actual_kg::float8 from sets where id = \(UUID(uuidString: id)!)") {
                return try row.decode(Double?.self)
            }
            return nil
        }
    }

    /// Первое упражнение с весом и две соседние ступени его лестницы выше 20 кг.
    private func weighted(_ workout: WorkoutDTO) throws -> (WorkoutExerciseDTO, Double, Double) {
        for exercise in workout.exercises where exercise.weighted {
            let ladder = try ladder(exercise.slug)
            guard let low = ladder.nextAchievableWeight(above: 19.99),
                  let high = ladder.nextAchievableWeight(above: low) else { continue }
            return (exercise, low, high)
        }
        throw Live.Failure.seed("в тренировке нет упражнения с весом")
    }

    @Test("20r: вес вне лестницы пишется ближайшей ступенью, при равенстве — нижней, и едет в set")
    func typedWeightIsRoundedToTheNearestRung() async throws {
        let user = try await Live.signUpLinked()
        let logger = Live.quietLogger("20r.round")
        try await Live.withServer("20r.round") { app, database in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            let (exercise, low, high) = try self.weighted(workout)
            let ladder = try self.ladder(exercise.slug)

            // Ближе к верхней ступени.
            let near = high - (high - low) / 4
            let first = self.set(index: 1, kg: near)
            let (status, raw) = try await self.post(app, user, workout: workout.id, exercise: exercise.id, first)
            #expect(status == 200, Comment(rawValue: String(decoding: raw, as: UTF8.self)))
            let response = try JSONDecoder().decode(LogSetResponseDTO.self, from: raw)
            #expect(response.set.actualKg == high, "ответ несёт записанную ступень, а не присланное число")
            #expect(response.set.id == first.id.lowercased())
            #expect(try await self.storedKg(database, user, id: first.id) == high)
            #expect(ladder.roundToAchievable(near, direction: .nearest) == high, "сверка с источником")

            // Ровно посередине — вниз.
            let tie = self.set(index: 2, kg: (low + high) / 2)
            let (tieStatus, tieRaw) = try await self.post(app, user, workout: workout.id, exercise: exercise.id, tie)
            #expect(tieStatus == 200, Comment(rawValue: String(decoding: tieRaw, as: UTF8.self)))
            #expect(try JSONDecoder().decode(LogSetResponseDTO.self, from: tieRaw).set.actualKg == low)
            #expect(try await self.storedKg(database, user, id: tie.id) == low)

            // Ретрай того же подхода тем же числом — тот же ответ, не set_immutable.
            let (retry, retryRaw) = try await self.post(app, user, workout: workout.id, exercise: exercise.id, tie)
            #expect(retry == 200, Comment(rawValue: String(decoding: retryRaw, as: UTF8.self)))
        }
    }

    @Test("20r: дерево следующего подхода строится от записанной ступени")
    func treeStartsFromTheRecordedWeight() async throws {
        let user = try await Live.signUpLinked()
        let logger = Live.quietLogger("20r.tree")
        try await Live.withServer("20r.tree") { app in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            let (exercise, low, high) = try self.weighted(workout)
            let near = low + (high - low) / 4
            let (status, raw) = try await self.post(app, user, workout: workout.id, exercise: exercise.id,
                                                   self.set(index: 1, kg: near, feedback: .ok))
            #expect(status == 200, Comment(rawValue: String(decoding: raw, as: UTF8.self)))
            let tree = try JSONDecoder().decode(LogSetResponseDTO.self, from: raw).decisionTree
            // «ok» вес не меняет (§9.3): корень — записанная ступень, а не присланное число.
            #expect(tree.nodes[tree.start]?.weightKg == low)
        }
    }

    @Test("20r: весовой подход без веса — 422 actual_kg; пропуск и флаг боли — 200")
    func weightedSetRequiresWeight() async throws {
        let user = try await Live.signUpLinked()
        let logger = Live.quietLogger("20r.required")
        try await Live.withServer("20r.required") { app in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            let (exercise, _, _) = try self.weighted(workout)

            let (missing, raw) = try await self.post(app, user, workout: workout.id, exercise: exercise.id,
                                                    self.set(index: 1, kg: nil))
            #expect(missing == 422, Comment(rawValue: String(decoding: raw, as: UTF8.self)))
            #expect(try self.error(raw).code == .validationFailed)
            #expect(try self.error(raw).details?["field"] == .string("actual_kg"))

            let (skip, skipRaw) = try await self.post(app, user, workout: workout.id, exercise: exercise.id,
                                                     self.set(index: 1, kg: nil, reps: nil, feedback: nil, skipped: true))
            #expect(skip == 200, Comment(rawValue: String(decoding: skipRaw, as: UTF8.self)))
            let (pain, painRaw) = try await self.post(app, user, workout: workout.id, exercise: exercise.id,
                                                     self.set(index: 2, kg: nil, reps: 0, feedback: nil, pain: true))
            #expect(pain == 200, Comment(rawValue: String(decoding: painRaw, as: UTF8.self)))
        }
    }

    @Test("20r: повторы, вес и номер вне диапазона — 422 с полем, строки нет")
    func rangesAreRefusedWithTheirField() async throws {
        let user = try await Live.signUpLinked()
        let logger = Live.quietLogger("20r.ranges")
        try await Live.withServer("20r.ranges") { app, database in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            let (exercise, low, _) = try self.weighted(workout)
            let cases: [(LogSetRequest, String)] = [
                (self.set(index: 1, kg: low, reps: 101), "actual_reps"),
                (self.set(index: 1, kg: low, reps: -1), "actual_reps"),
                (self.set(index: 1, kg: 500.5), "actual_kg"),
                (self.set(index: 1, kg: -1), "actual_kg"),
                (self.set(index: 0, kg: low), "set_index"),
                (self.set(index: exercise.targetSets + 3, kg: low), "set_index"),
            ]
            for (body, field) in cases {
                let (status, raw) = try await self.post(app, user, workout: workout.id, exercise: exercise.id, body)
                #expect(status == 422, "\(field): \(String(decoding: raw, as: UTF8.self))")
                #expect(try self.error(raw).details?["field"] == .string(field))
            }
            // Граница включена: номер target_sets + 2 принимается.
            let (edge, edgeRaw) = try await self.post(app, user, workout: workout.id, exercise: exercise.id,
                                                     self.set(index: exercise.targetSets + 2, kg: low, reps: 100))
            #expect(edge == 200, Comment(rawValue: String(decoding: edgeRaw, as: UTF8.self)))
            let count = try await database.withUserTransaction(authorization: "Bearer \(user.token)") { tx in
                for try await row in try await tx.query("select count(*)::int from sets") { return try row.decode(Int.self) }
                return -1
            }
            #expect(count == 1, "отказанные подходы не записаны")
        }
    }

    @Test("20r: второй подход с тем же номером и другим id — set_index_taken с id занявшего")
    func duplicateSetIndexIsTaken() async throws {
        let user = try await Live.signUpLinked()
        let logger = Live.quietLogger("20r.taken")
        try await Live.withServer("20r.taken") { app in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            let (exercise, low, _) = try self.weighted(workout)
            let first = self.set(index: 1, kg: low)
            let (ok, okRaw) = try await self.post(app, user, workout: workout.id, exercise: exercise.id, first)
            #expect(ok == 200, Comment(rawValue: String(decoding: okRaw, as: UTF8.self)))

            let (status, raw) = try await self.post(app, user, workout: workout.id, exercise: exercise.id,
                                                   self.set(index: 1, kg: low))
            #expect(status == 409, Comment(rawValue: String(decoding: raw, as: UTF8.self)))
            #expect(try self.error(raw).code == .setIndexTaken)
            #expect(try self.error(raw).details?["set_id"] == .string(first.id.lowercased()))
        }
    }

    @Test("20r: check'и схемы отклоняют те же значения при записи владельцем базы")
    func schemaChecksRefuseOutOfRange() async throws {
        let user = try await Live.signUpLinked()
        let logger = Live.quietLogger("20r.checks")
        try await Live.withServer("20r.checks") { app in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            let exercise = try #require(workout.exercises.first)
            let client = Live.ownerClient(logger)
            let violations: [String] = [
                "set_index = 0", "actual_reps = 101", "prescribed_reps = 101", "actual_kg = 501", "prescribed_kg = -1",
            ]
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { await client.run() }
                group.addTask {
                    for violation in violations {
                        let column = String(violation.split(separator: " ").first!)
                        let value = String(violation.split(separator: " ").last!)
                        let values: [String: String] = ["set_index": "1", "actual_reps": "8", "prescribed_reps": "8",
                                                        "actual_kg": "20", "prescribed_kg": "20"]
                            .merging([column: value]) { _, new in new }
                        do {
                            _ = try await client.query(PostgresQuery(unsafeSQL: """
                                insert into sets (id, workout_exercise_id, set_index, prescribed_kg, prescribed_reps,
                                                  actual_kg, actual_reps, exercise_slug, is_calibration,
                                                  weight_readiness, performed_on)
                                select gen_random_uuid(), we.id, \(values["set_index"]!), \(values["prescribed_kg"]!),
                                       \(values["prescribed_reps"]!), \(values["actual_kg"]!), \(values["actual_reps"]!),
                                       we.exercise_slug, false, 1.0, current_date
                                  from workout_exercises we where we.id = '\(exercise.id)'
                                """), logger: logger)
                            Issue.record("\(violation) записан")
                        } catch let error as PSQLError {
                            #expect(error.serverInfo?[.sqlState] == "23514", "\(violation): \(String(reflecting: error))")
                        }
                    }
                }
                try await group.next()
                group.cancelAll()
            }
        }
    }

    @Test("20r: неканоническая зона, в том числе с NUL, — 422 tz на /today, /progress и растяжке")
    func nonCanonicalZoneIsRefused() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("20r.tz")
        try await Live.withServer("20r.tz") { app in
            try await Live.seed(app, user, logger: logger)
            let date = Live.today.date
            for tz in ["Europe%2FMoscow%00", "Europe%2FMoscow%00x", "Europe%2FMoscow%20", "Europe%2FMoscow%0A"] {
                for path in ["/v1/today?date=\(date)&tz=\(tz)",
                             "/v1/progress?date=\(date)&tz=\(tz)&from=\(date)&to=\(date)",
                             "/v1/stretch-sessions?date=\(date)&tz=\(tz)"] {
                    try await app.testing().test(.GET, path, headers: user.headers) { response in
                        #expect(response.status == .unprocessableEntity, "\(path): \(String(buffer: response.body))")
                        let body = try JSONDecoder().decode(APIErrorEnvelope.self, from: Data(buffer: response.body))
                        #expect(body.error.details?["field"] == .string("tz"), "\(path)")
                    }
                }
            }
            // `UTC` — законная зона браузера, хотя Foundation зовёт её `GMT`.
            try await app.testing().test(.GET, "/v1/today?date=\(Mapping.LocalTime.iso(Mapping.LocalTime.day(of: Date(), in: TimeZone(identifier: "UTC")!)))&tz=UTC",
                                         headers: user.headers) { response in
                #expect(response.status == .ok, Comment(rawValue: String(buffer: response.body)))
            }
            let start = StartStretchSessionRequest(id: UUID().uuidString, kind: "standalone", templateSlug: "hip_opening",
                                                   day: DayContext(date: date, tz: "Europe/Moscow\u{0}"))
            try await app.testing().test(.POST, "/v1/stretch-sessions", headers: user.headers,
                                         beforeRequest: { try $0.content.encode(start) }) { response in
                #expect(response.status == .unprocessableEntity, Comment(rawValue: String(buffer: response.body)))
            }
        }
    }
}
