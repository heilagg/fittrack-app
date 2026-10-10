//  `POST /v1/workouts/{id}/exercises/{we_id}/substitute` через HTTP против
//  живой базы (SPEC §8.4 п.2, §13.4, §20.3).
//
//  Каждое утверждение привязано к тому, что без правила ответ был бы другим:
//
//    — перенос §13.4: вес от `baseline_kg` заменённого через `family_load_ratio`,
//      `is_calibration = false`; ожидание считается `transferredBaseline` и
//      лестницей, а не повтором кода пути;
//    — своя история нового упражнения важнее переноса;
//    — подходы до замены остаются фактом о прежнем упражнении: корень дерева
//      нового их не видит;
//    — допуск `to_slug`: вне пула и (для `pain`) без разгрузки суставов — 422;
//    — повтор — 200 тем же телом; адресация по словарю; 20g.
//
//  Пара «упражнение → замена той же семьи» ищется в тренировке, а не
//  захардкожена: состав зависит от дня, и тест не должен молча стать пустым.

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

@Suite("POST …/substitute: замена упражнения (§13.4, §20.3)", .enabled(if: Live.enabled), .serialized)
struct LiveSubstituteTests {

    private let library = try! Content.loadBundled()
    private var bySlug: [String: ExerciseCandidate] {
        Dictionary(library.candidates.map { ($0.slug, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func substitute(_ app: Application, _ user: Live.User, workout: String, exercise: String,
                            to slug: String, reason: SubstitutionReason = .userChoice)
        async throws -> (Int, Data) {
        var captured: (Int, Data) = (0, Data())
        let body = SubstituteExerciseRequest(toSlug: slug, reason: reason, day: Live.today)
        try await app.testing().test(
            .POST, "/v1/workouts/\(workout)/exercises/\(exercise)/substitute",
            headers: user.headers, beforeRequest: { try $0.content.encode(body) }
        ) { captured = (Int($0.status.code), Data(buffer: $0.body)) }
        return captured
    }

    private func logSet(_ app: Application, _ user: Live.User, workout: String, exercise: String,
                        index: Int, kg: Double?, reps: Int, feedback: Feedback?,
                        pain: Bool = false) async throws {
        let body = LogSetRequest(id: UUID().uuidString, setIndex: index, prescribedKg: kg,
                                 actualKg: kg, actualReps: reps, feedback: feedback, painFlag: pain,
                                 completedAt: "2026-10-08T10:00:00Z", day: Live.today)
        try await app.testing().test(
            .POST, "/v1/workouts/\(workout)/exercises/\(exercise)/sets",
            headers: user.headers, beforeRequest: { try $0.content.encode(body) }
        ) { #expect($0.status == .ok, Comment(rawValue: String(buffer: $0.body))) }
    }

    private func sql<T: Sendable>(_ database: Database, _ user: Live.User,
                                  _ body: @escaping @Sendable (UserTransaction) async throws -> T)
        async throws -> T {
        try await database.withUserTransaction(authorization: "Bearer \(user.token)", body)
    }

    private func baseline(_ database: Database, _ user: Live.User, slug: String) async throws -> Double? {
        try await sql(database, user) { tx in
            for try await row in try await tx.query(
                "select baseline_kg::float8 from exercise_states where exercise_slug = \(slug)") {
                return try row.decode(Double?.self)
            }
            return nil
        }
    }

    /// Упражнение тренировки с заменой той же семьи, где перенос определён
    /// по разметке (оба `family_load_ratio`).
    private func transferPair(_ workout: WorkoutDTO) -> [(WorkoutExerciseDTO, ExerciseCandidate)] {
        workout.exercises.flatMap { e -> [(WorkoutExerciseDTO, ExerciseCandidate)] in
            guard let old = bySlug[e.slug], old.familyLoadRatio != nil else { return [] }
            return old.alternatives.compactMap { bySlug[$0] }
                .filter { $0.progressionFamily == old.progressionFamily && $0.familyLoadRatio != nil }
                .map { (e, $0) }
        }
    }

    // MARK: - Перенос §13.4

    @Test("перенос: вес от baseline заменённого через family_load_ratio, калибровки нет")
    func transferCarriesTheBaseline() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("substitute.transfer")
        try await Live.withServer("substitute.transfer") { app, database in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            var done = false
            for (exercise, target) in self.transferPair(workout) where !done {
                // Базовая линия появляется у заменяемого из первого подхода с весом.
                try await self.logSet(app, user, workout: workout.id, exercise: exercise.id,
                                      index: 1, kg: 10, reps: exercise.targetRepMin, feedback: .ok)
                let (status, raw) = try await self.substitute(app, user, workout: workout.id,
                                                             exercise: exercise.id, to: target.slug)
                guard status == 200 else { continue } // не допущено инвентарём — следующая пара
                done = true
                let dto = try JSONDecoder().decode(WorkoutExerciseDTO.self, from: raw)
                let old = try #require(self.bySlug[exercise.slug])
                let base = try #require(try await self.baseline(database, user, slug: old.slug))
                let equipment = try await self.sql(database, user) { tx in
                    try await Mapping.readEquipment(tx, id: nil) }
                let ladder = WeightLadder.build(loadType: target.loadType, profile: equipment.profile)
                let transferred = try #require(Planner.transferredBaseline(
                    from: old, to: target, baselineKg: base, ladder: ladder))
                let raw0 = transferred * dto.weightReadiness
                let expected = ladder.roundToAchievable(raw0, direction: raw0 < transferred ? .down : .up)

                #expect(dto.slug == target.slug)
                #expect(dto.substitutedFrom == old.slug)
                #expect(dto.substitutionReason == .userChoice)
                #expect(dto.targetSets == exercise.targetSets, "target_sets принадлежит месту")
                #expect(dto.isCalibration == false, "перенос определён — калибровки нет (§13.4)")
                #expect(dto.prescribedKg == expected, "вес не равен переносу §13.4")
                // Строка exercise_states нового слага заведена: подход пишется.
                try await self.logSet(app, user, workout: workout.id, exercise: exercise.id,
                                      index: 2, kg: dto.prescribedKg, reps: dto.targetRepMin,
                                      feedback: .ok)
            }
            try #require(done, "в тренировке нет допущенной замены той же семьи — фикстура")
        }
    }

    @Test("своя история нового упражнения важнее переноса")
    func ownHistoryBeatsTransfer() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("substitute.own")
        try await Live.withServer("substitute.own") { app, database in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            let (exercise, target) = try #require(self.transferPair(workout).first)
            try await self.logSet(app, user, workout: workout.id, exercise: exercise.id,
                                  index: 1, kg: 10, reps: exercise.targetRepMin, feedback: .ok)
            // История нового упражнения: прошлая тренировка с подходами на 52 кг.
            let owner = try #require(UUID(uuidString: user.id.uuidString))
            let past = UUID(), pastExercise = UUID()
            try await self.sql(database, user) { tx -> Void in
                try await tx.query("""
                    insert into workouts (id, user_id, started_at, finished_at, session_kind, readiness)
                    values (\(past), \(owner), now() - interval '3 days',
                            now() - interval '3 days', 'full_body', 1.0)
                    """)
                try await tx.query("""
                    insert into workout_exercises (id, workout_id, exercise_slug, order_index,
                        target_sets, target_rep_min, target_rep_max, target_rir, weight_readiness)
                    values (\(pastExercise), \(past), \(target.slug), 0, 2, 8, 12, 2, 1.0)
                    """)
                for index in 1...2 {
                    try await tx.query("""
                        insert into sets (id, workout_exercise_id, set_index, prescribed_kg,
                            prescribed_reps, actual_kg, actual_reps, feedback, pain_flag, skipped,
                            completed_at, exercise_slug, is_calibration, weight_readiness, performed_on)
                        values (\(UUID()), \(pastExercise), \(index), 52, 12, 52, 10, 'ok',
                                false, false, now() - interval '3 days', \(target.slug), false, 1.0,
                                ((now() - interval '3 days') at time zone 'Europe/Moscow')::date)
                        """)
                }
                try await tx.query("""
                    insert into exercise_states (user_id, exercise_slug, baseline_kg,
                        current_rep_min, current_rep_max, in_calibration)
                    values (\(owner), \(target.slug), 52, 8, 12, false)
                    on conflict (user_id, exercise_slug) do nothing
                    """)
            }
            let (status, raw) = try await self.substitute(app, user, workout: workout.id,
                                                         exercise: exercise.id, to: target.slug)
            try #require(status == 200, Comment(rawValue: String(decoding: raw, as: UTF8.self)))
            let dto = try JSONDecoder().decode(WorkoutExerciseDTO.self, from: raw)
            let old = try #require(self.bySlug[exercise.slug])
            let base = try #require(try await self.baseline(database, user, slug: old.slug))
            let equipment = try await self.sql(database, user) { tx in
                try await Mapping.readEquipment(tx, id: nil) }
            let ladder = WeightLadder.build(loadType: target.loadType, profile: equipment.profile)
            let transferred = Planner.transferredBaseline(from: old, to: target, baselineKg: base,
                                                          ladder: ladder)
            let kg = try #require(dto.prescribedKg, "своя история с весом — вес обязан быть")
            // Контроль: перенос дал бы заметно другое число.
            #expect(abs((transferred ?? 0) - 52) > 5)
            #expect(abs(kg - 52) < abs(kg - (transferred ?? 0)), "взят перенос, а не своя история")
        }
    }

    // MARK: - Подходы до замены

    @Test("подходы до замены остаются прежнему упражнению: корень дерева нового их не видит")
    func earlierSetsStayWithTheOldExercise() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("substitute.history")
        try await Live.withServer("substitute.history") { app, database in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            let (exercise, target) = try #require(self.transferPair(workout).first)
            try await self.logSet(app, user, workout: workout.id, exercise: exercise.id,
                                  index: 1, kg: 10, reps: exercise.targetRepMin, feedback: .failed)
            let (status, raw) = try await self.substitute(app, user, workout: workout.id,
                                                         exercise: exercise.id, to: target.slug)
            try #require(status == 200, Comment(rawValue: String(decoding: raw, as: UTF8.self)))
            let dto = try JSONDecoder().decode(WorkoutExerciseDTO.self, from: raw)
            // В ответе подход до замены несёт слаг ПРЕЖНЕГО упражнения (§20.3).
            #expect(dto.sets.map(\.exerciseSlug) == [exercise.slug],
                    "подход до замены показан подходом нового упражнения")
            // После одного failed СТАРОГО второй failed завершил бы упражнение
            // (§9.3). У нового подходов нет — failed ведёт в обычный узел.
            let tree = try #require(dto.decisionTree)
            let root = try #require(tree.nodes[tree.start])
            let failed = try #require(root.transitions[TreeBranch.failed.rawValue])
            #expect(tree.nodes[failed]?.terminates == false, "корень нового построен по подходам старого")

            let journal = try await self.sql(database, user) { tx in
                try await Mapping.readSets(tx, since: nil, timeZone: TimeZone(identifier: "Europe/Moscow")!)
            }
            #expect(journal.map(\.exerciseSlug) == [exercise.slug], "подход приписан новому слагу")
        }
    }

    // MARK: - Допуск to_slug

    @Test("to_slug вне пула или незнакомый — 422 validation_failed с полем to_slug")
    func outsideThePoolIsRefused() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("substitute.pool")
        try await Live.withServer("substitute.pool") { app in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            let exercise = try #require(workout.exercises.first)
            let old = try #require(self.bySlug[exercise.slug])
            let outside = try #require(self.library.candidates.first {
                $0.slug != old.slug && !old.alternatives.contains($0.slug) })
            for slug in [outside.slug, "no_such_exercise"] {
                let (status, raw) = try await self.substitute(app, user, workout: workout.id,
                                                             exercise: exercise.id, to: slug)
                #expect(status == 422)
                let envelope = try JSONDecoder().decode(APIErrorEnvelope.self, from: raw)
                #expect(envelope.error.code == .validationFailed)
                #expect(envelope.error.details?["field"] == .string("to_slug"))
            }
        }
    }

    @Test("reason = pain: слаг пула без разгрузки суставов — 422, тот же по user_choice — 200")
    func painRequiresRelief() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("substitute.pain")
        try await Live.withServer("substitute.pain") { app in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            var checked = false
            for exercise in workout.exercises where !checked {
                try await self.logSet(app, user, workout: workout.id, exercise: exercise.id,
                                      index: 1, kg: nil, reps: 0, feedback: nil, pain: true)
                let old = try #require(self.bySlug[exercise.slug])
                let joints = Recovery.painJoints(from: old.jointStress)
                // Слаг пула, который суставы НЕ разгружает строго.
                guard let hard = old.alternatives.compactMap({ self.bySlug[$0] }).first(where: { c in
                    joints.contains { (c.jointStress[$0] ?? .none) >= (old.jointStress[$0] ?? .none) }
                }) else { continue }
                let (pain, _) = try await self.substitute(app, user, workout: workout.id,
                                                         exercise: exercise.id, to: hard.slug,
                                                         reason: .pain)
                let (choice, _) = try await self.substitute(app, user, workout: workout.id,
                                                           exercise: exercise.id, to: hard.slug,
                                                           reason: .userChoice)
                guard choice == 200 else { continue } // не прошёл инвентарь — не тот случай
                #expect(pain == 422, "\(hard.slug) не разгружает \(joints), но допущен по боли")
                checked = true
            }
            try #require(checked, "нет слага пула, который проходит user_choice и не разгружает — фикстура")
        }
    }

    // MARK: - Повтор и адресация

    @Test("повтор с тем же to_slug — 200 и то же тело; substituted_from не съезжает")
    func repeatAnswersTheSame() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("substitute.repeat")
        try await Live.withServer("substitute.repeat") { app in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            let (exercise, target) = try #require(self.transferPair(workout).first)
            let (first, a) = try await self.substitute(app, user, workout: workout.id,
                                                      exercise: exercise.id, to: target.slug)
            try #require(first == 200, Comment(rawValue: String(decoding: a, as: UTF8.self)))
            let (second, b) = try await self.substitute(app, user, workout: workout.id,
                                                       exercise: exercise.id, to: target.slug)
            #expect(second == 200, Comment(rawValue: String(decoding: b, as: UTF8.self)))
            let one = try JSONDecoder().decode(WorkoutExerciseDTO.self, from: a)
            let two = try JSONDecoder().decode(WorkoutExerciseDTO.self, from: b)
            #expect(two == one)
            #expect(two.substitutedFrom == exercise.slug, "повтор заменил упражнение само на себя")
        }
    }

    @Test("нет тренировки — 409 workout_not_started, закрыта — 409 workout_finished, чужой we_id — 404")
    func addressing() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("substitute.addressing")
        try await Live.withServer("substitute.addressing") { app, database in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            let (exercise, target) = try #require(self.transferPair(workout).first)
            let codes: [(String, String, Int, APIErrorCode)] = [
                (UUID().uuidString, exercise.id, 409, .workoutNotStarted),
                (workout.id, UUID().uuidString, 404, .notFound),
            ]
            for (w, e, status, code) in codes {
                let (got, raw) = try await self.substitute(app, user, workout: w, exercise: e,
                                                          to: target.slug)
                #expect(got == status)
                #expect(try JSONDecoder().decode(APIErrorEnvelope.self, from: raw).error.code == code)
            }
            let id = try #require(UUID(uuidString: workout.id))
            try await self.sql(database, user) { tx -> Void in
                try await tx.query("update workouts set finished_at = now() where id = \(id)")
            }
            let (closed, raw) = try await self.substitute(app, user, workout: workout.id,
                                                         exercise: exercise.id, to: target.slug)
            #expect(closed == 409)
            #expect(try JSONDecoder().decode(APIErrorEnvelope.self, from: raw).error.code == .workoutFinished)
        }
    }

    @Test("20g: замена двигает sync_seq тренировки")
    func test20g_substitutionMovesSyncSeq() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("substitute.20g")
        try await Live.withServer("substitute.20g") { app, database in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            let (exercise, target) = try #require(self.transferPair(workout).first)
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
            let (status, _) = try await self.substitute(app, user, workout: workout.id,
                                                       exercise: exercise.id, to: target.slug)
            #expect(status == 200)
            #expect(try await seq() > before)
        }
    }
}
