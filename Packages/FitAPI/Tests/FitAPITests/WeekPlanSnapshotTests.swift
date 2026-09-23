import XCTest
import Foundation
@testable import FitAPI
@testable import FitCore

/// Снимок показанного плана недели (SPEC §20.6): круг «план → jsonb → план»
/// обязан сохранить ровно то, что читает `Planner.rebuildNotice`, и ничего из
/// этого не потерять по дороге.
final class WeekPlanSnapshotTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private func session(_ dayID: String, _ composition: [String: Int]) -> BuiltSession {
        BuiltSession(dayID: dayID,
                     exercises: composition.keys.sorted().map { slug in
                         PrescribedExercise(slug: slug, orderIndex: 0, targetSets: composition[slug]!,
                                            targetRepMin: 8, targetRepMax: 12, targetRIR: 2,
                                            prescribedKg: 40, weightReadiness: 1.0)
                     },
                     estimatedSeconds: 2400, effectiveVolume: [.gluteMax: 9],
                     leadingMuscle: .gluteMax, scale: 1.0, reasons: [])
    }

    private var plan: WeekPlan {
        WeekPlan(days: [
            "d1": DayOutcome(dayID: "d1", kind: .session, cause: nil, losesPlannedVolume: false,
                             session: session("d1", ["hip_thrust_barbell": 3, "goblet_squat": 3])),
            "d2": DayOutcome(dayID: "d2", kind: .notBuilt, cause: .skipped, losesPlannedVolume: true,
                             session: nil),
            "d3": DayOutcome(dayID: "d3", kind: .stretching, cause: .gridStretch,
                             losesPlannedVolume: false, session: nil),
        ], statusLines: [.weekShortfallByTime(muscle: .gluteMax, sets: 3)])
    }

    /// Круг через jsonb и обратно, а дальше — главное: сравнение
    /// восстановленного плана с исходным молчит. Если бы круг терял `kind`,
    /// `cause` или состав, «План обновлён» печаталось бы на каждой пересборке,
    /// ничего не менявшей.
    func test_roundTripKeepsEverythingRebuildNoticeReads() throws {
        let data = try encoder.encode(WeekPlanSnapshot(plan))
        let restored = try XCTUnwrap(
            try decoder.decode(WeekPlanSnapshot.self, from: data).restoredForComparison())

        XCTAssertNil(Planner.rebuildNotice(previous: restored, current: plan, cause: .equipmentChanged),
                     "снимок того же плана обязан давать молчание")
    }

    /// Обратное утверждение: изменение состава круг обязан ДОНЕСТИ, иначе
    /// молчание было бы свойством потери данных, а не совпадения планов.
    func test_compositionChangeSurvivesTheRoundTrip() throws {
        let restored = try XCTUnwrap(
            try decoder.decode(WeekPlanSnapshot.self, from: try encoder.encode(WeekPlanSnapshot(plan)))
                .restoredForComparison())

        var changed = plan
        changed.days["d1"]?.session = session("d1", ["hip_thrust_barbell": 4, "goblet_squat": 3])
        XCTAssertNotNil(Planner.rebuildNotice(previous: restored, current: changed, cause: .equipmentChanged),
                        "подход прибавился — это изменение плана (§7.1)")

        var replaced = plan
        replaced.days["d1"]?.session = session("d1", ["hip_thrust_band": 3, "goblet_squat": 3])
        XCTAssertNotNil(Planner.rebuildNotice(previous: restored, current: replaced, cause: .equipmentChanged),
                        "упражнение заменилось — это изменение плана")
    }

    /// Смена судьбы дня по решению планировщика — тоже изменение (§7.1), и
    /// `kind` с `cause` обязаны пережить круг.
    func test_dayKindAndCauseSurviveTheRoundTrip() throws {
        let restored = try XCTUnwrap(
            try decoder.decode(WeekPlanSnapshot.self, from: try encoder.encode(WeekPlanSnapshot(plan)))
                .restoredForComparison())

        var changed = plan
        changed.days["d3"] = DayOutcome(dayID: "d3", kind: .stretching, cause: .restOverride,
                                        losesPlannedVolume: true, session: nil)
        XCTAssertNotNil(Planner.rebuildNotice(previous: restored, current: changed, cause: .override),
                        "растяжка по сетке и растяжка по оверрайду — разные причины")
    }

    /// Форма на проводе — из §20.6, вместе с номером версии.
    func test_wireShapeCarriesTheVersion() throws {
        let json = try JSONSerialization.jsonObject(
            with: try encoder.encode(WeekPlanSnapshot(plan))) as? [String: Any]
        XCTAssertEqual(Set(json?.keys ?? [:].keys), ["v", "days"])
        XCTAssertEqual(json?["v"] as? Int, 1)

        let day = (json?["days"] as? [String: Any])?["d1"] as? [String: Any]
        XCTAssertEqual(day?["kind"] as? String, "session")
        XCTAssertEqual((day?["composition"] as? [String: Int])?["hip_thrust_barbell"], 3)

        let skipped = (json?["days"] as? [String: Any])?["d2"] as? [String: Any]
        XCTAssertEqual(skipped?["cause"] as? String, "skipped")
        XCTAssertNil(skipped?["composition"], "у дня без сессии состава нет")
    }

    /// Чужая версия не разбирается молча: §20.6 велит обойтись с ней как с
    /// отсутствующим снимком, и для этого вызывающая сторона обязана её
    /// заметить.
    func test_unknownVersionIsRefused() throws {
        let data = Data(#"{"v": 2, "days": {}}"#.utf8)
        XCTAssertThrowsError(try decoder.decode(WeekPlanSnapshot.self, from: data))
    }

    /// Неизвестный `kind` — не крэш и не выдуманный план, а `nil`.
    func test_unknownKindRestoresToNil() throws {
        let data = Data(#"{"v": 1, "days": {"d1": {"kind": "teleport"}}}"#.utf8)
        let snapshot = try decoder.decode(WeekPlanSnapshot.self, from: data)
        XCTAssertNil(snapshot.restoredForComparison())
    }
}
