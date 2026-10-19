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

    private var session: BuiltSessionDTO { BuiltSessionDTO(coreSession, kind: .lower) }

    private var coreSession: BuiltSession {
        BuiltSession(
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
            reasons: [])
    }

    // MARK: - Тела ответов

    // MARK: - Календарь цикла (§11.6, §20.3)

    /// Даты эталона календаря отсчитываются от 2026-08-01: `iso` пишет их
    /// через Foundation, а не через `Mapping.LocalTime` сервера — FitAPI от
    /// сервера не зависит.
    private static let calendarBase = CalendarDay(year: 2026, month: 8, day: 1)
    private func calendarDay(_ n: Int) -> CalendarDay { Self.calendarBase.adding(days: n) }
    private func iso(_ day: CalendarDay) -> String {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let base = utc.date(from: DateComponents(year: 2026, month: 8, day: 1))!
        let date = utc.date(byAdding: .day, value: Self.calendarBase.days(until: day), to: base)!
        let c = utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    func test_cycleCalendar() throws {
        // Три цикла по 28, текущий с 84-го дня без отмеченного конца;
        // сегодня 94. В окне — отмеченное начало, расчётные дни, оценка
        // овуляции (98), прогнозные месячные (112…116) и пустой день за ними.
        let events = [0, 28, 56, 84].map { CycleEvent(kind: .periodStart, occurredOn: calendarDay($0)) }
        let profile = CycleProfile(typicalCycleLengthDays: 28)
        let today = calendarDay(94)
        let calendar = Cycle.calendar(events: events, profile: profile,
                                      from: calendarDay(84), to: calendarDay(117), asOf: today)
        let state = Cycle.state(events: events, profile: profile, responseProfiles: [:], asOf: today)
        let marks = [calendarDay(84): [CycleMarkDTO(id: "22222222-2222-4222-8222-222222222222",
                                                    kind: "period_start", source: "manual")]]
        try check("cycle_calendar.json", CycleCalendarDTO(
            calendar, from: calendarDay(84), to: calendarDay(117), cycle: CycleStateDTO(state),
            marks: marks, iso: iso))
    }

    func test_cycleCalendarNoPhases() throws {
        let events = [CycleEvent(kind: .periodStart, occurredOn: calendarDay(0))]
        let profile = CycleProfile(phaseMode: .noPhases, noPhaseReason: .contraception)
        let calendar = Cycle.calendar(events: events, profile: profile,
                                      from: calendarDay(0), to: calendarDay(6), asOf: calendarDay(3))
        let state = Cycle.state(events: events, profile: profile, responseProfiles: [:], asOf: calendarDay(3))
        let marks = [calendarDay(0): [CycleMarkDTO(id: "33333333-3333-4333-8333-333333333333",
                                                   kind: "period_start", source: "manual")]]
        try check("cycle_calendar_no_phases.json", CycleCalendarDTO(
            calendar, from: calendarDay(0), to: calendarDay(6), cycle: CycleStateDTO(state),
            marks: marks, iso: iso))
    }

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
            sessionMinutes: 60, trainingSplit: .auto, cycleTracking: .off, isComplete: false))
    }

    func test_profileComplete() throws {
        try check("profile_complete.json", ProfileDTO(
            sexAtBirth: "female", birthYear: 1994, heightCm: 168,
            experienceLevel: .intermediate, goal: .hypertrophy,
            daysPerWeek: 3, trainingWeekdays: [1, 3, 5],
            sessionMinutes: 60, trainingSplit: .pushPullLegs, cycleTracking: .off, isComplete: true,
            cycle: CycleProfileDTO(phaseMode: .noPhases, noPhaseReason: .userChoice)))
    }

    func test_weekPlanResponse() throws {
        try check("week_plan_response.json", WeekPlanResponseDTO(plan: weekPlanDTO()))
    }

    func test_contentExercises() throws {
        try check("content_exercises.json", [
            ExerciseContentDTO(slug: "squat_barbell", name: "Приседания со штангой",
                               cues: ["Колени по линии носков"], commonErrors: ["Колени заваливаются внутрь"],
                               illustration: "placeholder/lower/squat_barbell",
                               defaultRestSeconds: 120, equipmentLabels: ["Штанга"]),
            ExerciseContentDTO(slug: "bench_press_incline_dumbbell", name: "Жим гантелей на наклонной скамье",
                               cues: [], commonErrors: [],
                               illustration: "placeholder/upper/bench_press_incline_dumbbell",
                               defaultRestSeconds: 90, equipmentLabels: ["Гантели", "Регулируемая скамья"]),
            ExerciseContentDTO(slug: "pushup_bw", name: "Отжимания",
                               cues: [], commonErrors: [],
                               illustration: "placeholder/upper/pushup_bw",
                               defaultRestSeconds: 90, equipmentLabels: []),
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
                               exerciseSlug: "pushup_bw", setIndex: 1, prescribedReps: 15,
                               actualReps: 12, feedback: .ok, restSeconds: 90,
                               completedAt: "2026-10-12T09:36:00Z"),
                    ]),
            ]))
    }

    // MARK: - Завершение (срез 4)

    /// Неделя из двух дней: сегодняшний (низ тела, собран) и выполненный позже
    /// по дате, но раньше по `day_id` — эталон показывает порядок по датам.
    private func weekPlanDTO() -> WeekPlanDTO {
        let today = "11111111-1111-4111-8111-111111111111"
        let later = "00000000-0000-4000-8000-000000000000"
        let plan = WeekPlan(days: [
            today: DayOutcome(dayID: today, kind: .session, cause: nil,
                              losesPlannedVolume: false, session: coreSession),
            later: DayOutcome(dayID: later, kind: .notBuilt, cause: .done,
                              losesPlannedVolume: false, session: nil),
        ], statusLines: [])
        func day(_ id: String, _ kind: SessionKind) -> PlannedDay {
            PlannedDay(id: id, date: CalendarDay(dayNumber: 0), kind: kind, accent: nil, vector: [:])
        }
        return WeekPlanDTO(plan, week: [(day: day(later, .upper), isoDate: "2026-10-14"),
                                        (day: day(today, .lower), isoDate: "2026-10-12")])
    }

    private var finishedWorkout: WorkoutDTO {
        WorkoutDTO(
            id: "22222222-2222-4222-8222-222222222222",
            plannedDayID: "11111111-1111-4111-8111-111111111111",
            sessionKind: .upper, startedAt: "2026-10-12T09:30:00Z",
            finishedAt: "2026-10-12T10:15:00Z", readiness: 0.95,
            exercises: [
                WorkoutExerciseDTO(
                    id: "33333333-3333-4333-8333-333333333333",
                    prescribed: PrescribedExercise(
                        slug: "pushup_bw", orderIndex: 0, targetSets: 3, targetRepMin: 8,
                        targetRepMax: 15, targetRIR: 2, prescribedKg: nil, weightReadiness: 0.95),
                    isCalibration: false,
                    sets: [
                        SetDTO(id: "55555555-5555-4555-8555-555555555555",
                               exerciseSlug: "pushup_bw", setIndex: 1, prescribedReps: 15,
                               actualReps: 12, feedback: .ok, restSeconds: 90,
                               completedAt: "2026-10-12T09:36:00Z"),
                    ]),
            ])
    }

    func test_requestFinishWorkout() throws {
        try check("request_finish_workout.json", FinishWorkoutRequest(
            day: DayContext(date: "2026-10-12", tz: "Europe/Moscow")))
    }

    /// Первое завершение: неделя перестроилась, и в ней есть `notice` (§7.1).
    func test_responseFinishWorkoutWithNotice() throws {
        try check("response_finish_workout.json", FinishWorkoutResponseDTO(
            workout: finishedWorkout,
            week: WeekPlanResponseDTO(
                plan: weekPlanDTO(),
                notice: ReasonDTO(.planRebuilt(cause: .workoutCompleted))),
            cooldown: [CooldownPoseDTO(pose: "pigeon_pose", seconds: 45),
                       CooldownPoseDTO(pose: "hamstring_stretch", seconds: 30)]))
    }

    /// Повтор `/finish` или неделя без перестройки: `week` есть, `notice` нет.
    func test_responseFinishWorkoutNoNotice() throws {
        try check("response_finish_workout_no_notice.json", FinishWorkoutResponseDTO(
            workout: finishedWorkout,
            week: WeekPlanResponseDTO(plan: weekPlanDTO(), notice: nil),
            cooldown: [CooldownPoseDTO(pose: "pigeon_pose", seconds: 45),
                       CooldownPoseDTO(pose: "hamstring_stretch", seconds: 30)]))
    }

    /// Недели нет: ключа `week` в теле нет вовсе.
    func test_responseFinishWorkoutNoWeek() throws {
        try check("response_finish_workout_no_week.json", FinishWorkoutResponseDTO(
            workout: finishedWorkout, week: nil, cooldown: []))
    }

    // MARK: - Растяжка и прогресс (этап В3)

    /// Тело `/v1/content/stretches`: объект с позами и шаблонами (§12.3).
    func test_contentStretches() throws {
        try check("content_stretches.json", StretchContentDTO(
            poses: [
                PoseDTO(slug: "pigeon_pose", name: "Поза голубя", kind: "static", unilateral: true,
                        defaultSeconds: 45, cues: ["Таз ровно"], illustration: "placeholder/stretch/pigeon_pose"),
                PoseDTO(slug: "jumping_jack", name: "Джампинг-джек", kind: "cardio", unilateral: false,
                        defaultSeconds: 30, cues: ["Мягко на носки"], illustration: "placeholder/stretch/jumping_jack"),
            ],
            templates: [
                StretchTemplateDTO(slug: "hip_opening", name: "Раскрытие бёдер", purpose: "Приводящие, сгибатели бедра",
                                   durationSeconds: 150, minutes: 3, items: [TemplateItemDTO(pose: "pigeon_pose", seconds: 75)]),
                StretchTemplateDTO(slug: "cardio_intervals", name: "Кардио", purpose: "Интервальная сессия, не силовая",
                                   durationSeconds: 120, minutes: 2,
                                   items: [TemplateItemDTO(pose: "jumping_jack", workSeconds: 30, restSeconds: 15, rounds: 3)]),
            ]))
    }

    func test_requestStartStretchSession() throws {
        try check("request_start_stretch_session.json", StartStretchSessionRequest(
            id: "33333333-3333-4333-8333-333333333333", kind: "standalone", templateSlug: "hip_opening",
            day: DayContext(date: "2026-10-19", tz: "Europe/Moscow")))
    }

    func test_requestStartCooldownSession() throws {
        try check("request_start_cooldown_session.json", StartStretchSessionRequest(
            id: "44444444-4444-4444-8444-444444444444", kind: "static_cooldown", templateSlug: nil,
            day: DayContext(date: "2026-10-19", tz: "Europe/Moscow")))
    }

    func test_requestFinishStretchSession() throws {
        try check("request_finish_stretch_session.json",
                  FinishStretchSessionRequest(day: DayContext(date: "2026-10-19", tz: "Europe/Moscow")))
    }

    private var finishedStretch: StretchSessionDTO {
        StretchSessionDTO(id: "33333333-3333-4333-8333-333333333333", kind: "standalone",
                          templateSlug: "hip_opening", performedOn: "2026-10-19",
                          startedAt: "2026-10-19T18:00:00Z", finishedAt: "2026-10-19T18:12:00Z",
                          durationSeconds: 720)
    }

    func test_responseStretchSession() throws {
        try check("response_stretch_session.json", finishedStretch)
    }

    func test_responseStretchHistory() throws {
        try check("response_stretch_history.json",
                  StretchHistoryDTO(sessions: [finishedStretch], suggestedTemplate: "lower_back_pelvis"))
    }

    func test_responseProgress() throws {
        let groups = Dictionary(uniqueKeysWithValues: MuscleGroup.allCases.map { ($0.rawValue, 0.0) })
            .merging(["legs_glutes": 14.5, "back": 6.2], uniquingKeysWith: { $1 })
        try check("response_progress.json", ProgressDTO(
            from: "2026-09-01", to: "2026-10-19",
            weeks: [ProgressWeekDTO(weekStart: "2026-10-12", partial: false, groups: groups),
                    ProgressWeekDTO(weekStart: "2026-10-19", partial: true, groups: groups)],
            groupNorms: MuscleGroup.allCases.map { GroupNormDTO(group: $0, level: .intermediate) },
            baselines: [BaselineSeriesDTO(slug: "squat_barbell", points: [
                BaselinePointDTO(date: "2026-10-12", kg: 40), BaselinePointDTO(date: "2026-10-15", kg: 42.5)])],
            days: [ProgressDayDTO(date: "2026-10-12", strength: true, stretch: false, skipped: false, phase: .follicular),
                   ProgressDayDTO(date: "2026-10-13", strength: false, stretch: true, skipped: false, phase: nil),
                   ProgressDayDTO(date: "2026-10-14", strength: false, stretch: false, skipped: true, phase: nil)],
            streakWeeks: 3))
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

    /// Смена схемы тренировок в Профиле (§7.2): одно поле, остальное не трогается.
    func test_requestPatchProfileTrainingSplit() throws {
        try check("request_patch_profile_training_split.json", PatchProfileRequest(trainingSplit: .upperLower))
    }

    /// Названия тренажёров (§6.6) — эталон для таблицы `MACHINE_LABELS` веба,
    /// которая остаётся в Профиле и онбординге и сверяется с этим файлом.
    func test_machineNames() throws {
        try check("equipment_machine_names.json", EquipmentLabels.machineNames)
    }

    /// Шаг 9 онбординга, «да»: режим фаз, источник — вручную, заявленные
    /// длины и регулярность (§5, решения по онбордингу).
    func test_requestPatchProfileCyclePhases() throws {
        try check("request_patch_profile_cycle_phases.json", PatchProfileRequest(
            cycleTracking: .manual,
            cycle: CycleProfileDTO(typicalCycleLengthDays: 28, typicalPeriodLengthDays: 5,
                                   declaredRegularity: .regular, phaseMode: .phases)))
    }

    /// Шаг 9, «не сейчас»: `declined`, переспросить можно позже; «нет» несёт
    /// ту же форму с `user_choice`.
    func test_requestPatchProfileCycleDeclined() throws {
        try check("request_patch_profile_cycle_declined.json", PatchProfileRequest(
            cycleTracking: .off,
            cycle: CycleProfileDTO(phaseMode: .noPhases, noPhaseReason: .declined)))
    }

    func test_requestStartWorkout() throws {
        try check("request_start_workout.json", StartWorkoutRequest(
            plannedDayID: "11111111-1111-4111-8111-111111111111",
            day: DayContext(date: "2026-10-12", tz: "Europe/Moscow")))
    }

    /// Первый подход взвешенного упражнения: вес — тот, что показало дерево
    /// (`prescribed_kg` приходит от клиента, §20.3), `set_index` отсчитывается
    /// с единицы — как во всех серверных тестах и в умолчании `StoredSet`.
    func test_requestLogSet() throws {
        try check("request_log_set.json", LogSetRequest(
            id: "66666666-6666-4666-8666-666666666666", setIndex: 1,
            prescribedKg: 40, actualKg: 40, actualReps: 10, feedback: .ok,
            completedAt: "2026-10-12T09:36:00Z",
            day: DayContext(date: "2026-10-12", tz: "Europe/Moscow")))
    }

    /// Упражнение без веса: ни `prescribed_kg`, ни `actual_kg` в теле нет.
    func test_requestLogSetBodyweight() throws {
        try check("request_log_set_bodyweight.json", LogSetRequest(
            id: "77777777-7777-4777-8777-777777777777", setIndex: 2,
            actualReps: 8, feedback: .hard, completedAt: "2026-10-12T09:40:00Z",
            day: DayContext(date: "2026-10-12", tz: "Europe/Moscow")))
    }

    /// Ответ — только новое дерево (§20.3): корень уже «после этого подхода».
    func test_responseLogSet() throws {
        try check("response_log_set.json", LogSetResponseDTO(decisionTree: DecisionTreeDTO(
            start: "n0", nodes: [
                "n0": DecisionNode(weightKg: 40, truncated: false, terminates: false, transitions: [
                    "failed": "n1", "hard_below_min": "n1", "hard_at_or_above_min": "n0",
                    "ok": "n0", "easy_below_max": "n0", "easy_at_or_above_max": "n2",
                ]),
                "n1": DecisionNode(weightKg: 36, truncated: false, terminates: false, transitions: [:]),
                "n2": DecisionNode(weightKg: 42.5, truncated: false, terminates: false, transitions: [:]),
            ])))
    }

    func test_responseLogSetTerminated() throws {
        try check("response_log_set_terminated.json", LogSetResponseDTO(
            decisionTree: DecisionTree.terminated))
    }

    func test_requestGenerateWeekPlan() throws {
        try check("request_generate_week_plan.json", GenerateWeekPlanRequest(
            weekStart: "2026-10-12", day: DayContext(date: "2026-10-12", tz: "Europe/Moscow")))
    }

    // MARK: - Флаг боли и замена (срез 6, §8.4, §13.4)

    /// Подход с флагом боли: вес и повторы как на экране, без `feedback`.
    func test_requestLogSetPain() throws {
        try check("request_log_set_pain.json", LogSetRequest(
            id: "77777777-7777-4777-8777-777777777777", setIndex: 2,
            prescribedKg: 40, actualKg: 40, actualReps: 6, painFlag: true,
            completedAt: "2026-10-12T09:40:00Z",
            day: DayContext(date: "2026-10-12", tz: "Europe/Moscow")))
    }

    /// Три альтернативы с причинами пригодности (§13.4): ведущая мышца и сустав.
    func test_responseAlternatives() throws {
        try check("response_alternatives.json", [
            ExerciseAlternativeDTO(ExerciseAlternative(slug: "hip_thrust_barbell", reasons: [
                .substitutionKeepsLeadingMuscle(muscle: .gluteMax),
                .substitutionRelievesJoint(joint: .knee, from: .high, to: .low),
            ])),
            ExerciseAlternativeDTO(ExerciseAlternative(slug: "glute_bridge_bw", reasons: [
                .substitutionKeepsLeadingMuscle(muscle: .gluteMax),
            ])),
        ])
    }

    func test_requestSubstitutePain() throws {
        try check("request_substitute_pain.json", SubstituteExerciseRequest(
            toSlug: "hip_thrust_barbell", reason: .pain,
            day: DayContext(date: "2026-10-12", tz: "Europe/Moscow")))
    }

    /// Ответ замены: та же строка с новым слагом, `substituted_from` и
    /// `substitution_reason`; подходы прежнего упражнения остаются в `sets`.
    func test_responseSubstitute() throws {
        try check("response_substitute.json", WorkoutExerciseDTO(
            id: "33333333-3333-4333-8333-333333333333",
            prescribed: PrescribedExercise(
                slug: "hip_thrust_barbell", orderIndex: 0, targetSets: 3, targetRepMin: 8,
                targetRepMax: 12, targetRIR: 2, prescribedKg: 50, weightReadiness: 1.0),
            isCalibration: false, substitutedFrom: "squat_barbell", substitutionReason: .pain,
            sets: [
                SetDTO(id: "77777777-7777-4777-8777-777777777777", exerciseSlug: "squat_barbell",
                       setIndex: 1, prescribedKg: 40, prescribedReps: 10, actualKg: 40, actualReps: 6,
                       painFlag: true, painJoints: [.knee], completedAt: "2026-10-12T09:40:00Z"),
            ]))
    }

    func test_requestRebuildCycleEvent() throws {
        try check("request_rebuild_cycle_event.json", RebuildWeekPlanRequest(
            cause: .cycleEventAdded, day: DayContext(date: "2026-10-12", tz: "Europe/Moscow")))
    }
}
