//  Журнал, утомление и выполненные тренировки (SPEC §20.6, обязанности
//  2, 6, 7, 8, 9, 12).
//
//  Шесть обязанностей одного рода: величина считается, а не перекладывается, и
//  ошибка в каждой тихая. Поэтому тесты проверяют следствия — что распад не
//  применяется дважды, что калибровочный подход не попал в объём, что свёртка
//  получила готовность упражнения, а не дня.

import Testing
import FitCore
import FitContent
@testable import FitServer

@Suite("Mapping: журнал, утомление, выполненные (§20.6)")
struct MappingJournalTests {

    private let day = CalendarDay(year: 2026, month: 9, day: 29)

    /// Упражнение со «своей» стоимостью утомления: 1.0 не отличило бы
    /// произведение от вклада.
    private var squat: ExerciseCandidate {
        ExerciseCandidate(slug: "goblet_squat", pattern: .squat,
                          muscleContributions: [.quads: 0.6, .gluteMax: 0.4],
                          progressionFamily: "squat", fatigueCost: 1.5,
                          setupSeconds: 20, loadType: .dumbbell)
    }

    private func set(_ feedback: String? = "ok", reps: Int? = 10, kg: Double? = 20,
                     skipped: Bool = false, calibration: Bool = false,
                     readiness: Double = 1.0, on date: CalendarDay? = nil) -> Mapping.SetRow {
        Mapping.SetRow(exerciseSlug: "goblet_squat", prescribedKg: kg, actualKg: kg,
                       actualReps: reps, feedback: feedback, skipped: skipped,
                       isCalibration: calibration, weightReadiness: readiness,
                       performedOn: date ?? day)
    }

    // MARK: - Обязанность 2: muscleLoad — это произведение

    @Test("muscleLoad = вклад мышцы × fatigue_cost, а не вклад")
    func muscleLoadIsTheProduct() throws {
        let fatigueSet = try #require(Mapping.fatigueSet(from: set(), candidate: squat))
        #expect(fatigueSet.muscleLoad[.quads] == 0.6 * 1.5)
        #expect(fatigueSet.muscleLoad[.gluteMax] == 0.4 * 1.5)
        #expect(fatigueSet.feedback == .ok)
    }

    @Test("вклады берутся сырые, а не эффективные")
    func rawContributionsNotEffective() throws {
        // Эффективные нормированы на ведущую мышцу: quads стали бы 1.0.
        // §8.1 считает по сырым, §7.4 — по эффективным, и смешать их значит
        // завысить утомление всех неведущих мышц.
        let fatigueSet = try #require(Mapping.fatigueSet(from: set(), candidate: squat))
        #expect(fatigueSet.muscleLoad[.quads] != 1.0 * 1.5)
        #expect(squat.effectiveContributions[.quads] == 1.0, "фикстура: эффективный вклад ведущей — 1.0")
    }

    // MARK: - Обязанность 9: калибровка вне утомления и вне неделя[m]

    @Test("калибровочный подход в утомление не идёт (§9.8)")
    func calibrationSetsAreOutOfFatigue() {
        #expect(Mapping.fatigueSet(from: set(calibration: true), candidate: squat) == nil)
    }

    @Test("пропущенный подход и подход без фидбэка в утомление не идут")
    func skippedAndUnfeedbackedAreOut() {
        #expect(Mapping.fatigueSet(from: set(skipped: true), candidate: squat) == nil)
        #expect(Mapping.fatigueSet(from: set(nil), candidate: squat) == nil)
        #expect(Mapping.fatigueSet(from: set("превосходно"), candidate: squat) == nil)
    }

    @Test("калибровочные и пропущенные подходы не идут в неделя[m]")
    func calibrationAndSkippedAreOutOfWeeklyVolume() {
        let rows = [Mapping.CompletedWorkoutRow(id: "w1", plannedDayID: "d1", date: day,
                                                performedAt: Timestamp(hoursSinceEpoch: 100))]
        let completed = Mapping.completedWorkouts(rows: rows, sets: ["w1": [
            set(), set(), set(calibration: true), set(skipped: true), set(nil)
        ]])
        #expect(completed[0].setsBySlug == ["goblet_squat": 2],
                "два честных подхода из пяти строк")
    }

    // MARK: - Обязанность 12: performedAt из finished_at

    @Test("performedAt служит только порядку и берётся из одной колонки")
    func performedAtOrdersWorkouts() {
        let rows = [
            Mapping.CompletedWorkoutRow(id: "w1", plannedDayID: nil, date: day,
                                        performedAt: Timestamp(hoursSinceEpoch: 100)),
            Mapping.CompletedWorkoutRow(id: "w2", plannedDayID: nil, date: day,
                                        performedAt: Timestamp(hoursSinceEpoch: 130))
        ]
        let completed = Mapping.completedWorkouts(rows: rows, sets: [:])
        let latest = completed.max { $0.performedAt < $1.performedAt }
        #expect(latest?.id == "w2", "слагаемое w6 §7.3 ищет последнюю выполненную")
    }

    // MARK: - Обязанность 6: два утомления означают разное

    @Test("срез отдаёт состояние ДО распада, декание — отдельный вызов")
    func fatigueIsUndecayedUntilAsked() throws {
        let states = Mapping.fatigue(from: [
            Mapping.FatigueRow(muscle: "quads", value: 2.0, updatedAt: Timestamp(hoursSinceEpoch: 0))
        ])
        let quads = try #require(states[.quads])
        #expect(quads.value == 2.0, "значение колонки, без распада")
        #expect(quads.updatedAt == Timestamp(hoursSinceEpoch: 0))

        let decayed = Mapping.decayedFatigue(states, to: Timestamp(hoursSinceEpoch: 20))
        #expect((decayed[.quads] ?? 0) < 2.0, "распад применяется тем, кто знает момент")
    }

    @Test("двойное декание заметно и потому разведено по именам")
    func decayingTwiceIsVisiblyWrong() {
        let states = Mapping.fatigue(from: [
            Mapping.FatigueRow(muscle: "quads", value: 2.0, updatedAt: Timestamp(hoursSinceEpoch: 0))
        ])
        let once = Mapping.decayedFatigue(states, to: Timestamp(hoursSinceEpoch: 20))
        // Если бы продеканное значение положили в WeekContext, планировщик
        // продекал бы его ещё раз — вот во что это обходится.
        let asIfStored = [MuscleSlug.quads: FatigueState(value: once[.quads] ?? 0,
                                                         updatedAt: Timestamp(hoursSinceEpoch: 0))]
        let twice = Mapping.decayedFatigue(asIfStored, to: Timestamp(hoursSinceEpoch: 20))
        #expect((twice[.quads] ?? 0) < (once[.quads] ?? 0) * 0.9,
                "второй распад съедает ещё столько же — и не падает")
    }

    @Test("неизвестная мышца в колонке не попадает в состояние")
    func unknownMuscleIsDropped() {
        #expect(Mapping.fatigue(from: [
            Mapping.FatigueRow(muscle: "поясница", value: 1, updatedAt: Timestamp(hoursSinceEpoch: 0))
        ]).isEmpty)
    }

    // MARK: - Обязанности 7 и 8: сырой журнал и правильная готовность

    @Test("журнал группируется по (упражнение, день) и несёт сырые подходы")
    func historyIsGroupedRaw() throws {
        let history = Mapping.exerciseHistory(from: [
            set(kg: 20), set(kg: 20), set(kg: 22, on: day.adding(days: 2))
        ])
        let sessions = try #require(history["goblet_squat"])
        #expect(sessions.count == 2, "две сессии — два дня")
        #expect(sessions[0].sets.count == 2)
        #expect(sessions[1].sets.count == 1)
        #expect(sessions[0].sets[0].actualKg == 20)
    }

    @Test("weightReadiness берётся из workout_exercises, а не из workouts")
    func weightReadinessComesFromTheExerciseRow() throws {
        // §20.6 называет это самой лёгкой молчаливой подменой во всём слое:
        // обе колонки numeric, обе «готовность», и демпфирование §9.6 читает
        // только эту. На дневной базовая линия поедет — не упадёт, поедет.
        let history = Mapping.exerciseHistory(from: [set(readiness: 1.1)])
        let session = try #require(history["goblet_squat"]?.first)
        #expect(session.weightReadiness == 1.1)
    }

    @Test("калибровочные подходы ОСТАЮТСЯ в журнале")
    func calibrationStaysInTheJournal() throws {
        // В отличие от утомления и неделя[m]: §9.8 выводит из калибровки по
        // журналу калибровочных же подходов, и без них свёртка не узнает, что
        // калибровка кончилась.
        let history = Mapping.exerciseHistory(from: [set(calibration: true), set(calibration: true)])
        let sessions = try #require(history["goblet_squat"])
        #expect(sessions.count == 1)
        #expect(sessions[0].isCalibration)
        #expect(sessions[0].sets.count == 2)
    }

    @Test("подходы разной калибровочности одного дня не смешиваются в одну сессию")
    func calibrationSplitsSessions() throws {
        let history = Mapping.exerciseHistory(from: [set(calibration: true), set(calibration: false)])
        #expect(history["goblet_squat"]?.count == 2)
    }

    @Test("пропущенные и безфидбэковые подходы в журнал не попадают")
    func skippedIsNotHistory() {
        #expect(Mapping.exerciseHistory(from: [set(skipped: true), set(nil)]).isEmpty)
    }

    @Test("журнал годится как вход свёртки: состояние считается на текущей лестнице")
    func historyFeedsTheFold() throws {
        // Тот самый довод §20.6, по которому отдаётся журнал, а не состояния:
        // лестница берётся ТЕКУЩАЯ, и смена инвентаря пересчитывает базовую
        // линию, а не наследует посчитанную на прежней.
        let history = Mapping.exerciseHistory(from: [
            set(kg: 20, readiness: 1.0), set(kg: 20, readiness: 1.0)
        ])
        let states = Planner.exerciseStates(history: history, library: [squat], goal: .hypertrophy,
                                            equipment: EquipmentProfile(dumbbellsKg: [16, 18, 20, 22]))
        #expect(states["goblet_squat"] != nil, "свёртка приняла сырой журнал")
    }
}
