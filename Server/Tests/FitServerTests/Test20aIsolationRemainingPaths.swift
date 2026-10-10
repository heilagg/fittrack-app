//  Тест 20a (§20.15) на путях, которых недельный набор не касается:
//  `/today`, `/preview`, `GET`/`PATCH /profile`, `POST …/sets`, `/substitute`.
//  Остальные пути проверены там, где написаны (недельные — в
//  `Test20aIsolationOverHTTP`, тренировочные — в своих наборах).
//
//  Утверждение каждого теста двустороннее: Боб не видит строк Алисы И строки
//  Алисы после его запроса не изменились. Отказ без проверки строки был бы
//  отказом только на словах.
//
//  Отдельно — подход с клиентским `id` подхода Алисы. Upsert по `id` (§20.6) —
//  единственное место, где запрос Боба адресует чужую строку напрямую, по
//  ключу, а не через путь.

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

@Suite("20a: изоляция на остальных путях (§20.15)", .enabled(if: Live.enabled), .serialized)
struct Test20aIsolationRemainingPaths {

    private var today: CalendarDay {
        Mapping.LocalTime.day(of: Date(), in: TimeZone(identifier: "Europe/Moscow")!)
    }
    private var weekStart: String { Mapping.LocalTime.iso(Mapping.LocalTime.mondayOfWeek(today)) }
    private var query: String { "date=\(Live.today.date)&tz=Europe%2FMoscow" }

    private func call(_ app: Application, _ method: HTTPMethod, _ path: String,
                      _ user: Live.User) async throws -> (Int, Data) {
        var captured: (Int, Data) = (0, Data())
        try await app.testing().test(method, path, headers: user.headers) {
            captured = (Int($0.status.code), Data(buffer: $0.body))
        }
        return captured
    }

    private func call<B: Vapor.Content>(_ app: Application, _ method: HTTPMethod, _ path: String,
                                        _ user: Live.User, body: B) async throws -> (Int, Data) {
        var captured: (Int, Data) = (0, Data())
        try await app.testing().test(method, path, headers: user.headers,
                                     beforeRequest: { try $0.content.encode(body) }) {
            captured = (Int($0.status.code), Data(buffer: $0.body))
        }
        return captured
    }

    private func sql<T: Sendable>(_ database: Database, _ user: Live.User,
                                  _ body: @escaping @Sendable (UserTransaction) async throws -> T)
        async throws -> T {
        try await database.withUserTransaction(authorization: "Bearer \(user.token)", body)
    }

    private func code(_ raw: Data) -> APIErrorCode? {
        try? JSONDecoder().decode(APIErrorEnvelope.self, from: raw).error.code
    }

    // MARK: - /today и /preview

    @Test("20a: /today и /preview Боба не несут дней Алисы")
    func test20a_todayAndPreview() async throws {
        let alice = try await Live.signUpAnonymous()
        let bob = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("test.20a.today")
        try await Live.withServer("test.20a.today") { app in
            let workout = try await Live.startedWorkout(app, alice, logger: logger)
            let aliceDay = try #require(workout.plannedDayID)
            try await Live.seed(app, bob, logger: logger) // профиль есть, недели нет

            // Контроль: у Алисы день виден, иначе отсутствие у Боба ничего не значит.
            let (own, ownRaw) = try await self.call(app, .GET, "/v1/today?\(self.query)", alice)
            #expect(own == 200)
            #expect(try JSONDecoder().decode(TodayCardDTO.self, from: ownRaw).day.dayID == aliceDay)

            let (status, raw) = try await self.call(app, .GET, "/v1/today?\(self.query)", bob)
            #expect(status == 200)
            let card = try JSONDecoder().decode(TodayCardDTO.self, from: raw)
            #expect(card.day.dayID == nil, "у Боба недели нет — день Алисы попал в его карточку")
            #expect(!String(decoding: raw, as: UTF8.self).contains(aliceDay))

            let preview = "/v1/week-plans/\(self.weekStart)/preview?\(self.query)&day=\(Live.today.date)"
            let (ownPreview, ownPreviewRaw) = try await self.call(app, .GET, preview, alice)
            #expect(ownPreview == 200)
            #expect(String(decoding: ownPreviewRaw, as: UTF8.self).contains(aliceDay))
            let (pStatus, pRaw) = try await self.call(app, .GET, preview, bob)
            #expect(pStatus == 200)
            let plan = try JSONDecoder().decode(WeekPlanResponseDTO.self, from: pRaw)
            #expect(plan.plan.days.isEmpty, "у Боба недели нет — срез не пуст")
            #expect(!String(decoding: pRaw, as: UTF8.self).contains(aliceDay))
        }
    }

    // MARK: - /profile

    @Test("20a: GET /profile Боба — не профиль Алисы; PATCH Боба не трогает её профиль")
    func test20a_profile() async throws {
        let alice = try await Live.signUpAnonymous()
        let bob = try await Live.signUpAnonymous()
        try await Live.withServer("test.20a.profile") { app in
            let (a, _) = try await self.call(app, .PATCH, "/v1/profile", alice,
                                              body: PatchProfileRequest(birthYear: .some(1981),
                                                                        heightCm: .some(181)))
            #expect(a == 200)
            // Боб без строки профиля: 404 «онбординг не начат», а не профиль Алисы.
            let (b, raw) = try await self.call(app, .GET, "/v1/profile", bob)
            #expect(b == 404, Comment(rawValue: String(decoding: raw, as: UTF8.self)))
            #expect(!String(decoding: raw, as: UTF8.self).contains("1981"))

            let (p, _) = try await self.call(app, .PATCH, "/v1/profile", bob,
                                              body: PatchProfileRequest(birthYear: .some(1999),
                                                                        heightCm: .some(160)))
            #expect(p == 200)
            let (_, bobRaw) = try await self.call(app, .GET, "/v1/profile", bob)
            let bobProfile = try JSONDecoder().decode(ProfileDTO.self, from: bobRaw)
            #expect(bobProfile.birthYear == 1999 && bobProfile.heightCm == 160,
                    "Боб читает не свой профиль")
            let (_, aliceRaw) = try await self.call(app, .GET, "/v1/profile", alice)
            let aliceProfile = try JSONDecoder().decode(ProfileDTO.self, from: aliceRaw)
            #expect(aliceProfile.birthYear == 1981 && aliceProfile.heightCm == 181,
                    "PATCH Боба изменил профиль Алисы")
        }
    }

    // MARK: - POST …/sets

    @Test("20a: подход в тренировку Алисы и подход с id подхода Алисы — её строки целы")
    func test20a_sets() async throws {
        let alice = try await Live.signUpAnonymous()
        let bob = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("test.20a.sets")
        try await Live.withServer("test.20a.sets") { app, database in
            let aliceWorkout = try await Live.startedWorkout(app, alice, logger: logger)
            let aliceExercise = try #require(aliceWorkout.exercises.first)
            let aliceSetID = UUID().uuidString
            let aliceSet = LogSetRequest(id: aliceSetID, setIndex: 1, prescribedKg: 10, actualKg: 10,
                                         actualReps: 10, feedback: .ok,
                                         completedAt: "2026-10-08T10:00:00Z", day: Live.today)
            let path = "/v1/workouts/\(aliceWorkout.id)/exercises/\(aliceExercise.id)/sets"
            let (own, _) = try await self.call(app, .POST, path, alice, body: aliceSet)
            #expect(own == 200)

            // 1. Боб пишет в тренировку Алисы: для него её нет.
            var foreign = aliceSet
            foreign.id = UUID().uuidString
            foreign.setIndex = 2
            let (s1, raw1) = try await self.call(app, .POST, path, bob, body: foreign)
            #expect(s1 == 409)
            #expect(self.code(raw1) == .workoutNotStarted)

            // 2. Боб пишет в СВОЮ тренировку, но с id подхода Алисы и другими
            //    значениями.
            let bobWorkout = try await Live.startedWorkout(app, bob, logger: logger)
            let bobExercise = try #require(bobWorkout.exercises.first)
            var collision = aliceSet
            collision.actualKg = 99
            collision.actualReps = 1
            collision.feedback = .failed
            let (s2, raw2) = try await self.call(
                app, .POST, "/v1/workouts/\(bobWorkout.id)/exercises/\(bobExercise.id)/sets", bob,
                body: collision)
            // Точный код здесь SPEC не задаёт: сейчас это 500 — upsert натыкается
            // на строку, которую RLS не показывает, и Postgres отказывает. Утечки
            // нет (строки Алисы проверены ниже), но код — открытый вопрос, и тест
            // его не закрепляет.
            #expect(s2 != 200, Comment(rawValue: "чужой id принят: \(String(decoding: raw2, as: UTF8.self))"))

            // Строки Алисы: ровно одна, с её значениями.
            let rows = try await self.sql(database, alice) { tx -> [(Double?, Int?, String?)] in
                var out: [(Double?, Int?, String?)] = []
                for try await row in try await tx.query(
                    "select actual_kg::float8, actual_reps, feedback from sets") {
                    out.append(try row.decode((Double?, Int?, String?).self))
                }
                return out
            }
            #expect(rows.count == 1, "у Алисы появился чужой подход")
            #expect(rows.first?.0 == 10 && rows.first?.1 == 10 && rows.first?.2 == "ok",
                    "подход Алисы изменён запросом Боба")
        }
    }

    // MARK: - /substitute

    @Test("20a: замена в тренировке Алисы — 409 workout_not_started, её строка цела")
    func test20a_substitute() async throws {
        let alice = try await Live.signUpAnonymous()
        let bob = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("test.20a.substitute")
        try await Live.withServer("test.20a.substitute") { app, database in
            let workout = try await Live.startedWorkout(app, alice, logger: logger)
            let exercise = try #require(workout.exercises.first)
            let library = try FitContent.Content.loadBundled()
            let target = try #require(library.candidates.first { $0.slug == exercise.slug }?
                .alternatives.first)
            let body = SubstituteExerciseRequest(toSlug: target, reason: .userChoice, day: Live.today)
            let (status, raw) = try await self.call(
                app, .POST, "/v1/workouts/\(workout.id)/exercises/\(exercise.id)/substitute",
                bob, body: body)
            #expect(status == 409)
            #expect(self.code(raw) == .workoutNotStarted)
            let slug = try await self.sql(database, alice) { tx -> String? in
                for try await row in try await tx.query(
                    "select exercise_slug from workout_exercises where id = \(UUID(uuidString: exercise.id)!)") {
                    return try row.decode(String.self)
                }
                return nil
            }
            #expect(slug == exercise.slug, "Боб заменил упражнение Алисы")
        }
    }
}
