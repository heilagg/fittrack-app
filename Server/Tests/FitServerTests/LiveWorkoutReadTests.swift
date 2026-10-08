//  `GET /v1/workouts/{id}` через HTTP против живой базы (SPEC §20.3, §20.9).
//
//  Тело у чтения то же, что у старта, и собирается тем же `WorkoutRoutes.body`,
//  поэтому состав и подходы здесь не перепроверяются — это уже сделано на
//  старте. Проверяется то, что добавляет именно чтение:
//
//    — тренировка возвращается равной той, что отдал старт;
//    — чужая не возвращается вовсе (404, а не 403: RLS строки не отдала);
//    — **дерево НАЧАТОГО упражнения непустое.** §20.9 называет этот путь вторым
//      потребителем вывода корня из журнала — «то же самое верно для
//      `GET /v1/workouts/{id}`, если упражнение начато», — и это половина
//      §20.15 (20c), которую на пустом корне проверить нельзя;
//    — дерева нет, когда подходов не осталось (§20.3), и условие это
//      `remaining_sets = 0`, а не `finished_at`.
//
//  ── Почему подходы сеются, а не логируются ────────────────────────────────
//
//  `POST …/sets` ещё не написан. Строки кладутся транзакцией той же
//  пользовательницы — через RLS §3.2 и ту же точку входа, — и когда путь
//  появится, посев заменяется им, а утверждения остаются: корень выводится из
//  журнала одинаково, кто бы его туда ни положил.

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

@Suite("GET /v1/workouts/{id}: чтение тренировки (§20.3, §20.9)",
       .enabled(if: Live.enabled), .serialized)
struct LiveWorkoutReadTests {

    private var today: CalendarDay {
        Mapping.LocalTime.day(of: Date(), in: TimeZone(identifier: "Europe/Moscow")!)
    }
    private var weekStart: CalendarDay { Mapping.LocalTime.mondayOfWeek(today) }
    private var todayISOWeekday: Int { (today.dayNumber + 3) % 7 + 1 }

    private var day: DayContext {
        DayContext(date: Mapping.LocalTime.iso(today), tz: "Europe/Moscow")
    }

    /// Профиль, неделя из одного сегодняшнего дня и начатая по нему тренировка.
    private func started(_ app: Application, _ user: Live.User,
                         logger: Logger) async throws -> WorkoutDTO {
        try await Live.seed(app, user, logger: logger, weekdays: [todayISOWeekday])
        let generate = GenerateWeekPlanRequest(weekStart: Mapping.LocalTime.iso(weekStart),
                                               day: day)
        var dayID: String?
        try await app.testing().test(.POST, "/v1/week-plans", headers: user.headers,
                                     beforeRequest: { try $0.content.encode(generate) }) { response in
            #expect(response.status == .created, Comment(rawValue: String(buffer: response.body)))
            dayID = try JSONDecoder().decode(WeekPlanResponseDTO.self,
                                             from: Data(buffer: response.body))
                .plan.days.first?.dayID
        }
        let start = StartWorkoutRequest(plannedDayID: try #require(dayID), day: day)
        var workout: WorkoutDTO?
        try await app.testing().test(.POST, "/v1/workouts", headers: user.headers,
                                     beforeRequest: { try $0.content.encode(start) }) { response in
            #expect(response.status == .created, Comment(rawValue: String(buffer: response.body)))
            workout = try JSONDecoder().decode(WorkoutDTO.self, from: Data(buffer: response.body))
        }
        return try #require(workout)
    }

    private func read(_ app: Application, _ user: Live.User,
                      id: String) async throws -> (Int, WorkoutDTO?) {
        var captured: (Int, WorkoutDTO?) = (0, nil)
        try await app.testing().test(.GET, "/v1/workouts/\(id)", headers: user.headers) { response in
            captured = (Int(response.status.code),
                        try? JSONDecoder().decode(WorkoutDTO.self, from: Data(buffer: response.body)))
        }
        return captured
    }

    /// Подход прямо в базу — транзакцией самой пользовательницы (см. шапку).
    private func logSet(_ database: Database, _ user: Live.User, exerciseID: String,
                        index: Int, kg: Double?, reps: Int, feedback: String) async throws {
        try await database.withUserTransaction(authorization: "Bearer \(user.token)") { tx -> Void in
            try await tx.query("""
                insert into sets (id, workout_exercise_id, set_index, prescribed_kg,
                                  prescribed_reps, actual_kg, actual_reps, feedback,
                                  pain_flag, skipped, completed_at)
                values (\(UUID()), \(UUID(uuidString: exerciseID)!), \(index), \(kg),
                        \(reps), \(kg), \(reps), \(feedback), false, false, now())
                """)
        }
    }

    // MARK: - Чтение возвращает то же, что старт

    @Test("начатая тренировка читается и равна той, что отдал старт")
    func readsTheStartedWorkout() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("workout.read")

        try await Live.withServer("workout.read") { app in
            let started = try await self.started(app, user, logger: logger)
            let (status, read) = try await self.read(app, user, id: started.id)
            #expect(status == 200)
            let w = try #require(read)
            #expect(w.id == started.id)
            #expect(w.startedAt == started.startedAt)
            #expect(w.exercises.map(\.slug) == started.exercises.map(\.slug))
            #expect(w.exercises.map(\.prescribedKg) == started.exercises.map(\.prescribedKg))
            #expect(w.exercises.map(\.targetRIR) == started.exercises.map(\.targetRIR))
        }
    }

    @Test("чужая тренировка — 404, а не 403 и не чужое тело")
    func anotherUsersWorkoutIsNotFound() async throws {
        let alice = try await Live.signUpAnonymous()
        let bob = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("workout.read.isolation")

        try await Live.withServer("workout.read.isolation") { app in
            let started = try await self.started(app, alice, logger: logger)
            let (status, body) = try await self.read(app, bob, id: started.id)
            #expect(status == 404)
            #expect(body == nil)
        }
    }

    // MARK: - Дерево начатого упражнения (§20.9, половина 20c)

    @Test("после подхода с failed корень несёт признак, и ветка failed завершает")
    func treeOfAStartedExerciseCarriesTheRoot() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("workout.read.tree")

        try await Live.withServer("workout.read.tree") { app, database in
            let started = try await self.started(app, user, logger: logger)
            let first = try #require(started.exercises.first)
            #expect(first.targetSets >= 2, "иначе после одного подхода дерева не будет вовсе")

            // Пустой корень: до подходов ветка failed ведёт в обычный узел.
            let fresh = try #require(first.decisionTree)
            let freshRoot = try #require(fresh.nodes[fresh.start])
            let freshFailed = try #require(freshRoot.transitions[TreeBranch.failed.rawValue])
            #expect(fresh.nodes[freshFailed]?.terminates == false,
                    "один failed упражнение не закрывает (§9.3)")

            try await self.logSet(database, user, exerciseID: first.id, index: 1,
                                  kg: first.prescribedKg, reps: first.targetRepMin,
                                  feedback: "failed")

            let (status, read) = try await self.read(app, user, id: started.id)
            #expect(status == 200)
            let after = try #require(read?.exercises.first { $0.id == first.id })
            #expect(after.sets.count == 1, "подход доехал в тело")

            // Корень выведен из журнала: предыдущий был failed, и ВТОРОЙ failed
            // обязан завершить упражнение досрочно (§9.3).
            let tree = try #require(after.decisionTree, "подходы остались — дерево обязано быть")
            let root = try #require(tree.nodes[tree.start])
            let failed = try #require(root.transitions[TreeBranch.failed.rawValue])
            #expect(tree.nodes[failed]?.terminates == true,
                    "второй failed не завершает — корень не несёт previousWasFailed")
        }
    }

    @Test("подходов не осталось — дерева нет, и условие это остаток, а не finished_at")
    func noTreeWhenNoSetsRemain() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("workout.read.exhausted")

        try await Live.withServer("workout.read.exhausted") { app, database in
            let started = try await self.started(app, user, logger: logger)
            let first = try #require(started.exercises.first)

            for index in 1...first.targetSets {
                try await self.logSet(database, user, exerciseID: first.id, index: index,
                                      kg: first.prescribedKg, reps: first.targetRepMin,
                                      feedback: "ok")
            }

            let (status, read) = try await self.read(app, user, id: started.id)
            #expect(status == 200)
            let after = try #require(read?.exercises.first { $0.id == first.id })
            #expect(after.sets.count == first.targetSets)
            #expect(after.decisionTree == nil, "решать нечего — поля нет (§20.3)")
            // Тренировка при этом ОТКРЫТА: пустота дерева привязана к остатку
            // подходов, а не к завершению.
            #expect(read?.finishedAt == nil)
            // А у упражнения, которое ещё не начинали, дерево на месте.
            if let untouched = read?.exercises.first(where: { $0.id != first.id }) {
                #expect(untouched.decisionTree != nil)
            }
        }
    }
}
