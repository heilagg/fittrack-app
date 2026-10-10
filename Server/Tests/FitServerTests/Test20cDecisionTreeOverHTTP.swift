//  Тест 20c, половины, которые требуют HTTP (SPEC §9.3, §9.8, §20.9, §20.15).
//
//  Сверка каждой ветки с `Progression.nextSet`, лимит калибровки и упражнение
//  без веса закрыты в `FitAPITests/DecisionTreeTests` — на дереве с ПУСТЫМ
//  корнем. §20.15 называет ещё одну половину и говорит про неё прямо: «Обе
//  проверки обязаны идти через HTTP, а не через прямой вызов `build`: состояние
//  корня выводится сервером из журнала, и именно этот вывод здесь и
//  проверяется».
//
//  Поэтому здесь — дерево СЕРЕДИНЫ упражнения, отданное `POST …/sets`:
//
//    — после подхода с `failed` корень несёт признак, и ветка `failed` из него
//      ведёт в узел с `terminates` (§9.3);
//    — после трёх калибровочных повышений четвёртое «легко» веса не поднимает
//      (§9.8), хотя дерево построено заново;
//    — пропущенный подход и подход с флагом боли корень НЕ двигают (§20.9);
//    — границы, с которыми построено дерево, совпадают с
//      `workout_exercises.target_rep_*` и `exercise_states.current_rep_*` —
//      все три из одного вызова `Planner.repRange` (§9.1).
//
//  Последняя половина нужна потому, что сверка с `nextSet` к выбору диапазона
//  слепа по построению: она передаёт дереву и ядру ОДИН диапазон и проходит
//  зелёной при любом.

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

@Suite("20c: дерево середины упражнения через HTTP (§20.15)",
       .enabled(if: Live.enabled), .serialized)
struct Test20cDecisionTreeOverHTTP {

    /// Логирует подход и отдаёт дерево из ответа.
    private func log(_ app: Application, _ user: Live.User, workout: String, exercise: String,
                     index: Int, kg: Double?, reps: Int, feedback: Feedback?,
                     pain: Bool = false, skipped: Bool = false) async throws -> DecisionTreeDTO {
        let body = LogSetRequest(id: UUID().uuidString, setIndex: index, prescribedKg: kg,
                                 actualKg: kg, actualReps: reps, feedback: feedback,
                                 painFlag: pain, completedAt: "2026-10-08T10:00:00Z",
                                 skipped: skipped, day: Live.today)
        var tree: DecisionTreeDTO?
        try await app.testing().test(
            .POST, "/v1/workouts/\(workout)/exercises/\(exercise)/sets",
            headers: user.headers, beforeRequest: { try $0.content.encode(body) }
        ) { response in
            #expect(response.status == .ok, Comment(rawValue: String(buffer: response.body)))
            tree = try? JSONDecoder().decode(LogSetResponseDTO.self,
                                             from: Data(buffer: response.body)).decisionTree
        }
        return try #require(tree)
    }

    private func root(_ tree: DecisionTreeDTO) throws -> DecisionNode {
        try #require(tree.nodes[tree.start])
    }

    /// Лестница упражнения — из библиотеки и профиля инвентаря, ровно как её
    /// строит сервер.
    ///
    /// Без неё утверждать об абсолютных весах нельзя, и первая версия этого
    /// файла на том и сломалась: она кормила 40 кг упражнению с гантелями до 32,
    /// `roundToAchievable` честно опускал до 32, а тест читал это как ошибку
    /// сервера. Числа здесь берутся у `Progression.nextSet` на том же
    /// состоянии — §20.15 именно этого и требует, — а не выписываются руками.
    private func ladder(_ database: Database, _ user: Live.User,
                        slug: String) async throws -> WeightLadder {
        let library = try FitContent.Content.loadBundled()
        let candidate = try #require(library.candidates.first { $0.slug == slug })
        let profile = try await database.withUserTransaction(
            authorization: "Bearer \(user.token)"
        ) { tx in
            try await Mapping.readEquipment(tx, id: nil).profile
        }
        return WeightLadder.build(loadType: candidate.loadType, profile: profile)
    }

    /// Первое весовое упражнение тренировки: у упражнения без веса дерево весов
    /// не несёт вовсе (§20.9), и утверждать о них там нечего.
    private func weighted(_ workout: WorkoutDTO, _ database: Database,
                          _ user: Live.User) async throws -> (WorkoutExerciseDTO, WeightLadder) {
        for exercise in workout.exercises {
            let ladder = try await self.ladder(database, user, slug: exercise.slug)
            if ladder != .none { return (exercise, ladder) }
        }
        throw Live.Failure.seed("в тренировке нет ни одного весового упражнения")
    }

    // MARK: - Корень после failed

    @Test("после failed корень несёт признак: второй failed завершает упражнение")
    func rootCarriesPreviousFailed() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("test.20c.failed")

        try await Live.withServer("test.20c.failed") { app in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            let exercise = try #require(workout.exercises.first)
            #expect(exercise.targetSets >= 2, "иначе дерева после подхода не будет")

            let tree = try await self.log(app, user, workout: workout.id, exercise: exercise.id,
                                          index: 1, kg: exercise.prescribedKg ?? 40,
                                          reps: exercise.targetRepMin, feedback: .failed)
            let failed = try #require(try self.root(tree).transitions[TreeBranch.failed.rawValue])
            #expect(tree.nodes[failed]?.terminates == true,
                    "второй failed не завершает — корень не вывел previousWasFailed из журнала")
        }
    }

    // MARK: - Лимит калибровки (§9.8)

    @Test("четвёртое «легко» в калибровке вес не поднимает, хотя дерево построено заново")
    func calibrationLimitHoldsAcrossRebuilds() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("test.20c.calibration")

        try await Live.withServer("test.20c.calibration") { app, database in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            let (exercise, ladder) = try await self.weighted(workout, database, user)
            #expect(exercise.isCalibration, "у новой пользовательницы упражнения в калибровке")

            // Стартовый вес — любой ДОСТИЖИМЫЙ: у калибровки без базовой линии
            // `prescribed_kg` пуст, и первое число называет пользовательница.
            var weight = ladder.roundToAchievable(10, direction: .up)
            var weights: [Double] = []
            for index in 1...4 {
                // Оракул на том же состоянии, ДО запроса: счётчик повышений —
                // это число уже израсходованных, то есть index - 1, пока лимит
                // не исчерпан.
                let expected = Progression.nextSet(
                    priorFeedback: nil, current: weight, feedback: .easy,
                    actualReps: exercise.targetRepMax,
                    range: exercise.targetRepMin...exercise.targetRepMax,
                    isCalibration: true, calibrationIncreasesUsed: min(index - 1, 3),
                    ladder: ladder)

                let tree = try await self.log(
                    app, user, workout: workout.id, exercise: exercise.id, index: index,
                    kg: weight, reps: exercise.targetRepMax, feedback: .easy)
                let next = try #require(try self.root(tree).weightKg,
                                        "весовое упражнение — вес обязан быть")
                #expect(expected == .nextWeight(next),
                        Comment(rawValue: "подход \(index): корень разошёлся с nextSet"))
                weights.append(next)
                weight = next
            }

            #expect(weights[0] < weights[1], "первое повышение")
            #expect(weights[1] < weights[2], "второе")
            #expect(weights[2] == weights[3],
                    "четвёртое «легко» подняло вес — лимит §9.8 не держится через перестройку")
        }
    }

    // MARK: - Подходы вне дерева (§20.9)

    @Test("пропуск и флаг боли корень не двигают")
    func offTreeSetsLeaveTheRootAlone() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("test.20c.offtree")

        try await Live.withServer("test.20c.offtree") { app in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            let exercise = try #require(workout.exercises.first)
            let start = exercise.prescribedKg ?? 40.0

            let afterOk = try await self.log(app, user, workout: workout.id,
                                             exercise: exercise.id, index: 1, kg: start,
                                             reps: exercise.targetRepMin, feedback: .ok)
            let base = try self.root(afterOk)

            // Пропуск фидбэка не несёт вовсе: «предыдущий был failed» про него не
            // определено ни в какую сторону (§20.9).
            let afterSkip = try await self.log(app, user, workout: workout.id,
                                               exercise: exercise.id, index: 2, kg: nil,
                                               reps: 0, feedback: nil, skipped: true)
            #expect(try self.root(afterSkip).weightKg == base.weightKg,
                    "пропуск сдвинул вес корня")

            // Флаг боли запускает свою ветку §8.4, и засчитывать его ещё и шагом
            // прогрессии значит применить к одному событию два правила.
            let afterPain = try await self.log(app, user, workout: workout.id,
                                               exercise: exercise.id, index: 3, kg: start,
                                               reps: exercise.targetRepMax, feedback: .easy,
                                               pain: true)
            #expect(try self.root(afterPain).weightKg == base.weightKg,
                    "подход с флагом боли сдвинул вес корня")
            let failed = try #require(try self.root(afterPain)
                .transitions[TreeBranch.failed.rawValue])
            #expect(afterPain.nodes[failed]?.terminates == false,
                    "боль не должна выглядеть как предыдущий failed")
        }
    }

    // MARK: - Сам диапазон повторов (§9.1, §20.15)

    @Test("границы дерева, workout_exercises и exercise_states — один диапазон")
    func rangeIsOneSourceForAllThree() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("test.20c.range")

        try await Live.withServer("test.20c.range") { app, database in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            let (exercise, ladder) = try await self.weighted(workout, database, user)
            let range = exercise.targetRepMin...exercise.targetRepMax

            let stored = try await database.withUserTransaction(
                authorization: "Bearer \(user.token)"
            ) { tx -> ClosedRange<Int>? in
                let rows = try await tx.query("""
                    select current_rep_min, current_rep_max from exercise_states
                     where exercise_slug = \(exercise.slug)
                    """)
                for try await row in rows {
                    let (lo, hi) = try row.decode((Int, Int).self)
                    return lo...hi
                }
                return nil
            }
            #expect(stored == range,
                    "exercise_states и workout_exercises разошлись в диапазоне")

            // Дерево построено ровно на нём, и видно это по двум веткам «легко»:
            // ниже верхней границы вес не двигается, на ней — двигается. На
            // другом диапазоне одна из двух соврала бы.
            let start = ladder.roundToAchievable(10, direction: .up)
            let belowMax = try await self.log(
                app, user, workout: workout.id, exercise: exercise.id, index: 1,
                kg: start, reps: exercise.targetRepMax - 1, feedback: .easy)
            let afterBelow = try #require(try self.root(belowMax).weightKg)
            #expect(Progression.nextSet(priorFeedback: nil, current: start, feedback: .easy,
                                        actualReps: exercise.targetRepMax - 1, range: range,
                                        isCalibration: exercise.isCalibration,
                                        calibrationIncreasesUsed: 0, ladder: ladder)
                    == .nextWeight(afterBelow))
            #expect(afterBelow == start, "«легко» ниже rep_max вес поднимать не должно")

            let atMax = try await self.log(
                app, user, workout: workout.id, exercise: exercise.id, index: 2,
                kg: afterBelow, reps: exercise.targetRepMax, feedback: .easy)
            #expect(try #require(try self.root(atMax).weightKg) > afterBelow,
                    "«легко» на rep_max вес обязано поднять")
        }
    }
    // MARK: - Перерыв (§9.7): сброс rep_extension внутри сборки

    /// §20.15: «Случай с перерывом (§9.7, сброс `rep_extension` внутри сборки)
    /// входит в тест отдельной веткой». Свёртка журнала даёт расширенный
    /// диапазон, но сборка на день после перерыва в 22–45 дней сбрасывает
    /// расширение; все три места — предписание, `exercise_states` и дерево —
    /// обязаны получить СБРОШЕННЫЙ диапазон. Сырой дал бы правдоподобные числа,
    /// которых пользовательница не видела.
    @Test("перерыв 34 дня: дерево, workout_exercises и exercise_states — сброшенный диапазон")
    func rangeAfterABreakIsTheResetOne() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("test.20c.break")
        let library = try FitContent.Content.loadBundled()
        let base = Planner.baseRepRange(goal: .hypertrophy) // цель посева (LiveHarness)
        let zone = TimeZone(identifier: "Europe/Moscow")!
        let today = Mapping.LocalTime.day(of: Date(), in: zone)
        let day = DayContext(date: Mapping.LocalTime.iso(today), tz: zone.identifier)

        try await Live.withServer("test.20c.break") { app, database in
            try await Live.seed(app, user, logger: logger, weekdays: [(today.dayNumber + 3) % 7 + 1])
            // История всех гантельных упражнений (40, 37, 34 дня назад): состав сессии не выбрать
            // заранее, а история должна быть у того, что войдёт.
            let dumbbell = library.candidates.filter { $0.loadType == .dumbbell }.map(\.slug)
            let owner = try #require(UUID(uuidString: user.id.uuidString))
            try await database.withUserTransaction(authorization: "Bearer \(user.token)") { tx -> Void in
                // Первая сессия — два `ok` в диапазоне: выход из калибровки
                // (§9.8) с базовой линией 4 кг. Две следующие — «легко» на верхе:
                // ступень 4 → 6 кг больше 10%, и §9.5 расширяет повторы.
                for (daysAgo, feedback) in [(40, "ok"), (37, "easy"), (34, "easy")] {
                    let workout = UUID()
                    try await tx.query("""
                        insert into workouts (id, user_id, started_at, finished_at, session_kind, readiness)
                        values (\(workout), \(owner), now() - make_interval(days => \(daysAgo)::int),
                                now() - make_interval(days => \(daysAgo)::int), 'full_body', 1.0)
                        """)
                    for (index, slug) in dumbbell.enumerated() {
                        let we = UUID()
                        try await tx.query("""
                            insert into workout_exercises (id, workout_id, exercise_slug, order_index,
                                target_sets, target_rep_min, target_rep_max, target_rir, weight_readiness)
                            values (\(we), \(workout), \(slug), \(index), 2, \(base.lowerBound),
                                    \(base.upperBound), 2, 1.0)
                            """)
                        for setIndex in 1...2 {
                            try await tx.query("""
                                insert into sets (id, workout_exercise_id, set_index, prescribed_kg,
                                    prescribed_reps, actual_kg, actual_reps, feedback, pain_flag,
                                    skipped, completed_at, exercise_slug, is_calibration,
                                    weight_readiness)
                                values (\(UUID()), \(we), \(setIndex), 4, \(base.upperBound), 4,
                                        \(base.upperBound), \(feedback), false, false,
                                        now() - make_interval(days => \(daysAgo)::int), \(slug), false, 1.0)
                                """)
                        }
                    }
                }
                // Строки состояния — как их оставила бы запись подходов: вне
                // калибровки и с СЫРЫМ расширенным диапазоном. Старт обязан их
                // перезаписать сброшенным.
                for slug in dumbbell {
                    try await tx.query("""
                        insert into exercise_states (user_id, exercise_slug, baseline_kg,
                            current_rep_min, current_rep_max, in_calibration)
                        values (\(owner), \(slug), 4, \(base.lowerBound), \(base.upperBound + 2), false)
                        """)
                }
            }

            let generate = GenerateWeekPlanRequest(
                weekStart: Mapping.LocalTime.iso(Mapping.LocalTime.mondayOfWeek(today)), day: day)
            var dayID: String?
            try await app.testing().test(.POST, "/v1/week-plans", headers: user.headers,
                                         beforeRequest: { try $0.content.encode(generate) }) {
                #expect($0.status == .created, Comment(rawValue: String(buffer: $0.body)))
                dayID = try JSONDecoder().decode(WeekPlanResponseDTO.self, from: Data(buffer: $0.body))
                    .plan.days.first?.dayID
            }
            var workout: WorkoutDTO?
            let start = StartWorkoutRequest(plannedDayID: try #require(dayID), day: day)
            try await app.testing().test(.POST, "/v1/workouts", headers: user.headers,
                                         beforeRequest: { try $0.content.encode(start) }) {
                #expect($0.status == .created, Comment(rawValue: String(buffer: $0.body)))
                workout = try JSONDecoder().decode(WorkoutDTO.self, from: Data(buffer: $0.body))
            }
            let started = try #require(workout)

            // Контроль: свёртка журнала действительно даёт расширение, а
            // перерыв попадает в окно сброса без калибровки (22–45 дней).
            let journal = try await database.withUserTransaction(
                authorization: "Bearer \(user.token)") { tx in
                try await Mapping.readSets(tx, since: nil, timeZone: zone) }
            let equipment = try await database.withUserTransaction(
                authorization: "Bearer \(user.token)") { tx in try await Mapping.readEquipment(tx, id: nil) }
            let raw = Planner.exerciseStates(history: Mapping.exerciseHistory(from: journal),
                                             library: library.candidates, goal: .hypertrophy,
                                             equipment: equipment.profile)
            let exercise = try #require(started.exercises.first { (raw[$0.slug]?.repExtension ?? 0) > 0 },
                                        "ни у одного упражнения сессии свёртка не дала расширения: \(started.exercises.map { "\($0.slug)=\(String(describing: raw[$0.slug]))" })")
            let rawState = try #require(raw[exercise.slug])
            #expect((rawState.lastPerformedAt.map { $0.days(until: today) } ?? 0) >= 22)
            #expect(exercise.isCalibration == false, "фикстура: дерево вне калибровки")

            let range = exercise.targetRepMin...exercise.targetRepMax
            #expect(range == base, "сборка не сбросила rep_extension после перерыва")
            #expect(range != Planner.repRange(goal: .hypertrophy, state: rawState),
                    "контроль: сырой диапазон обязан отличаться")

            let stored = try await database.withUserTransaction(
                authorization: "Bearer \(user.token)") { tx -> ClosedRange<Int>? in
                for try await row in try await tx.query("""
                    select current_rep_min, current_rep_max from exercise_states
                     where exercise_slug = \(exercise.slug)
                    """) {
                    let (lo, hi) = try row.decode((Int, Int).self)
                    return lo...hi
                }
                return nil
            }
            #expect(stored == range, "exercise_states остались с сырым диапазоном")

            // Корень дерева выведен из журнала на сброшенном диапазоне: «легко»
            // на его верхе вес поднимает, а на сыром (верх выше на 2) это был
            // бы не верх. Диапазон внутри `DecisionTree.build` в ответе не
            // наблюдаем: ветки символьные (`easy_at_or_above_max`), и какой
            // ветке соответствуют повторы, клиент решает по `target_rep_*`.
            let ladder = WeightLadder.build(
                loadType: try #require(library.candidates.first { $0.slug == exercise.slug }).loadType,
                profile: equipment.profile)
            let startKg = try #require(exercise.prescribedKg)
            let tree = try await self.log(app, user, workout: started.id, exercise: exercise.id,
                                          index: 1, kg: startKg, reps: range.upperBound,
                                          feedback: .easy)
            let next = try #require(try self.root(tree).weightKg)
            #expect(Progression.nextSet(priorFeedback: nil, current: startKg, feedback: .easy,
                                        actualReps: range.upperBound, range: range,
                                        isCalibration: false, calibrationIncreasesUsed: 0,
                                        ladder: ladder) == .nextWeight(next))
            #expect(next > startKg, "«легко» на верхе сброшенного диапазона вес не подняло")
        }
    }
}
