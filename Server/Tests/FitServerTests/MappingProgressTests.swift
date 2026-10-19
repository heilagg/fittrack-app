//  Тело `/v1/progress` без базы (SPEC §13.7) и проверка тела старта растяжки
//  (§12.2, §20.3). Живые 20p и 20q — отдельно.

import Testing
import Foundation
import FitAPI
import FitContent
import FitCore
@testable import FitServer

@Suite("Прогресс и растяжка: чистые части (§13.7, §12.2)")
struct MappingProgressTests {

    private let monday = CalendarDay(year: 2026, month: 10, day: 12)

    private var library: [String: ExerciseCandidate] {
        ["squat": ExerciseCandidate(slug: "squat", pattern: .squat, muscleContributions: [.quads: 0.6, .gluteMax: 0.4],
                                    progressionFamily: "squat", fatigueCost: 1, setupSeconds: 30, loadType: .barbell),
         "pushup": ExerciseCandidate(slug: "pushup", pattern: .pushH, muscleContributions: [.pecs: 1.0],
                                     progressionFamily: "pushup", fatigueCost: 0.8, setupSeconds: 10, loadType: .bodyweight)]
    }

    private func input(cycle: CycleInputs = CycleInputs(events: [], profile: CycleProfile(phaseMode: .noPhases,
                                                                                          noPhaseReason: .userChoice)),
                       history: [String: [ExerciseSession]] = [:],
                       stretch: Set<CalendarDay> = [], skipped: Set<CalendarDay> = []) -> Mapping.ProgressInputs {
        let completed = [
            CompletedWorkout(id: "w1", plannedDayID: nil, date: monday, performedAt: Timestamp(hoursSinceEpoch: 1),
                             setsBySlug: ["squat": 4, "pushup": 3]),
            CompletedWorkout(id: "w2", plannedDayID: nil, date: monday.adding(days: 7),
                             performedAt: Timestamp(hoursSinceEpoch: 2), setsBySlug: ["squat": 2]),
        ]
        return Mapping.ProgressInputs(
            from: monday, to: monday.adding(days: 9), today: monday.adding(days: 9), level: .intermediate,
            goal: .hypertrophy, equipment: EquipmentProfile(platesKg: [1.25, 2.5, 5, 10], barbellKg: 20),
            library: library, completed: completed, history: history, stretchDays: stretch, skippedDays: skipped,
            cycle: cycle)
    }

    @Test("недели: объём по группам из weekDoneVolume, текущая — partial")
    func weeks() {
        let body = Mapping.progress(input())
        #expect(body.weeks.map(\.weekStart) == ["2026-10-12", "2026-10-19"])
        #expect(body.weeks.map(\.partial) == [false, true])
        #expect(body.weeks[0].groups["legs_glutes"] == 4 * (1 + 0.4 / 0.6))
        #expect(body.weeks[0].groups["chest"] == 3)
        #expect(body.weeks[1].groups["chest"] == 0)
        #expect(Set(body.weeks[0].groups.keys) == Set(MuscleGroup.allCases.map(\.rawValue)))
        #expect(body.groupNorms.first { $0.group == "chest" }?.norm == 10)
        #expect(body.groupNorms.first { $0.group == "chest" }?.name == "Грудь")
    }

    @Test("календарь: силовая, растяжка, пропуск; стрик по неделям")
    func days() {
        let stretchDay = monday.adding(days: 2)
        let skippedDay = monday.adding(days: 4)
        let body = Mapping.progress(input(stretch: [stretchDay], skipped: [skippedDay]))
        #expect(body.days.count == 10)
        #expect(body.days[0].strength && !body.days[0].stretch)
        #expect(body.days[2].stretch && !body.days[2].strength)
        #expect(body.days[4].skipped)
        #expect(body.days[1] == ProgressDayDTO(date: "2026-10-13", strength: false, stretch: false, skipped: false, phase: nil))
        #expect(body.streakWeeks == 2)
    }

    @Test("фаза — как знали в тот день: позднее событие прошлое не перекрашивает")
    func phaseAsKnown() {
        let profile = CycleProfile(typicalCycleLengthDays: 28, typicalPeriodLengthDays: 5,
                                   declaredRegularity: .regular, phaseMode: .phases)
        let early = CycleEvent(kind: .periodStart, occurredOn: monday.adding(days: -2))
        let late = CycleEvent(kind: .periodStart, occurredOn: monday.adding(days: 8))
        let withLate = Mapping.progress(input(cycle: CycleInputs(events: [early, late], profile: profile)))
        let withoutLate = Mapping.progress(input(cycle: CycleInputs(events: [early], profile: profile)))
        #expect(withLate.days.prefix(8).map(\.phase) == withoutLate.days.prefix(8).map(\.phase))
        #expect(withLate.days[0].phase == "menstrual")
        let noPhases = Mapping.progress(input())
        #expect(noPhases.days.allSatisfy { $0.phase == nil })
    }

    @Test("базовая линия: только упражнения с весом и с точками в окне")
    func baselines() {
        let set = SetResult(prescribedKg: 40, actualKg: 40, actualReps: 10, feedback: .ok)
        let squat = [ExerciseSession(performedAt: monday, weightReadiness: 1, isCalibration: false, sets: [set, set])]
        let push = [ExerciseSession(performedAt: monday, weightReadiness: 1, isCalibration: false,
                                    sets: [SetResult(prescribedKg: nil, actualKg: nil, actualReps: 12, feedback: .ok)])]
        let body = Mapping.progress(input(history: ["squat": squat, "pushup": push]))
        #expect(body.baselines.map(\.slug) == ["squat"])
        #expect(body.baselines.first?.points.first?.date == "2026-10-12")
    }

    @Test("старт растяжки: шаблон из контента у самостоятельной, без шаблона у заминки")
    func validateStart() throws {
        let library = try Content.loadBundled()
        let day = DayContext(date: "2026-10-19", tz: "Europe/Moscow")
        let id = UUID().uuidString
        #expect(throws: Never.self) {
            _ = try StretchRoutes.validate(StartStretchSessionRequest(id: id, kind: "standalone",
                                                                      templateSlug: "hip_opening", day: day), library: library)
            _ = try StretchRoutes.validate(StartStretchSessionRequest(id: id, kind: "static_cooldown",
                                                                      templateSlug: nil, day: day), library: library)
        }
        for bad in [StartStretchSessionRequest(id: id, kind: "standalone", templateSlug: nil, day: day),
                    StartStretchSessionRequest(id: id, kind: "standalone", templateSlug: "nope", day: day),
                    StartStretchSessionRequest(id: id, kind: "static_cooldown", templateSlug: "hip_opening", day: day),
                    StartStretchSessionRequest(id: id, kind: "mobility_warmup", templateSlug: nil, day: day),
                    StartStretchSessionRequest(id: "not-a-uuid", kind: "standalone", templateSlug: "hip_opening", day: day)] {
            #expect(throws: APIError.self) { _ = try StretchRoutes.validate(bad, library: library) }
        }
    }
}
