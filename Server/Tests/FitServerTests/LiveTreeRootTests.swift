//  Корень дерева §20.9 против ЖИВОЙ базы (SPEC §9.8, §20.9, §20.15 20c).
//
//  Тест заведён из-за конкретного промаха, и его стоит назвать, чтобы он не
//  вернулся. `Mapping.treeRoot` различала «упражнение без веса» по пустому
//  `startWeightKg`, то есть по `workout_exercises.prescribed_kg`. Но эта
//  колонка пуста у ДВУХ разных упражнений: у того, у которого веса нет
//  (`ladder == .none`), и у весового, стартующего в калибровке без базовой
//  линии (§9.8). Признак §20.9 — лестница, и только она.
//
//  Из-за подмены штанга в первую тренировку теряла вес, который ядро уже
//  посчитало: на 40 кг, «легко», 12 повторов `Progression.nextSet` отдавала
//  47.5, а корень — `nil`, и на экране следующего подхода веса не было вовсе.
//
//  **Почему живым прогоном, а не только юнитом.** Юнит-тест на это место уже
//  один раз соврал: он звал весовую лестницу с пустым стартовым весом и
//  утверждал, что весов быть не должно, — то есть фиксировал саму подмену.
//  Здесь те же числа проходят через настоящие колонки `numeric`, настоящий
//  `null` в `prescribed_kg` и настоящий путь чтения (`Mapping.readSets`), а
//  лестница строится из настоящего профиля инвентаря, а не подставляется
//  константой.
//
//  Посев идёт транзакцией САМОЙ пользовательницы, а не владельцем базы: RLS
//  §3.2 свои строки вставлять разрешает, и так проверяется заодно, что путь
//  записи у теста тот же, что у сервера. Строки `workouts` сервер пишет сам
//  (§20.6), но пути к ним ещё нет — когда появятся `POST /v1/workouts` и
//  `POST …/sets`, этот посев заменяется ими, а утверждения переезжают в
//  HTTP-половину 20c.

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
@testable import FitServer

@Suite("Корень дерева §20.9 против живой базы", .enabled(if: Live.enabled), .serialized)
struct LiveTreeRootTests {

    private let slug = "bench_press_barbell"
    private let zone = TimeZone(identifier: "Europe/Moscow")!
    private let range = 8...12

    @Test("штанга в калибровке без prescribed_kg: вес доезжает из базы, а не теряется")
    func calibrationWithoutBaselineOverLiveDatabase() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("tree.calibration")
        let database = try await Live.makeDatabase(logger)
        let library = try Content.loadBundled()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await database.run() }
            group.addTask {
                let token = "Bearer \(user.token)"

                // Посев: профиль, инвентарь (его фронтенд и так пишет сам,
                // §20.6), тренировка и один подход.
                try await database.withUserTransaction(authorization: token) { tx -> Void in
                    try await tx.query("""
                        insert into profiles (id, experience_level, goal, days_per_week,
                                              training_weekdays)
                        values (\(user.id), 'intermediate', 'hypertrophy', 3,
                                \([1, 3, 5] as [Int16]))
                        """)
                    try await tx.query("""
                        insert into equipment_profiles (id, user_id, name, is_default, plates_kg,
                                                        barbell_kg, bench)
                        values (\(UUID()), \(user.id), 'Зал', true,
                                '{1.25,2.5,5,10,20}', 20, 'flat')
                        """)

                    let workoutID = UUID()
                    let exerciseID = UUID()
                    try await tx.query("""
                        insert into workouts (id, user_id, planned_day_id, started_at,
                                              session_kind, readiness, is_calibration)
                        values (\(workoutID), \(user.id), null, now(), 'upper', 1.0, true)
                        """)
                    // `prescribed_kg` ПУСТ — базовой линии ещё нет (§9.8). Это
                    // и есть состояние, на котором ломалось.
                    try await tx.query("""
                        insert into workout_exercises (id, workout_id, exercise_slug, order_index,
                                                       target_sets, target_rep_min, target_rep_max,
                                                       target_rir, prescribed_kg,
                                                       weight_readiness, is_calibration)
                        values (\(exerciseID), \(workoutID), \(self.slug), 0, 3,
                                \(self.range.lowerBound), \(self.range.upperBound), 2, null,
                                1.0, true)
                        """)
                    // Она поставила 40 кг сама и сделала верх диапазона на «легко».
                    try await tx.query("""
                        insert into sets (id, workout_exercise_id, set_index, prescribed_kg,
                                          prescribed_reps, actual_kg, actual_reps, feedback,
                                          pain_flag, skipped, completed_at)
                        values (\(UUID()), \(exerciseID), 1, null, \(self.range.upperBound),
                                40, \(self.range.upperBound), 'easy', false, false, now())
                        """)
                }

                // Чтение — ровно тем путём, которым читает сервер.
                let (root, tree, direct) = try await database.withUserTransaction(
                    authorization: token
                ) { tx -> (Mapping.TreeRoot, DecisionTreeDTO, SetOutcome) in
                    let equipment = try await Mapping.readEquipment(tx, id: nil)
                    let journal = try await Mapping.readSets(tx, since: nil, timeZone: self.zone)
                    let mine = journal.filter { $0.exerciseSlug == self.slug }

                    let candidate = try #require(
                        library.candidates.first { $0.slug == self.slug })
                    let ladder = WeightLadder.build(loadType: candidate.loadType,
                                                    profile: equipment.profile)
                    #expect(ladder != .none, "штанга — весовое упражнение")

                    let row = try #require(mine.first)
                    #expect(row.prescribedKg == nil, "в базе пусто — ради этого тест и есть")
                    #expect(row.actualKg == 40)
                    #expect(row.isCalibration, "снимок калибровки доехал из workout_exercises")

                    let root = Mapping.treeRoot(sets: mine, startWeightKg: row.prescribedKg,
                                                range: self.range, isCalibration: row.isCalibration,
                                                ladder: ladder)
                    let tree = DecisionTree.build(
                        weightKg: root.weightKg, remainingSets: 2, range: self.range,
                        isCalibration: row.isCalibration,
                        previousWasFailed: root.previousWasFailed,
                        calibrationIncreasesUsed: root.calibrationIncreasesUsed,
                        ladder: ladder)
                    // Источник на том же состоянии — §20.15 требует совпадения
                    // с ним, а не правдоподобия.
                    let direct = Progression.nextSet(
                        priorFeedback: nil, current: 40, feedback: .easy,
                        actualReps: self.range.upperBound, range: self.range,
                        isCalibration: true, calibrationIncreasesUsed: 0, ladder: ladder)
                    return (root, tree, direct)
                }

                #expect(root.weightKg != nil,
                        "вес потерян: пустой prescribed_kg принят за упражнение без веса")
                #expect(direct == .nextWeight(root.weightKg ?? -1),
                        "корень обязан совпадать с прямым вызовом nextSet (§20.15, 20c)")
                #expect((root.weightKg ?? 0) > 40, "калибровочное ×1.15 подняло вес")
                #expect(root.calibrationIncreasesUsed == 1)

                let start = try #require(tree.nodes[tree.start])
                #expect(start.weightKg == root.weightKg, "корень доехал до карты состояний")
                #expect(tree.nodes.values.allSatisfy { $0.terminates || $0.weightKg != nil },
                        "весов нет ни на одном нетерминальном узле — та же потеря, но в дереве")

                // Уборка: своей же ролью, своим же путём.
                try await database.withUserTransaction(authorization: token) { tx -> Void in
                    try await tx.query("delete from workouts where user_id = \(user.id)")
                    try await tx.query("delete from equipment_profiles where user_id = \(user.id)")
                    try await tx.query("delete from profiles where id = \(user.id)")
                }
            }
            try await group.next()
            group.cancelAll()
        }
    }
}
