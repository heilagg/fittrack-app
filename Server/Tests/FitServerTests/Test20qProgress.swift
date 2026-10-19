//  20q. Прогресс через HTTP (SPEC §13.7, §20.3, §20.15).
//
//  История не короче шести недель (implement-feature §5а) заводится так: одна
//  тренировка проходит настоящий путь — старт, подходы, `/finish`, — а затем
//  её строки клонируются в шесть прошлых недель транзакцией пользовательницы
//  (RLS §3.2) с той же формой, что пишет сервер. Ожидаемый объём считается НЕ
//  через `Mapping`: по строкам `sets` и вкладам FitCore, независимо от пути.

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

@Suite("20q: прогресс (§13.7)", .enabled(if: Live.enabled), .serialized)
struct Test20qProgress {

    private let zone = TimeZone(identifier: "Europe/Moscow")!
    private var today: CalendarDay { Mapping.LocalTime.day(of: Date(), in: zone) }

    private func progress(_ app: Application, _ user: Live.User, from: CalendarDay) async throws -> ProgressDTO {
        var dto: ProgressDTO?
        let iso = Mapping.LocalTime.iso
        try await app.testing().test(
            .GET, "/v1/progress?from=\(iso(from))&to=\(iso(today))&date=\(iso(today))&tz=Europe%2FMoscow",
            headers: user.headers
        ) { response in
            #expect(response.status == .ok, Comment(rawValue: String(buffer: response.body)))
            dto = try JSONDecoder().decode(ProgressDTO.self, from: Data(buffer: response.body))
        }
        return try #require(dto)
    }

    private func tx<T: Sendable>(_ database: Database, _ user: Live.User,
                                 _ body: @escaping @Sendable (UserTransaction) async throws -> T) async throws -> T {
        try await database.withUserTransaction(authorization: "Bearer \(user.token)", body)
    }

    /// Клон тренировки на `weeks` недель назад: строки `workouts`,
    /// `workout_exercises` и `sets` с новыми `id`, сдвинутыми моментами и днём.
    private func cloneWorkout(_ database: Database, _ user: Live.User, id: String, weeks: Int) async throws {
        try await tx(database, user) { tx -> Void in
            let newWorkout = UUID()
            let shift = "\(weeks * 7) days"
            _ = try await tx.query("""
                insert into workouts
                select (jsonb_populate_record(null::workouts, to_jsonb(w) || jsonb_build_object(
                  'id', \(newWorkout), 'planned_day_id', null,
                  'started_at', w.started_at - \(shift)::interval,
                  'finished_at', w.finished_at - \(shift)::interval))).*
                  from workouts w where w.id = \(UUID(uuidString: id)!)
                """)
            var exercises: [String] = []
            for try await row in try await tx.query(
                "select id::text from workout_exercises where workout_id = \(UUID(uuidString: id)!)") {
                exercises.append(try row.decode(String.self))
            }
            for exercise in exercises {
                let newExercise = UUID()
                _ = try await tx.query("""
                    insert into workout_exercises
                    select (jsonb_populate_record(null::workout_exercises, to_jsonb(e) || jsonb_build_object(
                      'id', \(newExercise), 'workout_id', \(newWorkout)))).*
                      from workout_exercises e where e.id = \(UUID(uuidString: exercise)!)
                    """)
                _ = try await tx.query("""
                    insert into sets
                    select (jsonb_populate_record(null::sets, to_jsonb(s) || jsonb_build_object(
                      'id', gen_random_uuid(), 'workout_exercise_id', \(newExercise),
                      'completed_at', s.completed_at - \(shift)::interval,
                      'performed_on', s.performed_on - (\(weeks * 7))::int))).*
                      from sets s where s.workout_exercise_id = \(UUID(uuidString: exercise)!)
                    """)
            }
        }
    }

    @Test("20q: объём каждой из семи недель — по подходам этой недели; стрик — 7")
    func volumeOverSevenWeeks() async throws {
        let user = try await Live.signUpLinked()
        let logger = Live.quietLogger("20q.volume")
        try await Live.withServer("20q.volume") { app, database in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            for exercise in workout.exercises {
                for index in 1...2 {
                    let body = LogSetRequest(id: UUID().uuidString, setIndex: index, prescribedKg: exercise.prescribedKg,
                                             actualKg: exercise.prescribedKg, actualReps: exercise.targetRepMin,
                                             feedback: .ok, completedAt: ISO8601DateFormatter().string(from: Date()),
                                             day: Live.today)
                    try await app.testing().test(.POST, "/v1/workouts/\(workout.id)/exercises/\(exercise.id)/sets",
                                                 headers: user.headers, beforeRequest: { try $0.content.encode(body) }) { _ in }
                }
            }
            // Калибровочные подходы в `неделя[m]` не входят (§9.8); чтобы объём
            // был не нулевым, снимок калибровки снимается у всех подходов.
            try await self.tx(database, user) { tx -> Void in
                _ = try await tx.query("""
                    update sets set is_calibration = false
                     where workout_exercise_id in (select id from workout_exercises
                                                    where workout_id = \(UUID(uuidString: workout.id)!))
                    """)
            }
            try await app.testing().test(.POST, "/v1/workouts/\(workout.id)/finish", headers: user.headers,
                                         beforeRequest: { try $0.content.encode(FinishWorkoutRequest(day: Live.today)) }) { _ in }
            for weeks in 1...6 {
                do { try await self.cloneWorkout(database, user, id: workout.id, weeks: weeks) }
                catch { Issue.record("клонирование: \(String(reflecting: error))"); throw error }
            }

            // Ожидание — по строкам sets этой тренировки и вкладам FitCore.
            let counts: [String: Int] = try await self.tx(database, user) { tx in
                var result: [String: Int] = [:]
                for try await row in try await tx.query("""
                    select s.exercise_slug, count(*)::int from sets s
                      join workout_exercises we on we.id = s.workout_exercise_id
                     where we.workout_id = \(UUID(uuidString: workout.id)!)
                       and not s.skipped and s.feedback is not null and not s.is_calibration
                     group by s.exercise_slug
                    """) {
                    let (slug, n) = try row.decode((String, Int).self)
                    result[slug] = n
                }
                return result
            }
            let library = Dictionary(uniqueKeysWithValues: try Content.loadBundled().candidates.map { ($0.slug, $0) })
            var muscles: [MuscleSlug: Double] = [:]
            for (slug, n) in counts {
                for (m, share) in library[slug]!.effectiveContributions { muscles[m, default: 0] += Double(n) * share }
            }
            let expected = Progress.groupVolume(muscles)
            #expect(expected.values.reduce(0, +) > 0, "фикстура: объём не нулевой")

            let from = today.mondayOfWeek.adding(days: -42)
            let body = try await self.progress(app, user, from: from)
            #expect(body.weeks.count == 7)
            for week in body.weeks {
                for group in MuscleGroup.allCases {
                    #expect(abs((week.groups[group.rawValue] ?? -1) - (expected[group] ?? 0)) < 1e-9,
                            "неделя \(week.weekStart), \(group.rawValue)")
                }
            }
            #expect(body.weeks.last?.partial == true)
            #expect(body.weeks.dropLast().allSatisfy { !$0.partial })
            #expect(body.streakWeeks == 7)
            #expect(body.days.filter(\.strength).count == 7)
            #expect(body.groupNorms.count == MuscleGroup.allCases.count)
        }
    }

    @Test("20q: незавершённая растяжка не считается; завершённая — день растяжки и активность")
    func stretchCountsOnlyWhenFinished() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("20q.stretch")
        try await Live.withServer("20q.stretch") { app in
            try await Live.seed(app, user, logger: logger)
            let started = StartStretchSessionRequest(id: UUID().uuidString, kind: "standalone",
                                                     templateSlug: "hip_opening", day: Live.today)
            try await app.testing().test(.POST, "/v1/stretch-sessions", headers: user.headers,
                                         beforeRequest: { try $0.content.encode(started) }) { _ in }
            let open = try await self.progress(app, user, from: today.mondayOfWeek)
            #expect(open.streakWeeks == 0)
            #expect(open.days.allSatisfy { !$0.stretch })

            try await app.testing().test(.POST, "/v1/stretch-sessions/\(started.id)/finish", headers: user.headers,
                                         beforeRequest: { try $0.content.encode(FinishStretchSessionRequest(day: Live.today)) }) { _ in }
            let done = try await self.progress(app, user, from: today.mondayOfWeek)
            #expect(done.streakWeeks == 1)
            #expect(done.days.last?.stretch == true)
        }
    }

    @Test("20q: фаза дня не меняется от отметки, сделанной позже этого дня")
    func phaseAsKnownThatDay() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("20q.phase")
        try await Live.withServer("20q.phase") { app, database in
            try await Live.seed(app, user, logger: logger)
            let cycle = PatchProfileRequest(
                cycleTracking: .manual,
                cycle: CycleProfileDTO(typicalCycleLengthDays: 28, typicalPeriodLengthDays: 5,
                                       declaredRegularity: .regular, phaseMode: .phases))
            try await app.testing().test(.PATCH, "/v1/profile", headers: user.headers,
                                         beforeRequest: { try $0.content.encode(cycle) }) { _ in }
            let iso = Mapping.LocalTime.iso
            let addEvent = { (day: CalendarDay) in
                try await self.tx(database, user) { tx -> Void in
                    _ = try await tx.query("""
                        insert into cycle_events (id, user_id, kind, occurred_on)
                        values (\(UUID()), \(user.id), 'period_start', \(iso(day))::date)
                        """)
                }
            }
            try await addEvent(today.adding(days: -30))
            let from = today.adding(days: -29)
            let before = try await self.progress(app, user, from: from)
            #expect(before.days.contains { $0.phase != nil }, "фикстура: фазы в окне есть")

            let later = today.adding(days: -5)
            try await addEvent(later)
            let after = try await self.progress(app, user, from: from)
            let cutoff = iso(later)
            let earlierBefore = before.days.filter { $0.date < cutoff }.map(\.phase)
            let earlierAfter = after.days.filter { $0.date < cutoff }.map(\.phase)
            #expect(earlierBefore == earlierAfter, "прошлое не перекрашено")
            #expect(after.days.first { $0.date == cutoff }?.phase == "menstrual", "с дня отметки — новая фаза")
        }
    }
}
