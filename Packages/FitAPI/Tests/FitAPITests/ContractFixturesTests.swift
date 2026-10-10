import XCTest
import Foundation
@testable import FitAPI
@testable import FitCore

/// Эталонные JSON границы `/v1` (SPEC §20.2, решение по TS-типам; web-domain §5).
///
/// Источник правды — DTO этого пакета. Файлы в `Contract/fixtures/` — их
/// сериализация, и читает их TS-тест в `Web/`: так форма во фронтенде
/// проверяется тестом, а не договорённостью.
///
/// Тест падает, если файл расходится с тем, что выдаёт кодировщик сейчас, —
/// то есть если DTO поменяли, а эталон не перевыгрузили. Перевыгрузка:
///
///     FITAPI_REGENERATE_FIXTURES=1 swift test --filter ContractFixturesTests
///
/// Ключи отсортированы и вывод читаемый: эталон читают глазами в диффе. Порядок
/// ключей на проводе контрактом не является, TS-тест разбирает JSON, а не байты.
final class ContractFixturesTests: XCTestCase {

    private static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FitAPITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // FitAPI
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // корень репозитория
            .appendingPathComponent("Contract/fixtures", isDirectory: true)
    }

    private var regenerate: Bool {
        ProcessInfo.processInfo.environment["FITAPI_REGENERATE_FIXTURES"] == "1"
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value) + Data("\n".utf8)
    }

    /// Сверяет сериализацию значения с файлом и читает файл обратно в значение.
    private func check<T: Codable & Equatable>(_ name: String, _ value: T,
                                               file: StaticString = #filePath,
                                               line: UInt = #line) throws {
        let url = Self.directory.appendingPathComponent(name)
        let fresh = try encode(value)
        if regenerate {
            try FileManager.default.createDirectory(at: Self.directory,
                                                    withIntermediateDirectories: true)
            try fresh.write(to: url)
            return
        }
        guard let stored = try? Data(contentsOf: url) else {
            return XCTFail("нет эталона \(name); перевыгрузка: FITAPI_REGENERATE_FIXTURES=1",
                           file: file, line: line)
        }
        XCTAssertEqual(String(decoding: stored, as: UTF8.self),
                       String(decoding: fresh, as: UTF8.self),
                       "эталон \(name) устарел: DTO изменились, а файл нет", file: file, line: line)
        let decoded = try JSONDecoder().decode(T.self, from: stored)
        XCTAssertEqual(decoded, value, "эталон \(name) не читается обратно в то же значение",
                       file: file, line: line)
    }

    // MARK: - Значения

    private var noCycle: CycleStateDTO {
        CycleStateDTO(CycleState(phaseMode: .noPhases, noPhaseReason: .userChoice,
                                 hasAnchor: false, phase: nil, cycleConfidence: nil,
                                 periodization: nil, effectivePhaseAdjustment: nil))
    }

    private var session: BuiltSessionDTO {
        BuiltSessionDTO(BuiltSession(
            dayID: "11111111-1111-4111-8111-111111111111",
            exercises: [
                PrescribedExercise(slug: "squat_barbell", orderIndex: 0, targetSets: 3,
                                   targetRepMin: 6, targetRepMax: 10, targetRIR: 2,
                                   prescribedKg: 40, weightReadiness: 1.0),
                PrescribedExercise(slug: "pushup_bw", orderIndex: 1, targetSets: 3,
                                   targetRepMin: 8, targetRepMax: 15, targetRIR: 2,
                                   prescribedKg: nil, weightReadiness: 1.0),
            ],
            estimatedSeconds: 2400, effectiveVolume: [:], leadingMuscle: .quads, scale: 1,
            reasons: []))
    }

    // MARK: - Тела ответов

    func test_todayNotBuilt() throws {
        try check("today_not_built.json", TodayCardDTO(
            date: "2026-10-12", readiness: 1.0, cycle: noCycle,
            day: .notBuilt(cause: nil)))
    }

    func test_todaySession() throws {
        var day = DayOutcomeDTO.notBuilt(cause: nil)
        day = try JSONDecoder().decode(DayOutcomeDTO.self, from: Data("""
            {"day_id":"11111111-1111-4111-8111-111111111111","kind":"session",
             "loses_planned_volume":false}
            """.utf8))
        day.session = session
        try check("today_session.json", TodayCardDTO(
            date: "2026-10-12", readiness: 1.0, cycle: noCycle, day: day,
            reasons: [ReasonDTO(.plannedVolumeLoss(muscle: .gluteMax, sets: 4, cause: .skipped))]))
    }

    func test_todayNotATrainingDay() throws {
        try check("today_not_a_training_day.json", TodayCardDTO(
            date: "2026-10-13", readiness: 1.0, cycle: noCycle,
            day: .notBuilt(cause: .notATrainingDay)))
    }

    func test_profileIncomplete() throws {
        try check("profile_incomplete.json", ProfileDTO(
            sexAtBirth: "female", birthYear: 1994, heightCm: 168,
            experienceLevel: .intermediate, goal: .hypertrophy,
            daysPerWeek: 3, trainingWeekdays: [1, 3, 5],
            sessionMinutes: 60, cycleTracking: .off, isComplete: false))
    }

    func test_profileComplete() throws {
        try check("profile_complete.json", ProfileDTO(
            sexAtBirth: "female", birthYear: 1994, heightCm: 168,
            experienceLevel: .intermediate, goal: .hypertrophy,
            daysPerWeek: 3, trainingWeekdays: [1, 3, 5],
            sessionMinutes: 60, cycleTracking: .off, isComplete: true,
            cycle: CycleProfileDTO(phaseMode: .noPhases, noPhaseReason: .userChoice)))
    }

    func test_weekPlanResponse() throws {
        var day = try JSONDecoder().decode(DayOutcomeDTO.self, from: Data("""
            {"day_id":"11111111-1111-4111-8111-111111111111","kind":"session",
             "loses_planned_volume":false}
            """.utf8))
        day.session = session
        // `WeekPlanDTO` собирается только из значения ядра, а своего поэлементного
        // инициализатора не имеет; поэтому собираем его из JSON дня, который
        // кодирует тот же `DayOutcomeDTO`.
        let plan = try JSONDecoder().decode(WeekPlanDTO.self, from: Data(
            ("{\"days\":[" + String(decoding: try encode(day), as: UTF8.self)
             + "],\"status_lines\":[]}").utf8))
        try check("week_plan_response.json", WeekPlanResponseDTO(plan: plan))
    }

    func test_contentExercises() throws {
        try check("content_exercises.json", [
            ExerciseContentDTO(slug: "squat_barbell", name: "Приседания со штангой",
                               cues: ["Колени по линии носков"], commonErrors: ["Колени заваливаются внутрь"],
                               illustration: "placeholder/lower/squat_barbell",
                               defaultRestSeconds: 120),
            ExerciseContentDTO(slug: "pushup_bw", name: "Отжимания",
                               cues: [], commonErrors: [],
                               illustration: "placeholder/upper/pushup_bw",
                               defaultRestSeconds: 90),
        ])
    }

    // MARK: - Тренировка (срез 2)

    /// Только что начатая тренировка: подходов нет, дерево есть у обоих
    /// упражнений (§20.9), у упражнения без веса — только ветка завершения.
    func test_workoutStarted() throws {
        let weighted = DecisionTreeDTO(start: "n0", nodes: [
            "n0": DecisionNode(weightKg: 40, truncated: false, terminates: false, transitions: [
                "failed": "n1", "ok": "n0", "easy_at_or_above_max": "n2",
            ]),
            "n1": DecisionNode(weightKg: 36, truncated: false, terminates: false, transitions: [:]),
            "n2": DecisionNode(weightKg: 42.5, truncated: true, terminates: false, transitions: [:]),
        ])
        let bodyweight = DecisionTreeDTO(start: "n0", nodes: [
            "n0": DecisionNode(weightKg: nil, truncated: false, terminates: false, transitions: [
                "failed": "n1",
            ]),
            "n1": DecisionNode(weightKg: nil, truncated: false, terminates: false, transitions: [
                "failed": "n2",
            ]),
            "n2": DecisionNode(weightKg: nil, truncated: false, terminates: true, transitions: [:]),
        ])
        try check("workout_started.json", WorkoutDTO(
            id: "22222222-2222-4222-8222-222222222222",
            plannedDayID: "11111111-1111-4111-8111-111111111111",
            sessionKind: .lower, accentMuscle: .gluteMax,
            startedAt: "2026-10-12T09:30:00Z", readiness: 1.0, isCalibration: true,
            exercises: [
                WorkoutExerciseDTO(
                    id: "33333333-3333-4333-8333-333333333333",
                    prescribed: PrescribedExercise(
                        slug: "squat_barbell", orderIndex: 0, targetSets: 3, targetRepMin: 6,
                        targetRepMax: 10, targetRIR: 2, prescribedKg: 40, weightReadiness: 1.0),
                    isCalibration: true, decisionTree: weighted),
                WorkoutExerciseDTO(
                    id: "44444444-4444-4444-8444-444444444444",
                    prescribed: PrescribedExercise(
                        slug: "pushup_bw", orderIndex: 1, targetSets: 3, targetRepMin: 8,
                        targetRepMax: 15, targetRIR: 2, prescribedKg: nil, weightReadiness: 1.0),
                    isCalibration: false, decisionTree: bodyweight),
            ]))
    }

    /// Идущая тренировка с выполненным подходом: форма `SetDTO` (§3.1) на
    /// проводе — все ключи, включая `pain_joints` и `skipped`.
    func test_workoutInProgress() throws {
        try check("workout_in_progress.json", WorkoutDTO(
            id: "22222222-2222-4222-8222-222222222222",
            plannedDayID: "11111111-1111-4111-8111-111111111111",
            sessionKind: .upper, startedAt: "2026-10-12T09:30:00Z", readiness: 0.95,
            exercises: [
                WorkoutExerciseDTO(
                    id: "33333333-3333-4333-8333-333333333333",
                    prescribed: PrescribedExercise(
                        slug: "pushup_bw", orderIndex: 0, targetSets: 3, targetRepMin: 8,
                        targetRepMax: 15, targetRIR: 2, prescribedKg: nil, weightReadiness: 0.95),
                    isCalibration: false,
                    sets: [
                        SetDTO(id: "55555555-5555-4555-8555-555555555555",
                               exerciseSlug: "pushup_bw", setIndex: 0, prescribedReps: 15,
                               actualReps: 12, feedback: .ok, restSeconds: 90,
                               completedAt: "2026-10-12T09:36:00Z"),
                    ]),
            ]))
    }

    // MARK: - Ошибки

    func test_errorProfileIncomplete() throws {
        try check("error_profile_incomplete.json", APIErrorEnvelope(
            code: .profileIncomplete,
            details: ["missing": .string("experience_level,equipment_profile")]))
    }

    func test_errorUnauthorized() throws {
        try check("error_unauthorized.json", APIErrorEnvelope(code: .unauthorized))
    }

    func test_errorDateSkew() throws {
        try check("error_date_skew.json", APIErrorEnvelope(
            code: .dateSkew,
            details: ["sent": .string("2026-10-12"), "server": .string("2026-10-15")]))
    }

    func test_errorUnlinkedAccount() throws {
        try check("error_unlinked_account.json", APIErrorEnvelope(code: .unlinkedAccount))
    }

    func test_errorDayNotPlanned() throws {
        try check("error_day_not_planned.json", APIErrorEnvelope(
            code: .dayNotPlanned,
            details: ["workout_id": .string("22222222-2222-4222-8222-222222222222")]))
    }

    // MARK: - Тела запросов

    func test_requestPatchProfile() throws {
        try check("request_patch_profile.json", PatchProfileRequest(
            sexAtBirth: .some("female"), birthYear: .some(1994), heightCm: .some(168),
            experienceLevel: .some(.intermediate), goal: .some(.hypertrophy),
            trainingWeekdays: .some([1, 3, 5]), sessionMinutes: 60, cycleTracking: .off))
    }

    func test_requestStartWorkout() throws {
        try check("request_start_workout.json", StartWorkoutRequest(
            plannedDayID: "11111111-1111-4111-8111-111111111111",
            day: DayContext(date: "2026-10-12", tz: "Europe/Moscow")))
    }

    func test_requestGenerateWeekPlan() throws {
        try check("request_generate_week_plan.json", GenerateWeekPlanRequest(
            weekStart: "2026-10-12", day: DayContext(date: "2026-10-12", tz: "Europe/Moscow")))
    }
}
