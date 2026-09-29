//  Сборка входов FitCore из срезов (SPEC §7.1, §20.3, §20.6, §20.15 20l).
//
//  Здесь проверяется то, ради чего слой существует: что собранный вход даёт те
//  же числа, что дала сборка недели. §20.15 20l требует этого через роут; до
//  роутов утверждение проверяется на самом слое, и это не замена, а его
//  предшественник — как 20k для 20a.

import Testing
import FitCore
import FitContent
@testable import FitServer

@Suite("Mapping: сборка WeekContext и PrescriptionInput (§20.6)")
struct MappingAssemblyTests {

    private let weekStart = CalendarDay(year: 2026, month: 9, day: 28)   // понедельник
    private let userSeed: UInt64 = 12_345

    private var library: [ExerciseCandidate] {
        [
            ExerciseCandidate(slug: "goblet_squat", pattern: .squat,
                              muscleContributions: [.quads: 0.6, .gluteMax: 0.4],
                              progressionFamily: "squat", fatigueCost: 1.0,
                              setupSeconds: 20, loadType: .dumbbell),
            ExerciseCandidate(slug: "romanian_deadlift_db", pattern: .hinge,
                              muscleContributions: [.hamstrings: 0.5, .gluteMax: 0.4, .erectors: 0.1],
                              progressionFamily: "hinge", fatigueCost: 1.0,
                              setupSeconds: 20, loadType: .dumbbell),
            ExerciseCandidate(slug: "plank", pattern: .core,
                              muscleContributions: [.abs: 0.7, .obliques: 0.3],
                              progressionFamily: "plank", fatigueCost: 0.5,
                              setupSeconds: 10, loadType: .bodyweight)
        ]
    }

    private var vectors: DayVectorTable {
        DayVectorTable([DayVector(key: DayVectorKey(kind: .lower, accent: .gluteMax),
                                  shares: [.gluteMax: 0.5, .quads: 0.3, .hamstrings: 0.2])])
    }

    private var equipment: Mapping.EquipmentSlice {
        Mapping.equipment(from: Mapping.EquipmentRow(dumbbellsKg: [8, 10, 12, 14, 16, 18, 20]))
    }

    private var profile: Mapping.CompleteProfile {
        Mapping.CompleteProfile(level: .intermediate, goal: .hypertrophy, trainingWeekdays: [1, 3, 5])
    }

    private var cycle: CycleInputs {
        CycleInputs(events: [], profile: Mapping.cycleProfile(from: nil, tracking: .off))
    }

    private func days() -> [Mapping.PlannedDayRow] {
        [Mapping.PlannedDayRow(id: "d1", date: weekStart, sessionKind: "lower",
                               accentMuscle: "glute_max")]
    }

    private func context(today: CalendarDay? = nil,
                         fatigue: [MuscleSlug: FatigueState] = [:]) -> WeekContext {
        Mapping.weekContext(
            weekStart: weekStart, today: today ?? weekStart, days: days(), vectors: vectors,
            library: library, profile: profile, sessionMinutes: 45, equipment: equipment,
            safety: SafetyProfile(level: .intermediate, restrictions: [], painEvents: [],
                                  isConservative: false),
            cycle: cycle, checkin: DailyCheckin(), override: nil, fatigue: fatigue,
            journal: [], completed: [], completedSets: [:], startedDayIDs: [],
            isDeloadWeek: false, userSeed: userSeed)
    }

    // MARK: - Вектор дня (обязанность 15)

    @Test("вектор приходит из FitContent, а не из колонки")
    func vectorComesFromContent() throws {
        let week = Mapping.plannedDays(from: days(), vectors: vectors)
        #expect(week[0].vector[.gluteMax] == 0.5)
        #expect(week[0].isStrength)
    }

    @Test("пары без вектора дают пустой словарь, а дыру называет планировщик")
    func missingVectorIsReportedByThePlanner() throws {
        let rows = [Mapping.PlannedDayRow(id: "d1", date: weekStart, sessionKind: "push")]
        let week = Mapping.plannedDays(from: rows, vectors: vectors)
        #expect(week[0].vector.isEmpty)

        var ctx = context()
        ctx.week = week
        let plan = Planner.planRemainingDays(ctx)
        #expect(plan.days["d1"]?.kind == .vectorMissing)
        #expect(plan.days["d1"]?.cause == .markupMissing)
        #expect(plan.statusLines.contains { if case .dayVectorMissing = $0 { return true }; return false },
                "строка статуса недели печатается штатно (§7.3, правило 4)")
    }

    @Test("день с нераспознанным типом исчезает из недели — это заметно")
    func unknownKindIsDropped() {
        let rows = [Mapping.PlannedDayRow(id: "d1", date: weekStart, sessionKind: "кардио")]
        #expect(Mapping.plannedDays(from: rows, vectors: vectors).isEmpty)
    }

    // MARK: - 20l: пересобранный вход даёт те же числа

    /// То самое утверждение, ради которого §20.15 завёл 20l. Узкий тип защищает
    /// от чтения лишнего поля, но не от того, что девять оставшихся посчитаны
    /// иначе, чем их считала сборка.
    @Test("на НЕИЗМЕНЁННОМ утомлении предписание не двигает ни одного из трёх чисел")
    func prescriptionOnSameFatigueChangesNothing() throws {
        let fatigue: [MuscleSlug: FatigueState] = [
            .quads: FatigueState(value: 1.2, updatedAt: Timestamp(hoursSinceEpoch: 0)),
            .gluteMax: FatigueState(value: 0.9, updatedAt: Timestamp(hoursSinceEpoch: 0))
        ]
        let ctx = context(fatigue: fatigue)
        let plan = Planner.planRemainingDays(ctx)
        let built = try #require(plan.sessions["d1"], "фикстура: день собрался")

        // Момент — ровно тот, на который собиралась сессия: 12:00 дня (§7.1).
        let noon = Planner.evaluationMoment(for: weekStart)
        let input = Mapping.prescriptionInput(
            day: ctx.week[0], startMoment: noon, library: library, profile: profile,
            equipment: equipment, safety: ctx.safety, cycle: cycle,
            checkin: DailyCheckin(), override: nil, fatigue: fatigue, journal: [])
        let prescribed = try #require(Planner.prescribe(built, on: input))

        #expect(prescribed.exercises.map(\.targetRIR) == built.exercises.map(\.targetRIR))
        #expect(prescribed.exercises.map(\.weightReadiness) == built.exercises.map(\.weightReadiness))
        #expect(prescribed.exercises.map(\.prescribedKg) == built.exercises.map(\.prescribedKg))
        #expect(prescribed == built, "и сессия целиком та же")
    }

    @Test("на утомлении другого момента меняются числа, но не состав")
    func laterStartChangesNumbersOnly() throws {
        let fatigue: [MuscleSlug: FatigueState] = [
            .quads: FatigueState(value: 2.0, updatedAt: Timestamp(hoursSinceEpoch: 0)),
            .gluteMax: FatigueState(value: 2.0, updatedAt: Timestamp(hoursSinceEpoch: 0))
        ]
        let ctx = context(fatigue: fatigue)
        let built = try #require(Planner.planRemainingDays(ctx).sessions["d1"])

        let evening = Planner.evaluationMoment(for: weekStart).adding(hours: 7)
        let input = Mapping.prescriptionInput(
            day: ctx.week[0], startMoment: evening, library: library, profile: profile,
            equipment: equipment, safety: ctx.safety, cycle: cycle,
            checkin: DailyCheckin(), override: nil, fatigue: fatigue, journal: [])
        let prescribed = try #require(Planner.prescribe(built, on: input))

        #expect(prescribed.exercises.map(\.slug) == built.exercises.map(\.slug), "состав по 12:00")
        #expect(prescribed.exercises.map(\.targetSets) == built.exercises.map(\.targetSets))
    }

    @Test("утомление в WeekContext не продекано: распад делает планировщик")
    func weekContextFatigueIsUndecayed() {
        let states: [MuscleSlug: FatigueState] = [
            .quads: FatigueState(value: 2.0, updatedAt: Timestamp(hoursSinceEpoch: 0))
        ]
        #expect(context(fatigue: states).fatigue[.quads]?.value == 2.0,
                "продеканное здесь применило бы распад дважды (§20.6)")
    }

    // MARK: - Обязанность 13: current_rep_* только из сессии

    @Test("диапазоны для exercise_states берутся из PrescribedExercise, а не своим repRange")
    func repRangesComeFromTheSession() throws {
        let ctx = context()
        let built = try #require(Planner.planRemainingDays(ctx).sessions["d1"])
        let updates = Mapping.repRangeUpdates(for: built)

        #expect(Set(updates.keys) == Set(built.exercises.map(\.slug)),
                "только упражнения сессии: колонки — снимок последней, а не текущее значение")
        for exercise in built.exercises {
            #expect(updates[exercise.slug] == exercise.targetRepMin...exercise.targetRepMax)
        }
    }

    // MARK: - Профиль доезжает до сетки

    @Test("дни профиля превращаются в даты, из которых сетка §7.2 строит типы")
    func weekdaysReachTheGrid() {
        let dates = Mapping.trainingDates(weekStart: weekStart, weekdays: profile.trainingWeekdays)
        let grid = Planner.weekGrid(days: dates, level: profile.level)
        #expect(grid.count == 3)
        #expect(grid.map(\.date) == dates)
        #expect(grid.map(\.kind) == [.upper, .lower, .fullBody], "три дня, не новичок (§7.2)")
    }
}
