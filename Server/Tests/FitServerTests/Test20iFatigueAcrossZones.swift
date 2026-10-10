//  Тест 20i (§20.15): утомление, записанное в одной зоне и прочитанное в
//  другой, даёт тот же распад (§20.7).
//
//  Метка `muscle_fatigue.updated_at` — показания местных часов в зоне ЗАПИСИ, и
//  при чтении она больше не переводится. Проверяются обе половины:
//
//    — запись: тренировка А закрыта с зоной Токио, метка — токийское местное
//      время её подхода;
//    — чтение: тренировка Б закрыта с зоной Нью-Йорка, и `/finish` применяет
//      её подход ПОВЕРХ прочитанной токийской метки. Ожидание — прямые вызовы
//      `Recovery.applying` с метками «Токио для А» и «Нью-Йорк для Б».
//
//  Метка, переведённая при чтении в зону запроса, или записанная в UTC, даёт
//  другую разность и другое значение. Половина 20i про
//  `exercise_states.last_performed_at` (§9.7) здесь не проверяется.

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

@Suite("20i: утомление через смену зоны (§20.7, §20.15)", .enabled(if: Live.enabled), .serialized)
struct Test20iFatigueAcrossZones {

    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private let newYork = TimeZone(identifier: "America/New_York")!

    private func context(_ zone: TimeZone) -> DayContext {
        DayContext(date: Mapping.LocalTime.iso(Mapping.LocalTime.day(of: Date(), in: zone)),
                   tz: zone.identifier)
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    private func logAndFinish(_ app: Application, _ user: Live.User, workout: String,
                              exercise: String, at moment: Date, zone: TimeZone) async throws {
        let set = LogSetRequest(id: UUID().uuidString, setIndex: 1, prescribedKg: 20, actualKg: 20,
                                actualReps: 10, feedback: .ok, completedAt: iso(moment),
                                day: context(zone))
        try await app.testing().test(
            .POST, "/v1/workouts/\(workout)/exercises/\(exercise)/sets",
            headers: user.headers, beforeRequest: { try $0.content.encode(set) }
        ) { #expect($0.status == .ok, Comment(rawValue: String(buffer: $0.body))) }
        try await app.testing().test(
            .POST, "/v1/workouts/\(workout)/finish", headers: user.headers,
            beforeRequest: { try $0.content.encode(FinishWorkoutRequest(day: self.context(zone))) }
        ) { #expect($0.status == .ok, Comment(rawValue: String(buffer: $0.body))) }
    }

    @Test("20i: метка записана в зоне записи и не переводится при чтении в другой зоне")
    func test20i_fatigueLabelSurvivesZoneChange() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("test.20i")
        let library = try Content.loadBundled()

        try await Live.withServer("test.20i") { app, database in
            let first = try await Live.startedWorkout(app, user, logger: logger)
            let exercise = try #require(first.exercises.first)
            let owner = try #require(UUID(uuidString: user.id.uuidString))
            let second = UUID(), secondExercise = UUID()
            try await database.withUserTransaction(authorization: "Bearer \(user.token)") { tx -> Void in
                // Калибровочные подходы в утомление не идут (§9.8) — снимаем.
                try await tx.query("""
                    update workout_exercises set is_calibration = false
                     where id = \(UUID(uuidString: exercise.id)!)
                    """)
                // Вторая тренировка с тем же упражнением, вне плана.
                try await tx.query("""
                    insert into workouts (id, user_id, started_at, session_kind, readiness)
                    values (\(second), \(owner), now(), 'full_body', 1.0)
                    """)
                try await tx.query("""
                    insert into workout_exercises (id, workout_id, exercise_slug, order_index,
                        target_sets, target_rep_min, target_rep_max, target_rir, weight_readiness)
                    values (\(secondExercise), \(second), \(exercise.slug), 0, 3, 8, 12, 2, 1.0)
                    """)
            }

            let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            let momentA = now.addingTimeInterval(-5 * 3600)
            let momentB = now.addingTimeInterval(-3600)
            try await self.logAndFinish(app, user, workout: first.id, exercise: exercise.id,
                                        at: momentA, zone: self.tokyo)
            try await self.logAndFinish(app, user, workout: second.uuidString,
                                        exercise: secondExercise.uuidString,
                                        at: momentB, zone: self.newYork)

            let candidate = try #require(library.candidates.first { $0.slug == exercise.slug })
            let one = FatigueSet(muscleLoad: candidate.muscleContributions.mapValues {
                $0 * candidate.fatigueCost
            }, feedback: .ok)
            let tA = Mapping.LocalTime.timestamp(of: momentA, in: self.tokyo)
            let tB = Mapping.LocalTime.timestamp(of: momentB, in: self.newYork)
            // Контроль: по местным часам Б раньше А на 9 часов, хотя на деле
            // позже на 4. Иначе перепутанные зоны дали бы тот же ответ.
            #expect(tA.hoursSinceEpoch - tB.hoursSinceEpoch > 8)
            let expected = Recovery.applying([one], at: tB, to: Recovery.applying([one], at: tA, to: [:]))

            let stored = try await database.withUserTransaction(
                authorization: "Bearer \(user.token)") { tx in try await Mapping.readFatigue(tx) }
            for (muscle, state) in expected where state.value > 0 {
                let row = try #require(stored[muscle], "\(muscle.rawValue) не записана")
                #expect(abs(row.value - state.value) < 0.001,
                        "\(muscle.rawValue): \(row.value) против \(state.value)")
                #expect(abs(row.updatedAt.hoursSinceEpoch - state.updatedAt.hoursSinceEpoch) < 1e-6,
                        "\(muscle.rawValue): метка уехала со шкалы зоны записи")
            }
        }
    }
}
