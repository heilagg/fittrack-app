//  Снимок упражнения на подходе (SPEC §3.1, §20.6; миграция 0012).
//
//  Строка `workout_exercises` меняется на месте — так её поменяет замена
//  упражнения (§20.3), — и после этого журнал обязан видеть подход таким, каким
//  он был: прежний слаг, прежняя калибровка, прежняя готовность. Отдельно —
//  ретрай того же подхода после смены строки снимок не перезаписывает.
//
//  Строка меняется прямым SQL, а не через `/substitute`: свойство принадлежит
//  журналу, и проверять его нужно независимо от того, какой путь строку
//  поменяет.

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

@Suite("Снимок упражнения на подходе (§3.1, §20.6)", .enabled(if: Live.enabled), .serialized)
struct LiveSetSnapshotTests {

    @Test("после смены строки упражнения журнал видит подход прежним, ретрай снимок не трогает")
    func snapshotSurvivesRowChange() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("set.snapshot")
        try await Live.withServer("set.snapshot") { app, database in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            let exercise = try #require(workout.exercises.first)
            let weID = try #require(UUID(uuidString: exercise.id))
            let setID = UUID().uuidString
            let body = LogSetRequest(id: setID, setIndex: 1, prescribedKg: exercise.prescribedKg,
                                     actualKg: exercise.prescribedKg,
                                     actualReps: exercise.targetRepMin, feedback: .ok,
                                     completedAt: "2026-10-08T10:00:00Z", day: Live.today)
            let post = { @Sendable () async throws in
                try await app.testing().test(
                    .POST, "/v1/workouts/\(workout.id)/exercises/\(exercise.id)/sets",
                    headers: user.headers, beforeRequest: { try $0.content.encode(body) }
                ) { #expect($0.status == .ok, Comment(rawValue: String(buffer: $0.body))) }
            }
            try await post()

            // Строка теперь описывает ДРУГОЕ упражнение, с другой калибровкой и
            // другой готовностью — ровно то, что сделает замена.
            let otherSlug = "snapshot_other_slug"
            try await database.withUserTransaction(authorization: "Bearer \(user.token)") { tx -> Void in
                try await tx.query("""
                    update workout_exercises
                       set exercise_slug = \(otherSlug), is_calibration = not is_calibration,
                           weight_readiness = 0.777
                     where id = \(weID)
                    """)
            }
            // Ретрай того же подхода ПОСЛЕ смены строки: 200 и снимок прежний.
            try await post()

            let zone = TimeZone(identifier: "Europe/Moscow")!
            let (journal, workoutSets) = try await database.withUserTransaction(
                authorization: "Bearer \(user.token)") { tx in
                (try await Mapping.readSets(tx, since: nil, timeZone: zone),
                 try await Mapping.readWorkoutSets(tx, workoutID: UUID(uuidString: workout.id)!))
            }
            let row = try #require(journal.first, "подход пропал из журнала")
            #expect(journal.count == 1, "ретрай создал вторую строку")
            #expect(row.exerciseSlug == exercise.slug, "журнал приписал подход новому слагу")
            #expect(row.isCalibration == exercise.isCalibration, "калибровка взята у новой строки")
            #expect(abs(row.weightReadiness - exercise.weightReadiness) < 1e-9,
                    "готовность взята у новой строки")
            let local = try #require(workoutSets.journal[exercise.id]?.first)
            #expect(local.exerciseSlug == exercise.slug)
            #expect(local.isCalibration == exercise.isCalibration)
        }
    }
}
