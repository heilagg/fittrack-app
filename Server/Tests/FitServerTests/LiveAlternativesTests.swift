//  `GET /v1/workouts/{id}/exercises/{we_id}/alternatives` через HTTP против
//  живой базы (SPEC §8.4 п.2, §13.4, §20.3).
//
//  Проверяется то, что путь решает сам, а не отбор FitCore (он покрыт в
//  `FitCoreTests`):
//
//    — `purpose=pain` берёт суставы из `sets.pain_joints` и сужает список;
//      без флага боли вырождается в `user_choice`, а не отказывает;
//    — `purpose` вне словаря, пропущенные `date`/`tz`, перекос часов — 422;
//    — чужие и несуществующие `id`/`we_id` — 404, завершённая тренировка — 200;
//    — инвентарь берётся у ТРЕНИРОВКИ, а не у умолчания аккаунта.
//
//  Каждое утверждение о сужении привязано к тому, что без него список был бы
//  другим: тест, который проходит и на пути, игнорирующем `purpose` или
//  инвентарь, слеп. Поэтому условия вида «хотя бы у одного упражнения списки
//  различаются» стоят `#require`, а не `#expect`.

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

@Suite("GET …/alternatives: замена и боль (§20.3)", .enabled(if: Live.enabled), .serialized)
struct LiveAlternativesTests {

    private func get(_ app: Application, _ user: Live.User, workout: String, exercise: String,
                     query: String? = nil, headers: HTTPHeaders? = nil) async throws -> (Int, Data) {
        let day = Live.today
        let q = query ?? "date=\(day.date)&tz=\(day.tz)"
        var captured: (Int, Data) = (0, Data())
        try await app.testing().test(
            .GET, "/v1/workouts/\(workout)/exercises/\(exercise)/alternatives?\(q)",
            headers: headers ?? user.headers
        ) { response in
            captured = (Int(response.status.code), Data(buffer: response.body))
        }
        return captured
    }

    private func slugs(_ app: Application, _ user: Live.User, workout: String, exercise: String,
                       purpose: String? = nil) async throws -> [String] {
        let day = Live.today
        var query = "date=\(day.date)&tz=\(day.tz)"
        if let purpose { query += "&purpose=\(purpose)" }
        let (status, body) = try await get(app, user, workout: workout, exercise: exercise,
                                           query: query)
        #expect(status == 200, Comment(rawValue: String(decoding: body, as: UTF8.self)))
        return try JSONDecoder().decode([ExerciseAlternativeDTO].self, from: body).map(\.slug)
    }

    private func logPain(_ app: Application, _ user: Live.User, workout: String,
                         exercise: String) async throws {
        let body = LogSetRequest(id: UUID().uuidString, setIndex: 1, prescribedKg: nil,
                                 actualKg: nil, actualReps: nil, feedback: nil, painFlag: true,
                                 completedAt: "2026-10-08T10:00:00Z", day: Live.today)
        try await app.testing().test(
            .POST, "/v1/workouts/\(workout)/exercises/\(exercise)/sets",
            headers: user.headers, beforeRequest: { try $0.content.encode(body) }
        ) { response in
            #expect(response.status == .ok, Comment(rawValue: String(buffer: response.body)))
        }
    }

    // MARK: - purpose

    @Test("pain сужает список по суставам флага и строго разгружает их; без purpose — user_choice")
    func painNarrowsAndDefaultsToUserChoice() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("alternatives.purpose")
        let library = try Content.loadBundled()
        let bySlug = Dictionary(library.candidates.map { ($0.slug, $0) },
                                uniquingKeysWith: { first, _ in first })

        try await Live.withServer("alternatives.purpose") { app in
            let workout = try await Live.startedWorkout(app, user, logger: logger)

            var narrowedSomewhere = false
            for exercise in workout.exercises {
                let source = try #require(bySlug[exercise.slug])
                let byDefault = try await self.slugs(app, user, workout: workout.id,
                                                     exercise: exercise.id)
                let explicit = try await self.slugs(app, user, workout: workout.id,
                                                    exercise: exercise.id, purpose: "user_choice")
                #expect(byDefault == explicit, "умолчание — user_choice")
                // Флага боли ещё нет: pain вырождается, а не отказывает.
                let degenerate = try await self.slugs(app, user, workout: workout.id,
                                                      exercise: exercise.id, purpose: "pain")
                #expect(degenerate == explicit, "без флага боли суставов нет, список не сужается")

                try await self.logPain(app, user, workout: workout.id, exercise: exercise.id)
                let userChoice = try await self.slugs(app, user, workout: workout.id,
                                                      exercise: exercise.id, purpose: "user_choice")
                let pain = try await self.slugs(app, user, workout: workout.id,
                                                exercise: exercise.id, purpose: "pain")

                let joints = Recovery.painJoints(from: source.jointStress)
                for slug in pain {
                    let candidate = try #require(bySlug[slug])
                    for joint in joints {
                        let after = candidate.jointStress[joint] ?? .none
                        let before = source.jointStress[joint] ?? .none
                        #expect(after < before, "\(slug) не разгружает \(joint) строго")
                    }
                }
                #expect(Set(pain).isSubset(of: Set(userChoice)))
                if Set(pain) != Set(userChoice) { narrowedSomewhere = true }
            }
            // Без этого тест прошёл бы и на пути, который игнорирует `purpose`.
            try #require(narrowedSomewhere, "ни у одного упражнения pain не отличился от user_choice")
        }
    }

    @Test("purpose вне словаря — 422 validation_failed с полем")
    func unknownPurposeIsRejected() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("alternatives.badpurpose")
        try await Live.withServer("alternatives.badpurpose") { app in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            let exercise = try #require(workout.exercises.first)
            let day = Live.today
            let (status, body) = try await self.get(
                app, user, workout: workout.id, exercise: exercise.id,
                query: "date=\(day.date)&tz=\(day.tz)&purpose=whatever")
            #expect(status == 422)
            #expect(String(decoding: body, as: UTF8.self).contains("validation_failed"))
            #expect(String(decoding: body, as: UTF8.self).contains("purpose"))
        }
    }

    // MARK: - date и tz

    @Test("без date или tz — 422, перекос часов — date_skew")
    func dayIsRequiredAndSkewChecked() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("alternatives.day")
        try await Live.withServer("alternatives.day") { app in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            let exercise = try #require(workout.exercises.first)
            let day = Live.today

            let (noDate, _) = try await self.get(app, user, workout: workout.id,
                                                 exercise: exercise.id, query: "tz=\(day.tz)")
            #expect(noDate == 422)
            let (noTz, _) = try await self.get(app, user, workout: workout.id,
                                               exercise: exercise.id, query: "date=\(day.date)")
            #expect(noTz == 422)
            let (skew, body) = try await self.get(
                app, user, workout: workout.id, exercise: exercise.id,
                query: "date=2000-01-01&tz=\(day.tz)")
            #expect(skew == 422)
            #expect(String(decoding: body, as: UTF8.self).contains("date_skew"))
        }
    }

    // MARK: - Адресация

    @Test("чужая тренировка, чужой и несуществующий we_id — 404")
    func foreignAndMissingIdsAreNotFound() async throws {
        let alice = try await Live.signUpAnonymous()
        let bob = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("alternatives.notfound")
        try await Live.withServer("alternatives.notfound") { app in
            let workout = try await Live.startedWorkout(app, alice, logger: logger)
            let exercise = try #require(workout.exercises.first)

            let (foreign, _) = try await self.get(app, bob, workout: workout.id,
                                                  exercise: exercise.id)
            #expect(foreign == 404, "чужую тренировку RLS не отдаёт")
            let (missingWorkout, _) = try await self.get(app, alice, workout: UUID().uuidString,
                                                         exercise: exercise.id)
            #expect(missingWorkout == 404)
            let (missingExercise, _) = try await self.get(app, alice, workout: workout.id,
                                                          exercise: UUID().uuidString)
            #expect(missingExercise == 404)
        }
    }

    @Test("we_id другой тренировки той же пользовательницы — 404: RLS этого не ловит")
    func exerciseOfAnotherOwnWorkoutIsNotFound() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("alternatives.ownother")
        try await Live.withServer("alternatives.ownother") { app, database in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            let exercise = try #require(workout.exercises.first)
            let owner = try #require(UUID(uuidString: user.id.uuidString))
            let otherWorkout = UUID(), otherExercise = UUID()
            try await database.withUserTransaction(authorization: "Bearer \(user.token)") { tx -> Void in
                try await tx.query("""
                    insert into workouts (id, user_id, started_at, session_kind, readiness)
                    values (\(otherWorkout), \(owner), now(), 'full_body', 1.0)
                    """)
                try await tx.query("""
                    insert into workout_exercises (id, workout_id, exercise_slug, order_index,
                        target_sets, target_rep_min, target_rep_max, target_rir, weight_readiness)
                    values (\(otherExercise), \(otherWorkout), \(exercise.slug), 0, 3, 8, 12, 2, 1.0)
                    """)
            }
            // Строка существует и видна RLS — отказать может только сверка с путём.
            let (status, _) = try await self.get(app, user, workout: workout.id,
                                                 exercise: otherExercise.uuidString)
            #expect(status == 404)
            let (own, _) = try await self.get(app, user, workout: otherWorkout.uuidString,
                                              exercise: otherExercise.uuidString)
            #expect(own == 200, "контроль: та же строка по своему пути отдаётся")
        }
    }

    @Test("завершённая тренировка отвечает 200: список ничего не меняет")
    func finishedWorkoutStillAnswers() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("alternatives.finished")
        try await Live.withServer("alternatives.finished") { app, database in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            let exercise = try #require(workout.exercises.first)
            let open = try await self.slugs(app, user, workout: workout.id, exercise: exercise.id)

            let id = try #require(UUID(uuidString: workout.id))
            try await database.withUserTransaction(authorization: "Bearer \(user.token)") { tx -> Void in
                try await tx.query("update workouts set finished_at = now() where id = \(id)")
            }
            let closed = try await self.slugs(app, user, workout: workout.id, exercise: exercise.id)
            #expect(closed == open)
        }
    }

    // MARK: - Инвентарь тренировки

    @Test("инвентарь — профиль самой тренировки, а не умолчание аккаунта")
    func usesTheWorkoutsEquipmentProfile() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("alternatives.equipment")
        try await Live.withServer("alternatives.equipment") { app, database in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            var before: [String: [String]] = [:]
            for exercise in workout.exercises {
                before[exercise.id] = try await self.slugs(app, user, workout: workout.id,
                                                           exercise: exercise.id)
            }

            // Пустой инвентарь, НЕ умолчание, прикреплённый к тренировке.
            let bare = UUID()
            let id = try #require(UUID(uuidString: workout.id))
            let owner = try #require(UUID(uuidString: user.id.uuidString))
            try await database.withUserTransaction(authorization: "Bearer \(user.token)") { tx -> Void in
                try await tx.query("""
                    insert into equipment_profiles (id, user_id, name, is_default)
                    values (\(bare), \(owner), 'Пусто', false)
                    """)
                try await tx.query("""
                    update workouts set equipment_profile_id = \(bare) where id = \(id)
                    """)
            }

            var changed = false
            for exercise in workout.exercises {
                let after = try await self.slugs(app, user, workout: workout.id,
                                                 exercise: exercise.id)
                #expect(Set(after).isSubset(of: Set(before[exercise.id] ?? [])))
                if after != before[exercise.id] { changed = true }
            }
            try #require(changed, "список не изменился — путь читает умолчание, а не инвентарь тренировки")
        }
    }
}
