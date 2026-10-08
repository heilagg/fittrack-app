//  Тесты 20e, 20f и 20g (§20.15) — запись подхода через HTTP.
//
//  Одним файлом, как 20a/20d/20j: у всех трёх один фикстур (начатая
//  тренировка), и разнесённые по файлам они повторили бы его трижды. Номера
//  §20.15 при этом свои у каждого, и в именах тестов они стоят.
//
//    20e. Ретрай с тем же клиентским `id` применяется upsert'ом в ту же строку:
//         второй не появляется, а `exercise_states` после повтора равны тем, что
//         дала бы одиночная отправка. Отдельно — тело без `id` отклоняется, а не
//         получает ключ от сервера.
//    20f. Изменение подхода с непустым `completed_at` → отказ (§4.3).
//    20g. Логирование подхода двигает `sync_seq` родительской `workouts`;
//         идемпотентный ретрай — НЕ двигает, потому что триггер обновления
//         снабжён условием `old.* is distinct from new.*`.
//
//  `muscle_fatigue` в 20e не проверяется и проверяться здесь не может: §20.6
//  считает её один раз, на `/finish`, и до него она законно отстаёт от журнала.
//  Эта половина 20e переезжает в тест завершения.
//
//  Граница 20e и 20f — ровно в том, что ретрай с ТЕМИ ЖЕ значениями отказом не
//  является, хотя подход и завершён. Иначе клиент, потерявший ответ, не доедет
//  никогда, и §20.6 называет это прямо. Поэтому сверка идёт по значениям, а не
//  по факту «строка уже есть».

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

@Suite("20e/20f/20g: запись подхода (§20.15)", .enabled(if: Live.enabled), .serialized)
struct Test20efgSetWrites {

    /// Завершённый подход: `completed_at` непуст — именно это делает его
    /// иммутабельным по §4.3.
    private func set(_ id: String, index: Int = 1, kg: Double? = 10, reps: Int = 10,
                     feedback: Feedback? = .ok) -> LogSetRequest {
        LogSetRequest(id: id, setIndex: index, prescribedKg: kg, actualKg: kg, actualReps: reps,
                      feedback: feedback, completedAt: "2026-10-08T10:00:00Z", day: Live.today)
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

    /// Сырое тело — чтобы отправить запрос БЕЗ ключа `id`, чего типизированный
    /// `LogSetRequest` выразить не может: поле у него обязательное.
    private func postRaw(_ app: Application, _ user: Live.User, workout: String,
                         exercise: String, json: String) async throws -> (Int, Data) {
        var captured: (Int, Data) = (0, Data())
        try await app.testing().test(
            .POST, "/v1/workouts/\(workout)/exercises/\(exercise)/sets",
            headers: user.headers,
            beforeRequest: { request in
                request.headers.contentType = .json
                request.body = ByteBuffer(string: json)
            }
        ) { response in
            captured = (Int(response.status.code), Data(buffer: response.body))
        }
        return captured
    }

    private func states(_ database: Database, _ user: Live.User) async throws -> [String: String] {
        try await database.withUserTransaction(authorization: "Bearer \(user.token)") { tx in
            var result: [String: String] = [:]
            let rows = try await tx.query("""
                select exercise_slug, baseline_kg::text, rep_extension, extra_sets_added,
                       stall_count, last_performed_at::text, in_calibration
                  from exercise_states
                """)
            for try await row in rows {
                let (slug, baseline, ext, extra, stall, last, calibration) =
                    try row.decode((String, String?, Int, Int, Int, String?, Bool).self)
                result[slug] = "\(baseline ?? "nil")|\(ext)|\(extra)|\(stall)|"
                    + "\(last ?? "nil")|\(calibration)"
            }
            return result
        }
    }

    private func setCount(_ database: Database, _ user: Live.User) async throws -> Int {
        try await database.withUserTransaction(authorization: "Bearer \(user.token)") { tx in
            let rows = try await tx.query("select count(*)::int from sets")
            for try await row in rows { return try row.decode(Int.self) }
            return -1
        }
    }

    private func syncSeq(_ database: Database, _ user: Live.User,
                         workout: String) async throws -> Int64 {
        try await database.withUserTransaction(authorization: "Bearer \(user.token)") { tx in
            let rows = try await tx.query("""
                select sync_seq from workouts where id = \(UUID(uuidString: workout)!)
                """)
            for try await row in rows { return try row.decode(Int64.self) }
            return -1
        }
    }

    // MARK: - 20e. Идемпотентность по клиентскому `id`

    @Test("20e: ретрай с тем же id не создаёт второй строки и не двигает состояния")
    func test20e_retryIsIdempotent() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("test.20e")

        try await Live.withServer("test.20e") { app, database in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            let exercise = try #require(workout.exercises.first)
            let body = self.set(UUID().uuidString)

            let (first, firstBody) = try await self.post(app, user, workout: workout.id,
                                                         exercise: exercise.id, body)
            #expect(first == 200, Comment(rawValue: String(decoding: firstBody, as: UTF8.self)))
            let afterOne = try await self.states(database, user)
            #expect(try await self.setCount(database, user) == 1)

            // Тот же `id`, те же значения — второе нажатие той же кнопки.
            let (second, secondBody) = try await self.post(app, user, workout: workout.id,
                                                           exercise: exercise.id, body)
            #expect(second == 200, Comment(rawValue: String(decoding: secondBody, as: UTF8.self)))
            #expect(try await self.setCount(database, user) == 1, "появилась вторая строка")
            #expect(try await self.states(database, user) == afterOne,
                    "состояния после повтора отличаются от одиночной отправки")
        }
    }

    @Test("20e: тело без id отклоняется с set_id_required, а не получает ключ от сервера")
    func test20e_missingIdIsRefused() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("test.20e.noid")

        try await Live.withServer("test.20e.noid") { app, database in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            let exercise = try #require(workout.exercises.first)

            let json = """
                {"set_index":1,"actual_kg":10,"actual_reps":10,"feedback":"ok",
                 "pain_flag":false,"skipped":false,"completed_at":"2026-10-08T10:00:00Z",
                 "date":"\(Live.today.date)","tz":"\(Live.today.tz)"}
                """
            let (status, raw) = try await self.postRaw(app, user, workout: workout.id,
                                                       exercise: exercise.id, json: json)
            #expect(status == 422, Comment(rawValue: String(decoding: raw, as: UTF8.self)))
            let envelope = try JSONDecoder().decode(APIErrorEnvelope.self, from: raw)
            #expect(envelope.error.code == .setIDRequired,
                    "без ключа ретрай от нового подхода не отличить — код обязан быть свой")
            #expect(try await self.setCount(database, user) == 0, "строка не появилась")
        }
    }

    // MARK: - 20f. Иммутабельность завершённого подхода (§4.3)

    @Test("20f: изменение подхода с непустым completed_at отклоняется")
    func test20f_completedSetIsImmutable() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("test.20f")

        try await Live.withServer("test.20f") { app, database in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            let exercise = try #require(workout.exercises.first)
            let id = UUID().uuidString

            let (first, _) = try await self.post(app, user, workout: workout.id,
                                                 exercise: exercise.id, self.set(id))
            #expect(first == 200)

            // Тот же `id`, ДРУГИЕ повторы — это изменение завершённого подхода.
            let (status, raw) = try await self.post(app, user, workout: workout.id,
                                                    exercise: exercise.id,
                                                    self.set(id, reps: 12))
            #expect(status == 409, Comment(rawValue: String(decoding: raw, as: UTF8.self)))
            let envelope = try JSONDecoder().decode(APIErrorEnvelope.self, from: raw)
            #expect(envelope.error.code == .setImmutable)

            // А ретрай с ТЕМИ ЖЕ значениями отказом не является, хотя подход
            // завершён: иначе потерявший ответ клиент не доедет (§20.6).
            let (retry, retryBody) = try await self.post(app, user, workout: workout.id,
                                                         exercise: exercise.id, self.set(id))
            #expect(retry == 200, Comment(rawValue: String(decoding: retryBody, as: UTF8.self)))

            // И тот же МОМЕНТ, записанный в другой зоне, — тоже ретрай, а не
            // изменение. Это то, ради чего сверка идёт в SQL по `timestamptz`:
            // сравнение строк объявило бы «13:00+03:00» изменением «10:00Z», и
            // 20f отказал бы там, где отказывать нельзя.
            var otherZone = self.set(id)
            otherZone.completedAt = "2026-10-08T13:00:00+03:00"
            let (same, sameBody) = try await self.post(app, user, workout: workout.id,
                                                       exercise: exercise.id, otherZone)
            #expect(same == 200, Comment(rawValue: String(decoding: sameBody, as: UTF8.self)))

            // А другой момент — изменение, и он отклоняется.
            var otherMoment = self.set(id)
            otherMoment.completedAt = "2026-10-08T11:00:00Z"
            let (moved, _) = try await self.post(app, user, workout: workout.id,
                                                 exercise: exercise.id, otherMoment)
            #expect(moved == 409, "сдвинутый на час completed_at — изменение завершённого подхода")
        }
    }

    // MARK: - 20g. Курсор синхронизации (§3.1, §4.3)

    @Test("20g: подход двигает sync_seq тренировки, идемпотентный ретрай — нет")
    func test20g_syncSeqMovesOnlyOnRealChange() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("test.20g")

        try await Live.withServer("test.20g") { app, database in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            let exercise = try #require(workout.exercises.first)
            let before = try await self.syncSeq(database, user, workout: workout.id)
            let id = UUID().uuidString

            let (first, _) = try await self.post(app, user, workout: workout.id,
                                                 exercise: exercise.id, self.set(id))
            #expect(first == 200)
            let afterInsert = try await self.syncSeq(database, user, workout: workout.id)
            #expect(afterInsert > before,
                    "вставка подхода не сдвинула курсор родительской workouts (§3.1)")

            // Ретрай тем же `id` и теми же значениями: курсор НЕ двигается,
            // иначе pull отдавал бы страницу, в которой ничего не изменилось.
            let (second, _) = try await self.post(app, user, workout: workout.id,
                                                  exercise: exercise.id, self.set(id))
            #expect(second == 200)
            #expect(try await self.syncSeq(database, user, workout: workout.id) == afterInsert,
                    """
                    идемпотентный ретрай сдвинул курсор — условие \
                    `old.* is distinct from new.*` не работает
                    """)

            // Настоящее изменение — двигает. Берём НЕзавершённый подход, потому
            // что завершённый менять запрещает 20f.
            let open = LogSetRequest(id: UUID().uuidString, setIndex: 2, prescribedKg: 10,
                                     actualKg: 10, actualReps: 10, feedback: .ok,
                                     completedAt: nil, day: Live.today)
            let (third, _) = try await self.post(app, user, workout: workout.id,
                                                 exercise: exercise.id, open)
            #expect(third == 200)
            let afterOpen = try await self.syncSeq(database, user, workout: workout.id)

            var changed = open
            changed.actualReps = 11
            let (fourth, raw) = try await self.post(app, user, workout: workout.id,
                                                   exercise: exercise.id, changed)
            #expect(fourth == 200, Comment(rawValue: String(decoding: raw, as: UTF8.self)))
            #expect(try await self.syncSeq(database, user, workout: workout.id) > afterOpen,
                    "настоящее изменение строки курсор не сдвинуло")
        }
    }
}
