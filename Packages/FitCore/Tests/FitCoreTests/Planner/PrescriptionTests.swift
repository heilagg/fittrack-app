import XCTest
@testable import FitCore

/// `Planner.prescribe` — пересчёт предписания на момент старта тренировки
/// (SPEC §20.3). Проверяется не только то, что числа меняются, но и то, что
/// состав НЕ меняется: ради второго функция и существует.
final class PrescriptionTests: XCTestCase {

    private let week = PlannerFixtures.week([(.lower, .gluteMax, [.gluteMax: 0.5, .quads: 0.3, .hamstrings: 0.2])])

    /// Утомление разгибателей бедра в 12:00 и в 19:00 того же дня — числа из
    /// §20.3: три «нормально» и одно «тяжело» дают 1.944 к моменту оценки дня и
    /// 1.722 к вечернему старту. Порог §8.2 стоит на 1.8, то есть он ровно
    /// между ними, и в этом весь смысл примера.
    private let atNoon: [MuscleSlug: Double] = [.gluteMax: 1.944, .quads: 1.944, .hamstrings: 1.944]
    private let atStart: [MuscleSlug: Double] = [.gluteMax: 1.722, .quads: 1.722, .hamstrings: 1.722]

    /// Тот же вход, что у сборки, с одним изменённым полем.
    private func input(fatigue: [MuscleSlug: Double], readiness: Double = 1.1) -> SessionInput {
        PlannerFixtures.input(week: week, fatigue: fatigue, readiness: readiness)
    }

    // MARK: - Одна реализация, а не две

    /// На том же утомлении пересчёт обязан вернуть ровно то, что вернула
    /// сборка. Это и есть проверка «второй реализации формул нет»: разойдись
    /// они хоть в округлении, тест упадёт здесь, а не у пользовательницы.
    func test_sameFatigueReturnsExactlyWhatBuildProduced() throws {
        let inputAtNoon = input(fatigue: atNoon)
        let built = try XCTUnwrap(Planner.buildSession(inputAtNoon))
        let prescribed = try XCTUnwrap(Planner.prescribe(built, input: inputAtNoon))
        XCTAssertEqual(prescribed, built)
    }

    // MARK: - Что меняется и что нет

    /// §20.3: состав, порядок и `target_sets` — по 12:00; вес, готовность к
    /// весу и целевой RIR — на момент старта.
    func test_startMomentChangesNumbersButNotComposition() throws {
        let built = try XCTUnwrap(Planner.buildSession(input(fatigue: atNoon)))
        let prescribed = try XCTUnwrap(Planner.prescribe(built, input: input(fatigue: atStart)))

        XCTAssertEqual(prescribed.exercises.map(\.slug), built.exercises.map(\.slug), "состав по 12:00")
        XCTAssertEqual(prescribed.exercises.map(\.orderIndex), built.exercises.map(\.orderIndex), "порядок по 12:00")
        XCTAssertEqual(prescribed.exercises.map(\.targetSets), built.exercises.map(\.targetSets), "target_sets по 12:00")
        XCTAssertEqual(prescribed.exercises.map(\.targetRepMin), built.exercises.map(\.targetRepMin))
        XCTAssertEqual(prescribed.exercises.map(\.targetRepMax), built.exercises.map(\.targetRepMax))
        XCTAssertEqual(prescribed.estimatedSeconds, built.estimatedSeconds, accuracy: 1e-9)
        XCTAssertEqual(prescribed.effectiveVolume, built.effectiveVolume)
        XCTAssertEqual(prescribed.reasons, built.reasons)

        // Пересечение порога 1.8 снимает надбавку RIR утомления, а вместе с ней
        // — срез надбавки готовности (§10, «вес следует порогу RIR»).
        for (after, before) in zip(prescribed.exercises, built.exercises) {
            XCTAssertEqual(before.weightReadiness, 1.0, accuracy: 1e-9, "\(before.slug): в 12:00 надбавка срезана")
            XCTAssertEqual(after.weightReadiness, 1.1, accuracy: 1e-9, "\(after.slug): к старту срез снят")
            XCTAssertEqual(after.targetRIR, before.targetRIR - 1, "\(after.slug): надбавка RIR утомления ушла")
        }
    }

    /// Вес следует за готовностью: там, где базовая линия есть, к старту он не
    /// ниже, чем в 12:00. Упражнения без веса остаются без веса.
    func test_weightsDoNotFallWhenFatigueDecayed() throws {
        let built = try XCTUnwrap(Planner.buildSession(input(fatigue: atNoon)))
        let prescribed = try XCTUnwrap(Planner.prescribe(built, input: input(fatigue: atStart)))

        for (after, before) in zip(prescribed.exercises, built.exercises) {
            switch (before.prescribedKg, after.prescribedKg) {
            case (nil, nil):
                continue
            case (let b?, let a?):
                XCTAssertGreaterThanOrEqual(a, b, "\(after.slug): вес к старту не падает")
            default:
                XCTFail("\(after.slug): наличие веса не зависит от утомления")
            }
        }
    }

    /// Ровно та ловушка, ради которой функция и заведена: полная пересборка на
    /// утомлении момента старта — это ДРУГОЙ вызов, и совпадения состава она не
    /// обещает. Тест утверждает не «состав разойдётся» (на этом срезе он может
    /// и совпасть), а то, что пересчёт от неё не зависит вовсе.
    func test_prescribeIsNotASecondBuild() throws {
        let built = try XCTUnwrap(Planner.buildSession(input(fatigue: atNoon)))
        let rebuilt = try XCTUnwrap(Planner.buildSession(input(fatigue: atStart)))
        let prescribed = try XCTUnwrap(Planner.prescribe(built, input: input(fatigue: atStart)))

        XCTAssertEqual(prescribed.exercises.map(\.slug), built.exercises.map(\.slug),
                       "пересчёт держится состава 12:00, а не того, что дала бы пересборка")
        if rebuilt.exercises.map(\.slug) != built.exercises.map(\.slug) {
            XCTAssertNotEqual(prescribed.exercises.map(\.slug), rebuilt.exercises.map(\.slug))
        }
    }

    // MARK: - Вход не тот

    func test_nilWhenSessionBelongsToAnotherInput() throws {
        let built = try XCTUnwrap(Planner.buildSession(input(fatigue: atNoon)))

        var alien = built
        alien.dayID = "день-которого-нет"
        XCTAssertNil(Planner.prescribe(alien, input: input(fatigue: atStart)),
                     "дня сессии нет в неделе — молча отдать веса 12:00 нельзя")

        var unknownSlug = built
        unknownSlug.exercises[0].slug = "упражнение-которого-нет"
        XCTAssertNil(Planner.prescribe(unknownSlug, input: input(fatigue: atStart)),
                     "упражнения нет в срезе библиотеки")
    }
}
