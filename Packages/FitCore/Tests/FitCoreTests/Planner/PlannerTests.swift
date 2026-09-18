//  Planner — сценарии SPEC §18, закрытые этим модулем: 27, 27a–27h, 28, 29,
//  29a–29c, 30, 30a, 31, 31a–31c, 32, 32a–32e, 33, 33a. Плюс планировщиковые
//  части 25 (оверрайд не снимает защиту утомления) и 26 (беременность отключает
//  генератор), которые Recovery.swift и Cycle.swift оставили планировщику.
//
//  Контракт, на который сценарии опираются (инвентарь §6.6, жёсткие ограничения,
//  время, S_эфф, §7.6), помечен `// MARK: - Контракт`, а многосессионная
//  симуляция (implement-feature §5а) — `// MARK: - Симуляция`.
//
//  Все тесты — на синтетике PlannerFixtures (planner-domain §4) с фиксированным
//  seed. XCTest, а не Swift Testing — окружение только с Command Line Tools
//  (`swift test` падает на `no such module`), логика прогнана вручную через
//  временный executable, см. implement-feature §5.

import XCTest
@testable import FitCore

final class PlannerTests: XCTestCase {

    private typealias F = PlannerFixtures

    /// Журнал для тестов, которым он не важен: они проверяют состав и статусы,
    /// а не предписанный вес.
    ///
    /// ВНИМАНИЕ: это свойство НАМЕРЕННО выбрасывает всё, что дописывает
    /// `F.perform`, — каждый `get` возвращает свежий журнал, `set` игнорируется.
    /// В многосессионном тесте так делать нельзя: `lastPerformedAt` стоит на
    /// месте, с третьей недели включается детренированность §9.7, и прогон
    /// молча уезжает вниз, ничего не заваливая (ровно то, чем была находка 3
    /// второго ревью). Для таких тестов — `F.weightedHistory()` в локальной
    /// `var history`, которую `F.perform` пополняет, как в
    /// `test_simulation_sixWeeksOfFiveGluteDays_noDriftNoOvershoot`.
    private var throwawayHistory: [String: [ExerciseSession]] {
        get { F.familiarHistory(for: F.library) }
        set { _ = newValue }
    }

    private func build(_ input: SessionInput) -> BuiltSession {
        guard let session = Planner.buildSession(input) else {
            XCTFail("сессия не собрана")
            return BuiltSession(dayID: "", exercises: [], estimatedSeconds: 0, effectiveVolume: [:],
                                leadingMuscle: nil, scale: 0, reasons: [])
        }
        return session
    }

    private func patterns(_ session: BuiltSession, in library: [ExerciseCandidate] = PlannerFixtures.library) -> Set<Pattern> {
        Set(session.exercises.compactMap { e in library.first { $0.slug == e.slug }?.pattern })
    }

    private var twoGluteDays: [PlannedDay] {
        F.week([(.lower, .gluteMax, F.lowerGlutes), (.lower, .gluteMax, F.lowerGlutes)], offsets: [0, 3])
    }

    /// Прогон недели через планировщик: каждый день собирается от состояния,
    /// оставленного выполнением предыдущих (§7.1, замороженное состояние).
    private func runWeek(
        _ week: [PlannedDay],
        minutes: Int,
        weights: PlannerWeights = .spec,
        skip: Set<Int> = [],
        library: [ExerciseCandidate] = PlannerFixtures.library,
        availability: EquipmentAvailability = PlannerFixtures.fullAvailability,
        equipment: EquipmentProfile = PlannerFixtures.fullEquipment,
        history: [String: [ExerciseSession]]? = nil
    ) -> (sessions: [BuiltSession], volume: [MuscleSlug: Double]) {
        var week = week
        var completed: [CompletedWorkout] = []
        var fatigue: [MuscleSlug: FatigueState] = [:]
        var history = history ?? PlannerFixtures.familiarHistory(for: library)
        var sessions: [BuiltSession] = []
        var volume: [MuscleSlug: Double] = [:]
        for i in week.indices {
            if skip.contains(i) { week[i].status = .skipped; continue }
            let ctx = F.context(week: week, library: library, availability: availability, equipment: equipment,
                                history: history, today: week[i].date, completed: completed, fatigue: fatigue,
                                minutes: minutes, weights: weights)
            guard let session = Planner.planRemainingDays(ctx).sessions[week[i].id] else { continue }
            sessions.append(session)
            for (m, v) in session.effectiveVolume { volume[m, default: 0] += v }
            F.perform(session, on: week[i].date, completed: &completed, fatigue: &fatigue, library: library, history: &history)
            week[i].status = .done
        }
        return (sessions, volume)
    }

    // MARK: - Сценарий 25: оверрайд push при переутомлении — защита утомления не снята

    func test_scenario25_pushOverrideDoesNotLiftFatigueProtection() {
        let cycle = CycleInputs(events: [], profile: CycleProfile(phaseMode: .noPhases, noPhaseReason: .userChoice))
        let week = F.week([(.lower, .gluteMax, F.lowerGlutes)])
        let fatigue: [MuscleSlug: FatigueState] = [
            .gluteMax: FatigueState(value: 5.0, updatedAt: Planner.evaluationMoment(for: F.day(0))),
        ]
        let fresh = Planner.planRemainingDays(F.context(week: week, cycle: cycle, override: .push)).sessions["day0"]!
        let tired = Planner.planRemainingDays(F.context(week: week, fatigue: fatigue, cycle: cycle, override: .push)).sessions["day0"]!

        for e in tired.exercises where (F.candidate(e.slug).muscleContributions[.gluteMax] ?? 0) > 0 {
            XCTAssertLessThanOrEqual(e.weightReadiness, 1.0, "надбавка готовности к весу срезана на утомлённой мышце: \(e.slug)")
            let freshRIR = fresh.exercises.first { $0.slug == e.slug }?.targetRIR
            if let freshRIR { XCTAssertEqual(e.targetRIR, freshRIR + 1, "надбавка RIR утомления сверх push: \(e.slug)") }
        }
        XCTAssertLessThan(tired.effectiveVolume[.gluteMax] ?? 0, fresh.effectiveVolume[.gluteMax] ?? 0,
                          "объём на утомлённую мышцу срезан, push его не вернул")
    }

    // MARK: - Сценарий 26 (часть планировщика): беременность отключает генератор

    /// §14.3 выключает генератор, и «тренировка без упражнений» — это не он:
    /// пустая сессия в плане выглядит как обычный день, у которого просто
    /// ничего не подобралось. День получает свой итог и причину на уровне недели.
    func test_scenario26_pregnancyDisablesGenerator() {
        let pregnant = CycleState(phaseMode: .noPhases, noPhaseReason: .pregnancy, hasAnchor: false, phase: nil,
                                  cycleConfidence: nil, periodization: nil, effectivePhaseAdjustment: nil)
        XCTAssertNil(Planner.buildSession(F.input(week: twoGluteDays, cycleState: pregnant)),
                     "сборка одного дня не возвращает пустую тренировку")

        let cycle = CycleInputs(events: [], profile: CycleProfile(phaseMode: .noPhases, noPhaseReason: .pregnancy))
        let plan = Planner.planRemainingDays(F.context(week: twoGluteDays, cycle: cycle))
        XCTAssertTrue(plan.sessions.isEmpty, "в плане недели тренировок нет")
        XCTAssertEqual(plan.days["day0"]?.kind, .generatorDisabled)
        XCTAssertEqual(plan.days["day0"]?.cause, .pregnancy)
        XCTAssertFalse(plan.days["day0"]?.losesPlannedVolume ?? true, "это не потеря объёма — генератор выключен")
        XCTAssertTrue(plan.statusLines.contains(.workoutGenerationDisabled),
                      "причина видна на уровне недели, а не только внутри сессии")
    }

    // MARK: - Сценарий 27: ягодицы 5 дней подряд — объём режется, паттерны меняются, не блокируется

    func test_scenario27_fiveGluteDays_volumeCutCompositionChangesNeverBlocked() {
        let week = F.week(Array(repeating: (.lower, .gluteMax, F.lowerGlutes), count: 5))
        let run = runWeek(week, minutes: 45)
        XCTAssertEqual(run.sessions.count, 5)
        XCTAssertTrue(run.sessions.allSatisfy { !$0.exercises.isEmpty }, "ни один день не пустой")
        for (a, b) in zip(run.sessions, run.sessions.dropFirst()) {
            XCTAssertNotEqual(F.slugs(a), F.slugs(b), "состав меняется день ко дню")
        }

        // Пятый день с утомлением против того же дня без утомления: RIR выше,
        // эффективный объём на ягодичные не больше.
        var completed: [CompletedWorkout] = []
        var fatigue: [MuscleSlug: FatigueState] = [:]
        var days = week
        for i in 0..<4 {
            F.perform(run.sessions[i], on: F.day(i), completed: &completed, fatigue: &fatigue, history: &throwawayHistory)
            days[i].status = .done
        }
        let moment = Planner.evaluationMoment(for: F.day(4))
        let decayed = Dictionary(uniqueKeysWithValues: fatigue.map { ($0.key, Recovery.decayed($0.value, to: moment, muscle: $0.key)) })
        let tired = Planner.buildSession(F.input(week: days, dayIndex: 4, minutes: 45, fatigue: decayed))!
        let rested = Planner.buildSession(F.input(week: days, dayIndex: 4, minutes: 45))!
        XCTAssertGreaterThan(decayed[.gluteMax] ?? 0, 1.8,
                             "фикстура: к пятому дню ягодичные не восстановлены")
        XCTAssertLessThanOrEqual(tired.effectiveVolume[.gluteMax] ?? 0, (rested.effectiveVolume[.gluteMax] ?? 0) + 1e-9)
        let tiredRIR = tired.exercises.filter { F.candidate($0.slug).muscleContributions[.gluteMax] != nil }.map(\.targetRIR)
        XCTAssertFalse(tiredRIR.isEmpty)
        XCTAssertTrue(tiredRIR.allSatisfy { $0 == 1 + 1 }, "RIR +1 на упражнениях, нагружающих ягодичные (§8.3, п.1)")
    }

    // MARK: - Сценарий 27a: недельный glute_max не выше потолка, состав меняется, дни не пустые

    // Расхождение со SPEC §7.4, не исправленное в спеке: там «17.5 за пять дней
    // ягодиц подряд» — число раннего прототипа. На калибровочной библиотеке
    // текущий алгоритм без утомления даёт 16.7, на этих фикстурах с утомлением —
    // 18.8. Тест держит утверждение сценария (не выше потолка), а не число.

    func test_scenario27a_fiveGluteDays_weeklyVolumeWithinCeiling() {
        let week = F.week(Array(repeating: (.lower, .gluteMax, F.lowerGlutes), count: 5))
        let run = runWeek(week, minutes: 45)
        let ceiling = Planner.weeklyRange(level: .intermediate, accented: true).upperBound
        XCTAssertLessThanOrEqual(run.volume[.gluteMax] ?? 0, ceiling)
        XCTAssertGreaterThan(Set(run.sessions.map { F.slugs($0) }).count, 1, "состав меняется")
        XCTAssertTrue(run.sessions.allSatisfy { !$0.exercises.isEmpty })
    }

    // MARK: - Сценарий 27b: плоский full body 2 × 45 — ни одной мышцы вектора с нулём

    func test_scenario27b_flatFullBody_everyVectorMuscleGetsWork() {
        let week = F.week([(.fullBody, nil, F.flatFullBody), (.fullBody, nil, F.flatFullBody)], offsets: [0, 3])
        let run = runWeek(week, minutes: 45)
        for m in F.flatFullBody.keys {
            XCTAssertGreaterThanOrEqual(run.volume[m] ?? 0, 1.0, "мышца вектора без эффективного подхода: \(m)")
        }
    }

    // MARK: - Сценарий 27c: «низ с акцентом» 60/45/30 — w11 не забирает акцентный день

    /// На калибровочной библиотеке, а не на PlannerFixtures: почему — в
    /// комментарии к PlannerCalibrationFixtures (ничья в богатом пуле, зависимость
    /// от пути, не дефект). Дни — через два и через один, с утомлением между ними.
    func test_scenario27c_accentWeek_coverageTermKeepsGluteVolume() {
        typealias C = PlannerCalibrationFixtures
        var noCoverage = PlannerWeights()
        noCoverage.w11 = 0
        for offsets in [[0, 3], [0, 2]] {
            let week = F.week([(.lower, .gluteMax, F.lowerGlutes), (.lower, .gluteMax, F.lowerGlutes)], offsets: offsets)
            for minutes in [60, 45, 30] {
                let with = runWeek(week, minutes: minutes, library: C.library, availability: EquipmentAvailability(),
                                   equipment: EquipmentProfile())
                let without = runWeek(week, minutes: minutes, weights: noCoverage, library: C.library,
                                      availability: EquipmentAvailability(), equipment: EquipmentProfile())
                XCTAssertEqual(with.volume[.gluteMax] ?? 0, without.volume[.gluteMax] ?? 0, accuracy: 1e-9,
                               "дни \(offsets), \(minutes) минут")
            }
        }
    }

    // MARK: - Сценарий 27d: смешанная неделя — нет упражнения ради икр, нулевых мышц не больше

    func test_scenario27d_mixedWeek_noCalfExerciseOnAccentDay_noExtraZeroMuscles() {
        let week = F.week([(.upper, nil, F.upper), (.lower, .gluteMax, F.lowerGlutes), (.fullBody, nil, F.flatFullBody)])
        let at30 = runWeek(week, minutes: 30)
        let accentDay = at30.sessions[1]
        XCTAssertFalse(accentDay.exercises.contains { F.candidate($0.slug).leadingMuscle == .calves },
                       "в дне с акцентом нет упражнения, взятого ради икр")

        var noCoverage = PlannerWeights()
        noCoverage.w11 = 0
        let vectorMuscles = Set(week.flatMap { $0.vector.keys })
        for minutes in [60, 45] {
            let zeros = vectorMuscles.filter { (runWeek(week, minutes: minutes).volume[$0] ?? 0) < 1 }.count
            let zerosWithout = vectorMuscles.filter { (runWeek(week, minutes: minutes, weights: noCoverage).volume[$0] ?? 0) < 1 }.count
            XCTAssertLessThanOrEqual(zeros, zerosWithout, "\(minutes) минут")
        }
    }

    // MARK: - Сценарий 27e: S_эфф дня full body не зависит от порядка; 13.69 в неделе низ+низ

    func test_scenario27e_leadingMuscleByMinimum_andMixedLowerWeek() {
        let mixed = F.week([(.upper, nil, F.upper), (.lower, .gluteMax, F.lowerGlutes), (.fullBody, nil, F.flatFullBody)])
        let fb = Planner.sessionScale(dayIndex: 2, week: mixed, level: .intermediate)!
        XCTAssertEqual(fb.leadingMuscle, .gluteMax)
        XCTAssertEqual(fb.scale, 20.0, accuracy: 1e-9)
        // Тот же вектор, собранный в другом порядке ключей, — тот же масштаб.
        var reordered = mixed
        reordered[2].vector = Dictionary(uniqueKeysWithValues: F.flatFullBody.sorted { $0.key.rawValue > $1.key.rawValue })
        XCTAssertEqual(Planner.sessionScale(dayIndex: 2, week: reordered, level: .intermediate)!.scale, 20.0, accuracy: 1e-9)

        let lowerPair = F.week([(.lower, .gluteMax, F.lowerGlutes), (.lower, nil, F.lower)])
        let planned = lowerPair.indices.reduce(0.0) { sum, i in
            sum + Planner.sessionScale(dayIndex: i, week: lowerPair, level: .intermediate)!.scale * (lowerPair[i].vector[.gluteMax] ?? 0)
        }
        XCTAssertEqual(planned, 13.69, accuracy: 0.005)
    }

    // MARK: - Сценарий 27f: повторы и RIR из цели

    func test_scenario27f_repsAndRIRFromGoal() {
        let novice = build(F.input(week: twoGluteDays, safety: SafetyProfile(level: .novice)))
        XCTAssertTrue(novice.exercises.allSatisfy { $0.targetRIR == 2 && $0.targetRepMin == 8 && $0.targetRepMax == 12 })
        let intermediate = build(F.input(week: twoGluteDays))
        XCTAssertTrue(intermediate.exercises.allSatisfy { $0.targetRIR == 1 })

        var states = F.familiar
        for slug in states.keys { states[slug]!.repExtension = 2 }
        XCTAssertTrue(build(F.input(week: twoGluteDays, states: states)).exercises.allSatisfy { $0.targetRepMax == 14 })

        let general = build(F.input(week: twoGluteDays, goal: .general))
        XCTAssertTrue(general.exercises.allSatisfy { $0.targetRepMin == 10 && $0.targetRepMax == 15 && $0.targetRIR == 2 })

        let conservative = build(F.input(
            week: twoGluteDays, safety: SafetyProfile(level: .intermediate, isConservative: true),
            cycleState: F.phaseState(.lateLuteal, confidence: 1.0), readiness: 0.8))
        XCTAssertFalse(conservative.exercises.isEmpty)
        XCTAssertTrue(conservative.exercises.allSatisfy { $0.targetRIR == 1 + 2 }, "+1 фазы и готовности с потолком и +1 консервативного режима")
    }

    // MARK: - Сценарий 27g: сетка

    func test_scenario27g_weekGrid() {
        let days = (0..<7).map(F.day)
        func kinds(_ n: Int, _ level: ExperienceLevel) -> [SessionKind] {
            Planner.weekGrid(days: Array(days.prefix(n)), level: level).map(\.kind)
        }
        XCTAssertEqual(kinds(3, .novice), [.fullBody, .fullBody, .fullBody])
        XCTAssertEqual(kinds(3, .intermediate), [.upper, .lower, .fullBody])
        XCTAssertEqual(kinds(5, .advanced), [.upper, .lower, .upper, .lower, .fullBody])
        XCTAssertEqual(kinds(6, .intermediate), [.push, .pull, .lower, .upper, .lower, .stretch])
        XCTAssertEqual(kinds(7, .intermediate), [.push, .pull, .lower, .push, .pull, .lower, .stretch])
        XCTAssertEqual(kinds(2, .advanced), [.fullBody, .fullBody])
        XCTAssertEqual(kinds(4, .novice), [.upper, .lower, .upper, .lower])
        let shuffled = Planner.weekGrid(days: [F.day(5), F.day(1), F.day(3), F.day(0), F.day(2), F.day(6)], level: .advanced)
        XCTAssertEqual(shuffled.last?.date, F.day(6), "растяжка — последний выбранный день")
        XCTAssertTrue(shuffled.allSatisfy { $0.accent == nil })
    }

    // MARK: - Сценарий 27h: колонка §7.4 по сессии

    func test_scenario27h_normAndCeilingColumnPerSession() {
        let week = F.week([(.lower, .gluteMax, F.lowerGlutes), (.lower, nil, F.lower)])
        let accentDay = Planner.sessionScale(dayIndex: 0, week: week, level: .intermediate)!
        let plainDay = Planner.sessionScale(dayIndex: 1, week: week, level: .intermediate)!
        XCTAssertEqual(accentDay.scale, 24.62, accuracy: 0.005)
        XCTAssertEqual(plainDay.leadingMuscle, .gluteMax)
        XCTAssertEqual(plainDay.scale, 15.38, accuracy: 0.005)
        XCTAssertEqual(Planner.ceiling(.gluteMax, in: week[0], level: .intermediate), 20)
        XCTAssertEqual(Planner.ceiling(.gluteMax, in: week[1], level: .intermediate), 16)

        // Потолок сверяется с недельной суммой по колонке текущей сессии: при
        // выполненных 16 в дне без акцента цели на glute_max нет, а в акцентный
        // день она ещё есть.
        let plain = build(F.input(week: week, dayIndex: 1, weekDone: [.gluteMax: 16]))
        let accent = build(F.input(week: week, dayIndex: 0, weekDone: [.gluteMax: 16]))
        XCTAssertLessThan(plain.effectiveVolume[.gluteMax] ?? 0, accent.effectiveVolume[.gluteMax] ?? 0)
    }

    // MARK: - Сценарий 28: только резинки, акцент ягодицы — непустая тренировка

    func test_scenario28_bandsOnly_nonEmptyGluteSession() {
        let session = build(F.input(week: twoGluteDays, availability: F.bandsOnly, equipment: EquipmentProfile()))
        XCTAssertFalse(session.exercises.isEmpty)
        for e in session.exercises {
            let c = F.candidate(e.slug)
            XCTAssertTrue(c.equipment.allSatisfy { $0 == .bands }, "\(e.slug) требует не только резинки")
            XCTAssertTrue([.band, .bodyweight, .bodyweightLoaded].contains(c.loadType), "\(e.slug) нужен вес")
        }
        XCTAssertGreaterThan(session.effectiveVolume[.gluteMax] ?? 0, 0)
    }

    // MARK: - Сценарий 29: session_minutes = 20 — укладывается, 3–4 упражнения

    func test_scenario29_twentyMinutes_fitsWithThreeToFourExercises() {
        let session = build(F.input(week: twoGluteDays, minutes: 20))
        XCTAssertLessThanOrEqual(session.estimatedSeconds, 20 * 60)
        XCTAssertTrue((3...4).contains(session.exercises.count), "упражнений: \(session.exercises.count)")
    }

    // MARK: - Сценарий 29a: бюджет не вмещает три паттерна — ослаблено ПО ВРЕМЕНИ

    // Расхождение со SPEC §7.3 и §18 (29a), не исправленное в спеке: «при 14
    // минутах — два упражнения и два паттерна, при 8 — одно» дал прототип, чей
    // ремонт паттернов не проверял, влезает ли упражнение в бюджет. На той же
    // библиотеке при 14 минутах три паттерна по два подхода занимают 12.8 минуты,
    // и жёсткое ограничение требует трёх; при 8 минутах собираются два упражнения
    // одного паттерна. Тест проверяет правило — ослабление по времени с отличимой
    // причиной, бюджет, непустая тренировка — на своих порогах (12 и 6 минут).

    func test_scenario29a_budgetRelaxesPatternsByTime() {
        let session = build(F.input(week: twoGluteDays, minutes: 12))
        XCTAssertLessThan(patterns(session).count, 3)
        XCTAssertTrue(session.reasons.contains { if case .patternMinimumRelaxedByTime = $0 { return true }; return false })
        XCTAssertFalse(session.reasons.contains { if case .patternMinimumRelaxedUnavailable = $0 { return true }; return false },
                       "причина — время, не доступность")
        XCTAssertLessThanOrEqual(session.estimatedSeconds, 12 * 60)
        XCTAssertFalse(session.exercises.isEmpty)

        let tiny = build(F.input(week: twoGluteDays, minutes: 6))
        XCTAssertEqual(tiny.exercises.count, 1)
        XCTAssertLessThanOrEqual(tiny.estimatedSeconds, 6 * 60)
    }

    // MARK: - Сценарий 29b: односторонний подход вдвое дороже по работе

    func test_scenario29b_unilateralDoublesWorkNotRest() {
        var bilateral = F.stepUp
        bilateral.unilateral = false
        let uni = Planner.estimatedSeconds([(F.stepUp, 3)], restFactor: 1)
        let bi = Planner.estimatedSeconds([(bilateral, 3)], restFactor: 1)
        XCTAssertEqual(uni - bi, 3 * Planner.workSecondsPerSet, accuracy: 1e-9)
        XCTAssertEqual(Planner.effectiveVolume([(F.stepUp, 3)]), Planner.effectiveVolume([(bilateral, 3)]),
                       "учёт объёма §7.4 не меняется")

        func setsFitting(_ c: ExerciseCandidate, minutes: Double) -> Int {
            var n = 0
            while Planner.estimatedSeconds([(c, n + 1)], restFactor: 1) <= minutes * 60 { n += 1 }
            return n
        }
        XCTAssertLessThan(setsFitting(F.stepUp, minutes: 10), setsFitting(bilateral, minutes: 10))
    }

    // MARK: - Сценарий 29c: строка недобора по времени — только когда бюджет ограничивает

    func test_scenario29c_timeShortfallLineOnlyWhenBudgetBinds() {
        let tight = Planner.planRemainingDays(F.context(week: twoGluteDays, minutes: 12))
        XCTAssertTrue(tight.statusLines.contains { if case .weekShortfallByTime = $0 { return true }; return false })
        XCTAssertFalse(tight.statusLines.contains { if case .plannedVolumeLoss = $0 { return true }; return false })

        let roomy = Planner.planRemainingDays(F.context(week: twoGluteDays, minutes: 120))
        XCTAssertFalse(roomy.statusLines.contains { if case .weekShortfallByTime = $0 { return true }; return false })
    }

    // MARK: - Контракт: причина ослабления паттернов — лимиты, а не время (ревью, находка 7)

    private func isolation(_ slug: String, _ muscle: MuscleSlug) -> ExerciseCandidate {
        ExerciseCandidate(slug: slug, pattern: .isolation, muscleContributions: [muscle: 1.0],
                          progressionFamily: slug, fatigueCost: 0.4, setupSeconds: 10, defaultRestSeconds: 30, loadType: .bodyweight)
    }

    private func relaxedByTime(_ s: BuiltSession) -> Bool {
        s.reasons.contains { if case .patternMinimumRelaxedByTime = $0 { return true }; return false }
    }

    /// Семь упражнений одного паттерна набраны жадным шагом, ремонту некуда
    /// добавить: «в N минут не помещается» было бы неправдой — тап по
    /// session_minutes этого не решит.
    func test_patternRelaxed_exerciseLimit_notReportedAsTime() {
        let muscles: [MuscleSlug] = [.quads, .gluteMax, .hamstrings, .gluteMed, .pecs, .lats, .trapsMid, .sideDelts]
        let vector = Dictionary(uniqueKeysWithValues: muscles.map { ($0, 0.125) })
        let library = muscles.enumerated().map { isolation("iso_\($0.offset)", $0.element) } + [
            ExerciseCandidate(slug: "off_squat", pattern: .squat, muscleContributions: [.quads: 0.3, .erectors: 0.7],
                              progressionFamily: "off_squat", fatigueCost: 1.0, setupSeconds: 30, loadType: .bodyweight),
            ExerciseCandidate(slug: "off_hinge", pattern: .hinge, muscleContributions: [.hamstrings: 0.3, .erectors: 0.7],
                              progressionFamily: "off_hinge", fatigueCost: 1.0, setupSeconds: 30, loadType: .bodyweight),
        ]
        let session = build(F.input(week: F.week([(.fullBody, nil, vector)]), library: library, minutes: 180,
                                    states: Dictionary(uniqueKeysWithValues: library.map { ($0.slug, ExerciseState(isInCalibration: false)) })))
        XCTAssertEqual(session.exercises.count, Planner.maxExercises, "фикстура: упёрлись в семь")
        XCTAssertLessThan(patterns(session, in: library).count, 3)
        XCTAssertFalse(relaxedByTime(session), "лимит семи упражнений — не время")
        XCTAssertTrue(session.reasons.contains(.patternMinimumRelaxedByLimit(fitted: patterns(session, in: library).count, limit: .exerciseCount)))
        XCTAssertFalse(session.reasons.contains { if case .patternMinimumRelaxedUnavailable = $0 { return true }; return false })
    }

    /// Единственный кандидат нового паттерна — из семьи, где уже два упражнения.
    func test_patternRelaxed_familyLimit_notReportedAsTime() {
        let vector: [MuscleSlug: Double] = [.gluteMax: 0.5, .hamstrings: 0.5]
        let library = [
            ExerciseCandidate(slug: "fam_hinge_a", pattern: .hinge, muscleContributions: [.gluteMax: 1.0],
                              progressionFamily: "fam", fatigueCost: 1.0, setupSeconds: 20, loadType: .bodyweight),
            ExerciseCandidate(slug: "fam_hinge_b", pattern: .hinge, muscleContributions: [.hamstrings: 1.0],
                              progressionFamily: "fam", fatigueCost: 1.0, setupSeconds: 20, loadType: .bodyweight),
            ExerciseCandidate(slug: "fam_squat", pattern: .squat, muscleContributions: [.gluteMax: 0.3, .erectors: 0.7],
                              progressionFamily: "fam", fatigueCost: 1.0, setupSeconds: 20, loadType: .bodyweight),
            ExerciseCandidate(slug: "curl_iso", pattern: .isolation, muscleContributions: [.hamstrings: 0.6, .calves: 0.4],
                              progressionFamily: "curl_iso", fatigueCost: 0.5, setupSeconds: 20, loadType: .bodyweight),
        ]
        let session = build(F.input(week: F.week([(.lower, nil, vector)]), library: library, minutes: 180,
                                    states: Dictionary(uniqueKeysWithValues: library.map { ($0.slug, ExerciseState(isInCalibration: false)) })))
        XCTAssertTrue(F.slugs(session).isSuperset(of: ["fam_hinge_a", "fam_hinge_b"]), "фикстура: семья заполнена шарнирами")
        XCTAssertFalse(F.slugs(session).contains("fam_squat"))
        XCTAssertLessThan(patterns(session, in: library).count, 3)
        XCTAssertFalse(relaxedByTime(session), "семейный лимит — не время")
        XCTAssertTrue(session.reasons.contains(.patternMinimumRelaxedByLimit(fitted: patterns(session, in: library).count, limit: .family)))
    }

    // MARK: - Сценарий 29c (уточнение ревью, находка 5): недобор — только по мышцам вектора дня

    /// Побочные вклады вне вектора (разгибатели в тяге, пресс в кубковом
    /// приседе) — не недобор: день их не просил, и строка «выйдет меньше по
    /// разгибателям» была бы ложной.
    func test_scenario29c_shortfallOnlyForVectorMuscles() {
        var sawVectorLine = false
        for minutes in [8, 10, 12, 15, 20] {
            let plan = Planner.planRemainingDays(F.context(week: twoGluteDays, minutes: minutes))
            for line in plan.statusLines {
                guard case .weekShortfallByTime(let muscle, _) = line else { continue }
                XCTAssertNotNil(F.lowerGlutes[muscle], "\(minutes) минут: строка недобора по мышце вне вектора — \(muscle)")
                sawVectorLine = true
            }
        }
        XCTAssertTrue(sawVectorLine, "фикстура: бюджет ограничивает хотя бы в одном случае")
    }

    // MARK: - Сценарий 30: травма колена — низ из шарнирных движений

    func test_scenario30_kneeInjury_lowerFromHinges() {
        let safety = SafetyProfile(level: .intermediate, restrictions: [UserRestriction(joint: .knee, severity: .avoid)])
        let session = build(F.input(week: F.week([(.lower, nil, F.lower)]), safety: safety))
        XCTAssertFalse(session.exercises.isEmpty)
        for e in session.exercises {
            let c = F.candidate(e.slug)
            XCTAssertTrue([.hinge, .isolation].contains(c.pattern), "\(e.slug): \(c.pattern)")
            XCTAssertLessThan(c.jointStress[.knee] ?? .low, .medium)
        }
        XCTAssertTrue(session.exercises.contains { F.candidate($0.slug).pattern == .hinge })
    }

    // MARK: - Сценарий 30a: паттернов меньше трёх — ослаблено по доступности, безопасность не тронута

    func test_scenario30a_patternsRelaxedByAvailability() {
        let safety = SafetyProfile(level: .intermediate, restrictions: [UserRestriction(joint: .knee, severity: .avoid)])
        let session = build(F.input(week: F.week([(.lower, nil, F.lower)]), safety: safety))
        XCTAssertTrue(session.reasons.contains(.patternMinimumRelaxedUnavailable(available: 2)))
        XCTAssertFalse(session.exercises.contains { ["goblet_squat", "band_squat", "step_up", "box_jump"].contains($0.slug) })
    }

    // MARK: - Сценарий 31: смена фазы посреди недели — пересобраны только будущие дни

    func test_scenario31_phaseChangeMidWeek_onlyFutureDaysRebuilt() {
        let week = F.week(Array(repeating: (.lower, .gluteMax, F.lowerGlutes), count: 3), offsets: [0, 2, 4])
        let profile = CycleProfile(typicalCycleLengthDays: 28, declaredRegularity: .regular)
        let before = CycleInputs(events: [CycleEvent(kind: .periodStart, occurredOn: F.day(-20))], profile: profile)
        let after = CycleInputs(events: before.events + [CycleEvent(kind: .periodStart, occurredOn: F.day(2))], profile: profile)

        var days = week
        days[0].status = .done
        let planBefore = Planner.planRemainingDays(F.context(week: days, today: F.day(2), cycle: before))
        let planAfter = Planner.planRemainingDays(F.context(week: days, today: F.day(2), cycle: after))
        XCTAssertNil(planAfter.sessions["day0"], "прошедший день не трогается")
        XCTAssertEqual(Set(planAfter.sessions.keys), ["day1", "day2"])
        let setsBefore = planBefore.sessions["day1"]!.exercises.reduce(0) { $0 + $1.targetSets }
        let setsAfter = planAfter.sessions["day1"]!.exercises.reduce(0) { $0 + $1.targetSets }
        XCTAssertLessThanOrEqual(setsAfter, setsBefore)
        XCTAssertTrue(planAfter.sessions["day1"]!.reasons.contains { if case .phasePeriodization(.menstrual, _) = $0 { return true }; return false })
    }

    // MARK: - Оверрайд rest — растяжка решается внутри планировщика (ревью, находка 2)

    /// Оверрайд `rest` заменяет сегодняшний день растяжкой (§7.1, §11.4) при любом
    /// `status`: планировщик не ждёт, пока вызывающая сторона отметит день
    /// заменённым. Знаменатель `S_эфф` и завтрашний день не меняются.
    func test_restOverride_todayBecomesStretch_regardlessOfStatus() {
        let week = F.week([(.lower, .gluteMax, F.lowerGlutes), (.lower, .gluteMax, F.lowerGlutes)])
        XCTAssertEqual(week[0].status, .planned, "фикстура: день ещё не отмечен заменённым")
        let plain = Planner.planRemainingDays(F.context(week: week))
        let rest = Planner.planRemainingDays(F.context(week: week, override: .rest))
        XCTAssertNotNil(plain.sessions["day0"])
        XCTAssertNil(rest.sessions["day0"], "в день rest силовой тренировки нет")
        XCTAssertEqual(rest.stretchDayIDs, ["day0"])
        XCTAssertTrue(plain.stretchDayIDs.isEmpty)
        var replaced = week
        replaced[0].status = .replaced
        XCTAssertEqual(Planner.planRemainingDays(F.context(week: replaced, override: .rest)).stretchDayIDs, ["day0"],
                       "и после отметки replaced — тот же результат")
        XCTAssertTrue(Planner.planRemainingDays(F.context(week: week, today: F.day(0), override: .rest)).sessions["day1"] != nil)
        XCTAssertEqual(rest.sessions["day1"], plain.sessions["day1"], "завтрашний день не изменился")
        XCTAssertEqual(rest.sessions["day1"]?.scale, plain.sessions["day1"]?.scale)
    }

    // MARK: - Статус дня — один источник для сборки, потерь и строки «План обновлён» (ревью 2, находки 1–2)

    private func lossMuscles(_ plan: WeekPlan) -> [MuscleSlug] {
        plan.statusLines.compactMap { (line: ReasonCode) -> MuscleSlug? in
            if case .plannedVolumeLoss(let m, _, _) = line { return m }
            return nil
        }
    }

    /// День, заменённый оверрайдом `rest`, теряет свой плановый объём так же, как
    /// пропущенный: знаменатель `S_эфф` его сохраняет (§7.3), а неделя выходит
    /// легче — и обязана это сказать (§7.1).
    func test_restOverrideDayCountsAsLostVolume() {
        let week = F.week([(.lower, .gluteMax, F.lowerGlutes), (.lower, .gluteMax, F.lowerGlutes)])
        let rest = Planner.planRemainingDays(F.context(week: week, override: .rest))
        XCTAssertTrue(lossMuscles(rest).contains(.gluteMax), "строка потери по ягодичным за день отдыха")
        XCTAssertTrue(rest.statusLines.contains { if case .plannedVolumeLoss(_, _, .restOverride) = $0 { return true }; return false },
                      "причина — оверрайд отдыха, не пропуск")

        var skipped = week
        skipped[0].status = .skipped
        let skippedPlan = Planner.planRemainingDays(F.context(week: skipped, today: F.day(1)))
        XCTAssertEqual(Set(lossMuscles(rest)), Set(lossMuscles(skippedPlan)), "та же потеря, что у пропуска")
    }

    /// Статус `replaced` (день уже отмечен заменённым) — тот же потерянный объём.
    func test_replacedDayCountsAsLostVolume() {
        var week = F.week([(.lower, .gluteMax, F.lowerGlutes), (.lower, .gluteMax, F.lowerGlutes)])
        week[0].status = .replaced
        let plan = Planner.planRemainingDays(F.context(week: week, today: F.day(1)))
        XCTAssertTrue(lossMuscles(plan).contains(.gluteMax))
    }

    /// День, исчезнувший из плана (оверрайд `rest` заменил тренировку растяжкой),
    /// — изменение плана: молчаливой замены §7.1 не допускает.
    func test_rebuildNoticeSeesDayLeavingThePlan() {
        let week = F.week([(.lower, .gluteMax, F.lowerGlutes), (.lower, .gluteMax, F.lowerGlutes)])
        let before = Planner.planRemainingDays(F.context(week: week))
        let after = Planner.planRemainingDays(F.context(week: week, override: .rest))
        XCTAssertNotNil(Planner.rebuildNotice(previous: before, current: after, cause: .override),
                        "тренировка заменена растяжкой — строка обязана быть")
        XCTAssertNil(Planner.rebuildNotice(previous: before, current: before, cause: .override),
                     "ничего не изменилось — строки нет")
    }

    // MARK: - Причина потери — от дня, потерявшего больше всех (ревью 3, находка 1)

    /// Строка статуса называет один день, и это должен быть тот, из-за которого
    /// неделя просела сильнее, а не первый по календарю.
    func test_weekLossCauseIsTheBiggestLoser() {
        var week = F.week([(.upper, nil, F.upper), (.lower, .gluteMax, F.lowerGlutes)])
        // У дня верха ягодичные есть чуть-чуть, у дня низа — акцент.
        week[0].vector[.gluteMax] = 0.05
        week[0].status = .skipped
        let plan = Planner.planRemainingDays(F.context(week: week, today: F.day(1), override: .rest))

        func cause(_ muscle: MuscleSlug) -> DayOutcome.Cause? {
            for line in plan.statusLines {
                if case .plannedVolumeLoss(muscle, _, let cause) = line { return cause }
            }
            return nil
        }
        XCTAssertEqual(cause(.gluteMax), .restOverride, "ягодичные потерял день с акцентом — он и назван")
        XCTAssertEqual(cause(.lats), .skipped, "широчайшие есть только в дне верха")
    }

    // MARK: - Дубликаты id дня — невозможное состояние (ревью 3, находка 4)

    /// `planned_days.id` — первичный ключ, а пара (неделя, дата) уникальна
    /// (§3.1), так что двух строк с одним id не бывает: в отладке это ловит
    /// `assert` в `planRemainingDays`. Здесь проверяется релизное поведение —
    /// оно обязано быть определённым и ОДИНАКОВЫМ у всех правил: неделю все
    /// читают через `normalizedWeek`, где на каждый id остаётся первая строка.
    /// Раньше словарь итогов схлопывал дубликат, а знаменатель `S_эфф` и сумма
    /// потерь считали его дважды.
    func test_duplicateDayIDsAreNormalizedDeterministically() {
        let week = F.week([(.lower, .gluteMax, F.lowerGlutes), (.lower, .gluteMax, F.lowerGlutes)])
        var duplicated = week
        duplicated[1].id = "day0"
        duplicated[1].status = .skipped

        let normalized = Planner.normalizedWeek(duplicated)
        XCTAssertEqual(normalized.map(\.id), ["day0"], "на каждый id — одна строка")
        XCTAssertEqual(normalized.first?.status, .planned, "выигрывает первая строка, а не дубликат")
        XCTAssertEqual(Planner.normalizedWeek(duplicated.reversed()).map(\.id), ["day0"])

        // Сортировка по датам — там же, поэтому порядок массива на правила не влияет.
        let shuffled = Planner.normalizedWeek([week[1], week[0]])
        XCTAssertEqual(shuffled.map(\.id), ["day0", "day1"])

        // Знаменатель S_эфф и потери читают ту же нормализованную неделю.
        let scale = Planner.sessionScale(dayIndex: 0, week: normalized, level: .intermediate)?.scale
        let single = Planner.sessionScale(dayIndex: 0, week: [week[0]], level: .intermediate)?.scale
        XCTAssertEqual(scale ?? 0, single ?? -1, accuracy: 1e-12, "день учтён один раз")
    }

    // MARK: - День без целевого вектора виден снаружи (ревью 2, находка 5)

    /// Пара (тип дня, акцент) без вектора — ошибка разметки (§7.3, правило 4).
    /// Планировщик собрать день не может, но и молчать не должен: иначе дыра в
    /// контенте выглядит как обычный день отдыха.
    func test_dayWithoutVectorIsReportedAsMarkupGap() {
        var week = F.week([(.push, nil, F.upper), (.lower, .gluteMax, F.lowerGlutes)])
        week[0].vector = [:]
        let plan = Planner.planRemainingDays(F.context(week: week))
        XCTAssertNil(plan.sessions["day0"])
        XCTAssertTrue(plan.statusLines.contains { if case .dayVectorMissing(.push, nil) = $0 { return true }; return false },
                      "дыра в разметке названа явно")
        XCTAssertNotNil(plan.sessions["day1"], "остальная неделя собирается")

        let stretch = F.week([(.stretch, nil, [:]), (.lower, .gluteMax, F.lowerGlutes)])
        let stretchPlan = Planner.planRemainingDays(F.context(week: stretch))
        XCTAssertFalse(stretchPlan.statusLines.contains { if case .dayVectorMissing = $0 { return true }; return false },
                       "день растяжки вектора и не должен иметь")
        XCTAssertEqual(stretchPlan.stretchDayIDs, ["day0"])
    }

    // MARK: - Сценарий 31a: равномерная плановая поправка — состав тот же, меняются target_sets

    /// Равномерный срез — разгрузочная неделя и фаза ниже порога 0.3, где тип
    /// блока нейтральный, — меняет только подходы. Менструальная фаза при полной
    /// уверенности включает восстановительный блок (w8), и состав менять вправе;
    /// прежняя версия теста проверяла её на «тот же состав» и проходила только
    /// потому, что шаг 3 снимал упражнение против срезанной цели (находка 4).
    func test_scenario31a_uniformPlannedCut_sameCompositionFewerSets() {
        let base = build(F.input(week: twoGluteDays))
        let deload = build(F.input(week: twoGluteDays, isDeloadWeek: true))
        let lowConfidence = F.phaseState(.menstrual, confidence: 0.29)
        XCTAssertEqual(lowConfidence.periodization?.blockType, .neutral, "фикстура: ниже порога блок нейтральный")
        let menstrualLow = build(F.input(week: twoGluteDays, cycleState: lowConfidence))
        XCTAssertEqual(F.slugs(deload), F.slugs(base))
        XCTAssertEqual(F.slugs(menstrualLow), F.slugs(base))
        XCTAssertLessThan(totalSets(deload), totalSets(base))
        XCTAssertLessThanOrEqual(totalSets(menstrualLow), totalSets(base))
        XCTAssertTrue(deload.removedAtMinimum.isEmpty && menstrualLow.removedAtMinimum.isEmpty)
    }

    // MARK: - Шаг 3 (снятие упражнений) — против цели ДО равномерного среза (ревью, находка 4)

    /// Разгрузочная неделя режет все мышцы одинаково и состав менять не вправе
    /// (31a). Раньше шаг 3 снимал упражнение против цели с разгрузочным срезом:
    /// в неделе из трёх дней «низ с акцентом» при 30 минутах со штангой из сборки
    /// уходил ягодичный мост — срез учитывался дважды, в подходах и в составе.
    func test_step3_uniformCutDoesNotRemoveExercises() {
        let week = F.week(Array(repeating: (.lower, .gluteMax, F.lowerGlutes), count: 3))
        let base = build(F.input(week: week, minutes: 30))
        let deload = build(F.input(week: week, minutes: 30, isDeloadWeek: true))
        XCTAssertTrue(F.slugs(base).contains("hip_thrust_barbell"), "фикстура: мост в обычной неделе есть")
        XCTAssertEqual(F.slugs(deload), F.slugs(base), "разгрузочная неделя — тот же состав")
        XCTAssertLessThanOrEqual(totalSets(deload), totalSets(base))
    }

    /// Путь снятия жив: глубокий НЕравномерный срез — утомление на ведущей мышце —
    /// снимает упражнение на минимуме, не ломая минимум паттернов и не опускаясь
    /// ниже трёх упражнений (§7.3, шаг 3; §8.3, п.3).
    func test_step3_deepFatigueCutRemovesAtMinimum() {
        let week = F.week(Array(repeating: (.lower, .gluteMax, F.lowerGlutes), count: 3))
        let tired = build(F.input(week: week, safety: SafetyProfile(level: .advanced), minutes: 45, fatigue: [.gluteMax: 2.5]))
        XCTAssertFalse(tired.removedAtMinimum.isEmpty, "шаг 3 сработал")
        XCTAssertTrue(tired.removedAtMinimum.allSatisfy { !F.slugs(tired).contains($0) })
        XCTAssertGreaterThanOrEqual(tired.exercises.count, 3)
        XCTAssertGreaterThanOrEqual(patterns(tired).count, 3)
        let fresh = build(F.input(week: week, safety: SafetyProfile(level: .advanced), minutes: 45))
        XCTAssertTrue(fresh.removedAtMinimum.isEmpty, "без утомления снимать нечего")
    }

    // MARK: - Сценарий 31b: будущий день от замороженного состояния

    func test_scenario31b_futureDayFromFrozenState() {
        let week = F.week([(.lower, .gluteMax, F.lowerGlutes), (.lower, .gluteMax, F.lowerGlutes)])
        let plain = Planner.planRemainingDays(F.context(week: week))
        let withCheckin = Planner.planRemainingDays(F.context(
            week: week, checkin: DailyCheckin(energy: 1, soreness: 5, sleepQuality: 1, stress: 5), override: .ease))
        XCTAssertEqual(plain.sessions["day1"], withCheckin.sessions["day1"],
                       "check-in и оверрайд сегодня не меняют предпросмотр завтра")
        XCTAssertNotEqual(plain.sessions["day0"], withCheckin.sessions["day0"], "а сегодняшний день меняют")

        // Сегодняшняя тренировка ещё не выполнена — завтрашний день её утомления не знает.
        var started = Planner.planRemainingDays(F.context(week: week, started: ["day0"]))
        XCTAssertEqual(started.sessions["day1"], plain.sessions["day1"])
        XCTAssertNil(started.sessions["day0"])

        var completed: [CompletedWorkout] = []
        var fatigue: [MuscleSlug: FatigueState] = [:]
        F.perform(plain.sessions["day0"]!, on: F.day(0), completed: &completed, fatigue: &fatigue, history: &throwawayHistory)
        var done = week
        done[0].status = .done
        started = Planner.planRemainingDays(F.context(week: done, completed: completed, fatigue: fatigue))
        XCTAssertNotEqual(started.sessions["day1"], plain.sessions["day1"], "после выполнения — учтена")
    }

    // MARK: - Сценарий 31c: выполненная тренировка пересобирает оставшиеся дни; строка — только при изменении

    func test_scenario31c_completedWorkoutRebuild_noticeOnlyOnChange() {
        let week = F.week([(.lower, .gluteMax, F.lowerGlutes), (.lower, .gluteMax, F.lowerGlutes)])
        let before = Planner.planRemainingDays(F.context(week: week))
        XCTAssertNil(Planner.rebuildNotice(previous: before, current: before, cause: .workoutCompleted))

        var completed: [CompletedWorkout] = []
        var fatigue: [MuscleSlug: FatigueState] = [:]
        F.perform(before.sessions["day0"]!, on: F.day(0), completed: &completed, fatigue: &fatigue, history: &throwawayHistory)
        var done = week
        done[0].status = .done
        let after = Planner.planRemainingDays(F.context(week: done, today: F.day(0), completed: completed, fatigue: fatigue))
        let changed = after.sessions["day1"]!.composition != before.sessions["day1"]!.composition
        XCTAssertEqual(Planner.rebuildNotice(previous: before, current: after, cause: .workoutCompleted) != nil, changed)
        XCTAssertEqual(after.sessions["day1"]!.scale, before.sessions["day1"]!.scale, accuracy: 1e-12, "S_эфф тот же")
    }

    // MARK: - Сценарий 32: пропуск двух тренировок подряд — объём не догоняется

    func test_scenario32_twoSkips_noCompensation() {
        let week = F.week(Array(repeating: (.lower, .gluteMax, F.lowerGlutes), count: 4))
        let scaleBefore = Planner.sessionScale(dayIndex: 3, week: week, level: .intermediate)!.scale
        var skipped = week
        skipped[0].status = .done
        skipped[1].status = .skipped
        skipped[2].status = .skipped
        XCTAssertEqual(Planner.sessionScale(dayIndex: 3, week: skipped, level: .intermediate)!.scale, scaleBefore, accuracy: 1e-12)

        // Недельный план выполненных — сумма их долей: 2 из 4 → половина нормы 16.
        let plannedDone = [0, 3].reduce(0.0) { $0 + Planner.sessionScale(dayIndex: $1, week: skipped, level: .intermediate)!.scale * 0.40 }
        XCTAssertEqual(plannedDone, 8.0, accuracy: 1e-9)

        let plan = Planner.planRemainingDays(F.context(week: skipped, today: F.day(3)))
        let fresh = Planner.planRemainingDays(F.context(week: week, today: F.day(3)))
        XCTAssertEqual(plan.sessions["day3"]?.composition, fresh.sessions["day3"]?.composition,
                       "без утомления и выполненного объёма последний день тот же, что и без пропусков")
        XCTAssertTrue(plan.statusLines.contains(.plannedVolumeLoss(muscle: .gluteMax, sets: 8, cause: .skipped)))
    }

    // MARK: - Сценарий 32a: пропущен день другого типа — дни низа не изменились

    func test_scenario32a_skippedOtherKind_lowerDaysUnchanged() {
        let week = F.week([(.lower, .gluteMax, F.lowerGlutes), (.upper, nil, F.upper), (.lower, .gluteMax, F.lowerGlutes)])
        var skipped = week
        skipped[1].status = .skipped
        let before = Planner.planRemainingDays(F.context(week: week, today: F.day(2)))
        let after = Planner.planRemainingDays(F.context(week: skipped, today: F.day(2)))
        XCTAssertEqual(after.sessions["day2"]?.composition, before.sessions["day2"]?.composition)
        XCTAssertNil(Planner.rebuildNotice(previous: before, current: after, cause: .workoutSkipped))
        XCTAssertFalse(after.statusLines.contains { if case .plannedVolumeLoss(.gluteMax, _, _) = $0 { return true }; return false })
    }

    // MARK: - Сценарий 32b: пропущен последний день — пересобирать нечего, статус показан

    func test_scenario32b_lastDaySkipped_nothingToRebuild_statusShown() {
        var week = F.week([(.lower, .gluteMax, F.lowerGlutes), (.lower, .gluteMax, F.lowerGlutes)])
        week[0].status = .done
        let before = Planner.planRemainingDays(F.context(week: week, today: F.day(1)))
        week[1].status = .skipped
        let after = Planner.planRemainingDays(F.context(week: week, today: F.day(1)))
        XCTAssertTrue(after.sessions.isEmpty)
        XCTAssertNil(Planner.rebuildNotice(previous: before, current: after, cause: .workoutSkipped))
        XCTAssertTrue(after.statusLines.contains(.plannedVolumeLoss(muscle: .gluteMax, sets: 8, cause: .skipped)))
    }

    // MARK: - Сценарий 32c: пропуск в конце недели W — S_эфф недели W+1 не изменился

    func test_scenario32c_skipDoesNotCarryIntoNextWeek() {
        let nextWeek = F.week([(.lower, .gluteMax, F.lowerGlutes), (.lower, .gluteMax, F.lowerGlutes)], offsets: [7, 9])
        let scale = Planner.sessionScale(dayIndex: 0, week: nextWeek, level: .intermediate)!.scale
        XCTAssertEqual(scale, 20.0, accuracy: 1e-12, "S_эфф W+1 — от её собственной сетки, долг не переносится")
        // Выполненное на прошлой неделе не входит в неделя[m] следующей.
        let lastWeek = [CompletedWorkout(id: "w", plannedDayID: nil, date: F.day(4), performedAt: Timestamp(hoursSinceEpoch: 0),
                                         setsBySlug: ["rdl_band": 3])]
        let library = Dictionary(uniqueKeysWithValues: F.library.map { ($0.slug, $0) })
        XCTAssertTrue(Planner.weekDoneVolume(completed: lastWeek, weekStart: F.day(7), library: library).isEmpty)
    }

    // MARK: - Сценарий 32d: тип и акцент оставшихся дней после пропуска не изменились

    func test_scenario32d_skipKeepsKindsAndAccents() {
        var week = F.week([(.lower, .gluteMax, F.lowerGlutes), (.upper, nil, F.upper), (.lower, nil, F.lower)])
        week[0].status = .skipped
        let plan = Planner.planRemainingDays(F.context(week: week, today: F.day(1)))
        XCTAssertEqual(plan.sessions["day1"]?.leadingMuscle, .lats, "день верха остался днём верха")
        XCTAssertTrue(plan.sessions["day1"]!.exercises.allSatisfy {
            let c = F.candidate($0.slug)
            return c.leadingMuscle.map { F.upper[$0] != nil || $0 == .abs } ?? false
        })
        XCTAssertEqual(week.map(\.kind), [.lower, .upper, .lower])
        XCTAssertEqual(week.map(\.accent), [.gluteMax, nil, nil])
    }

    // MARK: - Сценарий 32e: пересборка трижды — тот же план и та же неделя[m]

    func test_scenario32e_repeatedRebuildIsIdempotent() {
        var week = F.week(Array(repeating: (.lower, .gluteMax, F.lowerGlutes), count: 3))
        var completed: [CompletedWorkout] = []
        var fatigue: [MuscleSlug: FatigueState] = [:]
        let first = Planner.planRemainingDays(F.context(week: week))
        F.perform(first.sessions["day0"]!, on: F.day(0), completed: &completed, fatigue: &fatigue, history: &throwawayHistory)
        week[0].status = .done
        week[1].status = .skipped
        // Повторная доставка той же тренировки (§4.3) — тот же ключ.
        completed.append(completed[0])
        let ctx = F.context(week: week, today: F.day(2), completed: completed, fatigue: fatigue)
        let a = Planner.planRemainingDays(ctx)
        let b = Planner.planRemainingDays(ctx)
        let c = Planner.planRemainingDays(ctx)
        XCTAssertEqual(a, b)
        XCTAssertEqual(b, c)
        let library = Dictionary(uniqueKeysWithValues: F.library.map { ($0.slug, $0) })
        let doneOnce = Planner.weekDoneVolume(completed: [completed[0]], weekStart: F.day(0), library: library)
        XCTAssertEqual(Planner.weekDoneVolume(completed: completed, weekStart: F.day(0), library: library), doneOnce)
    }

    // MARK: - Сценарий 33: начатая тренировка не пересобирается

    func test_scenario33_startedWorkoutUntouched() {
        let week = F.week([(.lower, .gluteMax, F.lowerGlutes), (.lower, .gluteMax, F.lowerGlutes)])
        let plan = Planner.planRemainingDays(F.context(week: week, started: ["day0"], isDeloadWeek: true))
        XCTAssertNil(plan.sessions["day0"])
        XCTAssertNotNil(plan.sessions["day1"])
    }

    // MARK: - Сценарий 33a: детерминизм и независимость от порядка среза

    func test_scenario33a_deterministicAndInputOrderIndependent() {
        let a = build(F.input(week: twoGluteDays, minutes: 30))
        let b = build(F.input(week: twoGluteDays, minutes: 30))
        XCTAssertEqual(a, b)
        let reversed = build(F.input(week: twoGluteDays, library: F.library.reversed(), minutes: 30))
        XCTAssertEqual(a, reversed)
        var rotated = F.library
        rotated.append(contentsOf: rotated.prefix(5))
        rotated.removeFirst(5)
        XCTAssertEqual(a, build(F.input(week: twoGluteDays, library: rotated, minutes: 30)))
        XCTAssertEqual(Planner.daySeed(userSeed: 1, day: F.day(3)), Planner.daySeed(userSeed: 1, day: F.day(3)))
        XCTAssertNotEqual(Planner.daySeed(userSeed: 1, day: F.day(3)), Planner.daySeed(userSeed: 1, day: F.day(4)))
    }

    // MARK: - Контракт: порядок дней недели — забота сборки (ревью 2, находка 4)

    /// `remaining[m]` слагаемого w11 считает сессии «от текущей включительно», и
    /// раньше это молча предполагало, что вызывающая сторона отсортировала
    /// неделю по дате. Сортировка — часть контракта `buildSession`.
    func test_contract_buildSessionSortsWeekByDate() {
        let vector = F.flatFullBody
        let byDate = F.week(Array(repeating: (.fullBody, nil, vector), count: 4))
        for target in byDate.indices {
            let inCreationOrder = [byDate[target]] + byDate.enumerated().filter { $0.offset != target }.map(\.element)
            let sorted = build(F.input(week: byDate, dayIndex: target, minutes: 20))
            let shuffled = build(F.input(week: inCreationOrder, dayIndex: 0, minutes: 20))
            XCTAssertEqual(shuffled.composition, sorted.composition, "день \(target): порядок массива не должен влиять")
            XCTAssertEqual(shuffled.effectiveVolume, sorted.effectiveVolume)
        }
    }

    // MARK: - Контракт: ранг ничьих не зависит от остальной библиотеки (ревью, находка 3)

    /// Ранг — hash(seed, slug) для каждого упражнения отдельно. Перетасовка всего
    /// списка меняла ранг почти каждого слага от добавления одного чужого, и
    /// ничьи во всех днях решались заново («План обновлён» без причины).
    func test_contract_tieRankStableUnderLibraryChanges() {
        let slugs = F.library.map(\.slug)
        let base = Planner.ranks(for: slugs, seed: F.seed)
        let added = Planner.ranks(for: slugs + ["zz_new_upper_exercise", "aa_new_core_exercise"], seed: F.seed)
        let removed = Planner.ranks(for: slugs.filter { $0 != "db_row" }, seed: F.seed)
        for slug in slugs {
            XCTAssertEqual(added[slug], base[slug], "добавление чужих слагов сдвинуло ранг \(slug)")
            if slug != "db_row" { XCTAssertEqual(removed[slug], base[slug], "удаление чужого слага сдвинуло ранг \(slug)") }
        }
        XCTAssertNotEqual(Planner.ranks(for: slugs, seed: F.seed &+ 1)["rdl_band"], base["rdl_band"], "ранг зависит от seed")
    }

    // MARK: - Контракт: §7.6 prescribed_kg = roundToAchievable(baseline × weight_readiness)

    func test_contract_prescribedWeightFollowsWeightReadiness() {
        var states = F.familiar
        states["goblet_squat"] = ExerciseState(baselineKg: 10, isInCalibration: false)
        let library = [F.gobletSquat, F.rdlBand, F.bandAbduction, F.legCurlBand]
        let week = F.week([(.lower, nil, F.lower)])
        for readiness in [0.8, 1.0, 1.08] {
            let session = build(F.input(week: week, library: library, states: states, readiness: readiness))
            guard let squat = session.exercises.first(where: { $0.slug == "goblet_squat" }) else {
                XCTFail("goblet_squat не собран при готовности \(readiness)"); continue
            }
            let ladder = WeightLadder.build(loadType: .dumbbell, profile: F.fullEquipment)
            let expected = ladder.roundToAchievable(10 * squat.weightReadiness, direction: squat.weightReadiness < 1 ? .down : .up)
            XCTAssertEqual(squat.prescribedKg, expected)
            XCTAssertEqual(squat.weightReadiness, readiness, accuracy: 1e-12, "без утомления — дневная готовность")
            XCTAssertTrue(session.exercises.filter { $0.slug != "goblet_squat" }.allSatisfy { $0.prescribedKg == nil })
        }
    }

    // MARK: - Контракт: детренированность в предписании (ревью, находка 1)

    /// §9.7 действует «перед первой сессией после перерыва», а свёртка
    /// `rebuildStates` применяет её, только когда эта сессия записана. Поэтому
    /// срез несёт само предписание — тем же правилом Progression.
    func test_contract_detraining_prescriptionCarriesDecay() {
        let library = [F.gobletSquat, F.rdlBand, F.bandAbduction, F.legCurlBand]
        // Три дня низа — объём на сессию такой, что добавленные подходы у приседа видны.
        let week = F.week(Array(repeating: (.lower, nil, F.lower), count: 3), offsets: [36, 38, 40])
        func squat(lastPerformed: Int, repExtension: Int = 3, extraSets: Int = 2) -> PrescribedExercise? {
            var states = F.familiar
            states["goblet_squat"] = ExerciseState(baselineKg: 10, repExtension: repExtension, extraSetsAdded: extraSets,
                                                   lastPerformedAt: F.day(40 - lastPerformed), isInCalibration: false)
            return build(F.input(week: week, dayIndex: 2, library: library, minutes: 30, states: states)).exercises.first { $0.slug == "goblet_squat" }
        }
        guard let recent = squat(lastPerformed: 5), let moderate = squat(lastPerformed: 30),
              let long = squat(lastPerformed: 60), let mild = squat(lastPerformed: 15) else {
            return XCTFail("фикстура: goblet_squat в сборке")
        }
        XCTAssertEqual(recent.prescribedKg, 10)
        XCTAssertEqual(recent.targetRepMax, 12 + 3)

        XCTAssertEqual(mild.prescribedKg, 8, "15 дней: 10 × 0.92 = 9.2 → вниз по лестнице")
        XCTAssertEqual(mild.targetRepMax, 12 + 3, "до 22 дней счётчики прогрессии не сбрасываются")

        XCTAssertEqual(moderate.prescribedKg, 8, "30 дней: 10 × 0.85 = 8.5 → вниз по лестнице")
        XCTAssertEqual(moderate.targetRepMax, 12, "rep_extension сброшен")
        let noExtras = squat(lastPerformed: 30, repExtension: 0, extraSets: 0)
        XCTAssertEqual(moderate.targetSets, noExtras?.targetSets, "extra_sets_added сброшен")
        XCTAssertLessThan(moderate.targetSets, recent.targetSets, "фикстура: добавленные подходы видны без перерыва")

        XCTAssertNil(long.prescribedKg, "больше 45 дней — снова калибровка")
        XCTAssertEqual(long.targetRepMax, 12)
    }

    /// Состояние прогрессии планировщик сворачивает сам — `rebuildStates` с
    /// лестницей ТЕКУЩЕГО инвентаря (находка 1). Журнал записан на гантелях до
    /// 12 кг; после смены инвентаря (до 10 кг) предписание следует свёртке с
    /// новой лестницей, а не состоянию, посчитанному со старой.
    func test_contract_plannerFoldsHistoryWithCurrentLadder() {
        let set = { (kg: Double) in SetResult(prescribedKg: kg, actualKg: kg, actualReps: 10, feedback: .ok) }
        let history: [String: [ExerciseSession]] = F.familiarHistory(for: F.library).merging([
            "goblet_squat": [
                ExerciseSession(performedAt: F.day(-6), weightReadiness: 1.0, isCalibration: false, sets: [set(12), set(12)]),
                ExerciseSession(performedAt: F.day(-3), weightReadiness: 1.0, isCalibration: false, sets: [set(12), set(12), set(12)]),
            ],
        ]) { $1 }
        let week = F.week([(.lower, nil, F.lower)])
        let library = [F.gobletSquat, F.rdlBand, F.bandAbduction, F.legCurlBand]
        for equipment in [F.fullEquipment, EquipmentProfile(dumbbellsKg: [4, 6, 8, 10])] {
            let ctx = WeekContext(
                weekStart: F.day(0), week: week, today: F.day(0), library: library, availability: F.fullAvailability,
                equipment: equipment, safety: SafetyProfile(level: .intermediate), goal: .hypertrophy, sessionMinutes: 45,
                exerciseHistory: history,
                cycle: CycleInputs(events: [], profile: CycleProfile(phaseMode: .noPhases, noPhaseReason: .userChoice)),
                userSeed: F.seed)
            let ladder = WeightLadder.build(loadType: .dumbbell, profile: equipment)
            let folded = Progression.rebuildStates(from: history["goblet_squat"]!, baseRange: 8...12, ladder: ladder)
            XCTAssertEqual(Planner.exerciseStates(history: history, library: library, goal: .hypertrophy, equipment: equipment)["goblet_squat"],
                           folded)
            guard let squat = Planner.planRemainingDays(ctx).sessions["day0"]?.exercises.first(where: { $0.slug == "goblet_squat" }) else {
                XCTFail("фикстура: goblet_squat в сборке"); continue
            }
            let expected = folded.baselineKg.map { ladder.roundToAchievable($0 * squat.weightReadiness, direction: .up) }
            XCTAssertEqual(squat.prescribedKg, expected)
            XCTAssertLessThanOrEqual(squat.prescribedKg ?? 0, ladder == .discrete([4, 6, 8, 10]) ? 10 : 12, "вес на лестнице текущего инвентаря")
        }
    }

    // MARK: - Контракт: инвентарь §6.6

    func test_contract_equipmentPredicatesAndLadder() {
        let flat = EquipmentAvailability(bench: .flat)
        XCTAssertTrue(flat.satisfies(.benchFlat))
        XCTAssertFalse(flat.satisfies(.benchAdjustable))
        XCTAssertTrue(EquipmentAvailability(bench: .adjustable).satisfies(.benchFlat))
        XCTAssertTrue(EquipmentAvailability(machines: ["leg_press"]).satisfies(.machine("leg_press")))
        XCTAssertFalse(EquipmentAvailability(machines: ["leg_press"]).satisfies(.machine("hack_squat")))
        XCTAssertFalse(EquipmentAvailability(cableMachine: false).satisfies(.cableMachine))

        XCTAssertFalse(Planner.isFeasible(F.gobletSquat, availability: F.fullAvailability, equipment: EquipmentProfile()),
                       "гантелей нет — лестница пуста")
        XCTAssertFalse(Planner.isFeasible(F.hipThrustBarbell, availability: F.fullAvailability, equipment: EquipmentProfile(dumbbellsKg: [10])))
        XCTAssertTrue(Planner.isFeasible(F.gluteBridge, availability: EquipmentAvailability(), equipment: EquipmentProfile()))
        XCTAssertFalse(Planner.isFeasible(F.hipThrustBand, availability: EquipmentAvailability(), equipment: EquipmentProfile()))
    }

    // MARK: - Контракт: жёсткие ограничения безопасности

    func test_contract_hardConstraints() {
        func passes(_ c: ExerciseCandidate, _ safety: SafetyProfile, on day: CalendarDay = F.day(0)) -> Bool {
            Planner.passesHardConstraints(c, safety: safety, availability: F.fullAvailability, equipment: F.fullEquipment, on: day)
        }
        let careful = SafetyProfile(level: .advanced, restrictions: [UserRestriction(joint: .knee, severity: .careful)])
        let avoid = SafetyProfile(level: .advanced, restrictions: [UserRestriction(joint: .knee, severity: .avoid)])
        XCTAssertTrue(passes(F.gobletSquat, careful), "careful пропускает medium")
        XCTAssertFalse(passes(F.boxJump, careful), "careful исключает high")
        XCTAssertFalse(passes(F.gobletSquat, avoid), "avoid исключает medium")
        XCTAssertTrue(passes(F.hipThrustBand, avoid))

        XCTAssertFalse(passes(F.boxJump, SafetyProfile(level: .novice)), "skill_level выше уровня")
        XCTAssertTrue(passes(F.boxJump, SafetyProfile(level: .intermediate)))
        let conservative = SafetyProfile(level: .advanced, isConservative: true)
        XCTAssertFalse(passes(F.hipThrustBarbell, conservative), "консервативный режим — потолок novice")
        XCTAssertFalse(passes(F.boxJump, conservative), "консервативный режим — без joint_stress high")

        let pain = SafetyProfile(level: .advanced, painEvents: [PainEvent(exerciseSlug: "rdl_band", joint: .lowerBack, occurredOn: F.day(0))])
        XCTAssertFalse(passes(F.rdlBand, pain, on: F.day(14)), "исключено 14 дней включительно")
        XCTAssertTrue(passes(F.rdlBand, pain, on: F.day(15)))
    }

    // MARK: - Контракт: семья, паттерны, фаза — мягкий штраф, не фильтр

    func test_contract_familyLimitPatternMinimumAndPhaseIsSoft() {
        for minutes in [30, 45, 60] {
            let session = build(F.input(week: twoGluteDays, minutes: minutes))
            let families = Dictionary(grouping: session.exercises, by: { F.candidate($0.slug).progressionFamily })
            XCTAssertTrue(families.values.allSatisfy { $0.count <= 2 }, "не более двух из одной семьи")
            XCTAssertGreaterThanOrEqual(patterns(session).count, 3, "\(minutes) минут: минимум трёх паттернов")
        }

        // Прыжковое уходит в овуляторную фазу, когда есть замена, и остаётся, когда её нет.
        let onlyJumps = [F.boxJump, F.rdlBand, F.legCurlBand]
        let ovulatory = F.phaseState(.ovulatory, confidence: 1.0)
        XCTAssertTrue(F.slugs(build(F.input(week: twoGluteDays, library: onlyJumps, cycleState: ovulatory))).contains("box_jump"),
                      "фаза — мягкий штраф, а не фильтр")
        XCTAssertFalse(F.slugs(build(F.input(week: twoGluteDays, minutes: 20, cycleState: ovulatory))).contains("box_jump"))
        XCTAssertTrue(F.slugs(build(F.input(week: twoGluteDays, minutes: 20))).contains("box_jump"),
                      "фикстура: без фазы при 20 минутах прыжок в сборке есть")
    }

    // MARK: - Контракт: пороги готовности §10 — из одного места (ревью 4, находка 1)

    /// SPEC §10 и §7.3: новых порогов не вводим, таймер отдыха и бюджет читают
    /// то же число, что и ±1 подход. Тест держит это поведением, а не сверкой
    /// констант: если у планировщика снова появится свой литерал, полосы
    /// разъедутся.
    func test_contract_readinessThresholdsHaveOneSource() {
        var readiness = Readiness.range.lowerBound
        while readiness <= Readiness.range.upperBound + 1e-9 {
            let delta = Readiness.sessionSetDelta(readiness: readiness)
            let rest = Planner.restFactor(readiness: readiness)
            switch delta {
            case -1: XCTAssertEqual(rest, 1.2, "готовность \(readiness): −1 подход и длинный отдых — одна полоса")
            case 1: XCTAssertEqual(rest, 0.8, "готовность \(readiness): +1 подход и короткий отдых — одна полоса")
            default: XCTAssertEqual(rest, 1.0, "готовность \(readiness): нейтральная полоса")
            }
            readiness += 0.005
        }
        // Границы строгие с обеих сторон.
        XCTAssertEqual(Planner.restFactor(readiness: Readiness.Thresholds.setDecrease), 1.0)
        XCTAssertEqual(Planner.restFactor(readiness: Readiness.Thresholds.setIncrease), 1.0)
        XCTAssertEqual(Planner.lowReadinessThreshold, Readiness.Thresholds.lowReadiness,
                       "порог w9 — тот же, за которым §10 поднимает RIR")
    }

    // MARK: - Контракт: время, порядок, w8/w9

    func test_contract_timeOrderAndPreferenceTerms() {
        XCTAssertEqual(Planner.restFactor(readiness: 0.89), 1.2)
        XCTAssertEqual(Planner.restFactor(readiness: 0.9), 1.0)
        XCTAssertEqual(Planner.restFactor(readiness: 1.05), 1.0)
        XCTAssertEqual(Planner.restFactor(readiness: 1.06), 0.8)
        // setup + подходы × (работа + отдых) − отдых последнего.
        let rdl: Double = 30 + 2 * 130
        let curl: Double = 20 + 2 * 100
        let expected = rdl + curl - 60
        XCTAssertEqual(Planner.estimatedSeconds([(F.rdlBand, 2), (F.legCurlBand, 2)], restFactor: 1), expected, accuracy: 1e-9)

        let session = build(F.input(week: twoGluteDays))
        let order = session.exercises.map { F.candidate($0.slug) }
        if let firstIsolation = order.firstIndex(where: { $0.pattern == .isolation || $0.pattern == .core }) {
            XCTAssertTrue(order[firstIsolation...].allSatisfy { $0.pattern == .isolation || $0.pattern == .core },
                          "многосуставные, потом изоляция")
        }
        let half = (order.count + 1) / 2
        XCTAssertTrue(order.prefix(half).contains { $0.leadingMuscle == .gluteMax }, "акцент в первой половине")
        XCTAssertEqual(session.exercises.map(\.orderIndex), Array(0..<session.exercises.count))

        XCTAssertTrue(Planner.isTechnicalBase(F.hipThrustBarbell))
        XCTAssertFalse(Planner.isTechnicalBase(F.hipThrustBand), "novice — не база")
        var machine = F.hipThrustBarbell
        machine.loadType = .machine
        XCTAssertFalse(Planner.isTechnicalBase(machine), "тренажёр — не технически сложная база")
        XCTAssertEqual(Planner.blockMismatch(F.hipThrustBarbell, block: .deload), 1)
        XCTAssertEqual(Planner.blockMismatch(F.legCurlBand, block: .strength), 1)
        XCTAssertEqual(Planner.blockMismatch(F.hipThrustBarbell, block: .neutral), 0)
    }

    // MARK: - Контракт: ±1 подход на сессию и добавленные подходы §9.5

    func test_contract_sessionSetDeltaAndExtraSets() {
        func total(_ s: BuiltSession) -> Int { s.exercises.reduce(0) { $0 + $1.targetSets } }
        let base = build(F.input(week: twoGluteDays, minutes: 90))
        XCTAssertEqual(total(build(F.input(week: twoGluteDays, minutes: 90, readiness: 1.08))), total(base) + 1)
        XCTAssertEqual(total(build(F.input(week: twoGluteDays, minutes: 90, readiness: 0.88))), total(base) - 1)

        var states = F.familiar
        let first = base.exercises[0].slug
        states[first]!.extraSetsAdded = 2
        let extra = build(F.input(week: twoGluteDays, minutes: 90, states: states))
        let before = base.exercises[0].targetSets
        XCTAssertEqual(extra.exercises.first { $0.slug == first }?.targetSets, min(before + 2, Planner.maxSetsPerExercise))
    }

    // MARK: - Контракт: +1 готовности перебирает подходящие упражнения (ревью, находка 6)

    private func totalSets(_ s: BuiltSession) -> Int { s.exercises.reduce(0) { $0 + $1.targetSets } }

    /// Первое подходящее упражнение уже на потолке пяти подходов — +1 ложится на
    /// следующее подходящее, а не пропадает (§10: +1 не даётся, только если
    /// подходящего упражнения нет вовсе).
    func test_contract_plusOneSkipsCappedExercise() {
        let plain = build(F.input(week: twoGluteDays, minutes: 180))
        var states = F.familiar
        let first = plain.exercises[0].slug
        states[first]!.extraSetsAdded = Planner.maxSetsPerExercise - plain.exercises[0].targetSets
        let capped = build(F.input(week: twoGluteDays, minutes: 180, states: states))
        XCTAssertEqual(capped.exercises.first { $0.slug == first }?.targetSets, Planner.maxSetsPerExercise,
                       "фикстура: первое упражнение на потолке")
        let ready = build(F.input(week: twoGluteDays, minutes: 180, states: states, readiness: 1.08))
        XCTAssertEqual(F.slugs(ready), F.slugs(capped), "фикстура: состав тот же")
        XCTAssertEqual(totalSets(ready), totalSets(capped) + 1, "+1 лёг на следующее подходящее упражнение")
        XCTAssertEqual(ready.exercises.first { $0.slug == first }?.targetSets, Planner.maxSetsPerExercise)
    }

    /// Первое подходящее упражнение не влезает в бюджет — +1 пробуется на
    /// следующем подходящем; утомлённое не получает его никогда.
    func test_contract_plusOneSkipsExerciseOverBudget() {
        var tried: [Int] = []
        let placed = Planner.placeSessionSetIncrease(hasFatiguedMuscle: [false, true, false, false]) { k in
            tried.append(k)
            return k == 2          // 0 не влезает в бюджет, 1 утомлено, 2 принимает
        }
        XCTAssertEqual(placed, 2)
        XCTAssertEqual(tried, [0, 2])
        XCTAssertNil(Planner.placeSessionSetIncrease(hasFatiguedMuscle: [false, true]) { _ in false },
                     "никто не принял — +1 не даётся")
        XCTAssertNil(Planner.placeSessionSetIncrease(hasFatiguedMuscle: [true, true]) { _ in true },
                     "подходящих нет — +1 не даётся")
    }

    // MARK: - Симуляция: шесть недель по пять дней ягодиц (implement-feature §5а)

    /// Тридцать тренировочных дней подряд; каждый собирается от состояния, которое
    /// оставило выполнение предыдущих (утомление переносится через границу недели,
    /// `неделя[m]` — нет). Инварианты: ни одного пустого дня, бюджет не превышен,
    /// недельный glute_max у потолка — не выше его больше чем на структурный
    /// перебор (§7.4: 21.8 при 20), и ни одна неделя не проваливается ниже
    /// половины нормы (дрейф вниз), а пересборка без изменения входа идемпотентна.
    func test_simulation_sixWeeksOfFiveGluteDays_noDriftNoOvershoot() {
        var completed: [CompletedWorkout] = []
        var fatigue: [MuscleSlug: FatigueState] = [:]
        var history = F.weightedHistory()
        var firstBaseline: [String: Double] = [:]
        var lastBaseline: [String: Double] = [:]
        let minutes = 45
        let ceiling = Planner.weeklyRange(level: .intermediate, accented: true).upperBound
        let norm = Planner.weeklyRange(level: .intermediate, accented: true).lowerBound
        var weekly: [Double] = []
        for w in 0..<6 {
            let start = F.day(7 * w)
            var week = (0..<5).map {
                PlannedDay(id: "w\(w)d\($0)", date: start.adding(days: $0), kind: .lower, accent: .gluteMax, vector: F.lowerGlutes)
            }
            var glute = 0.0
            for d in 0..<5 {
                let ctx = WeekContext(
                    weekStart: start, week: week, today: week[d].date, completed: completed, fatigue: fatigue,
                    library: F.library, availability: F.fullAvailability, equipment: F.fullEquipment,
                    safety: SafetyProfile(level: .intermediate), goal: .hypertrophy, sessionMinutes: minutes,
                    exerciseHistory: history,
                    cycle: CycleInputs(events: [], profile: CycleProfile(phaseMode: .noPhases, noPhaseReason: .userChoice)),
                    userSeed: F.seed)
                let plan = Planner.planRemainingDays(ctx)
                XCTAssertEqual(plan, Planner.planRemainingDays(ctx), "неделя \(w) день \(d): пересборка идемпотентна")
                guard let session = plan.sessions[week[d].id] else { XCTFail("неделя \(w) день \(d) не собран"); continue }
                XCTAssertFalse(session.exercises.isEmpty, "неделя \(w) день \(d) пустой")
                XCTAssertLessThanOrEqual(session.estimatedSeconds, Double(minutes * 60))
                glute += session.effectiveVolume[.gluteMax] ?? 0

                // Свёртка журнала — часть входа планировщика (находка 1 первого
                // ревью), поэтому симуляция обязана журнал ВЕСТИ: иначе
                // `lastPerformedAt` стоит на месте, к третьей неделе включается
                // детренированность §9.7, а к шестой упражнение уходит в
                // калибровку — и тест этого не замечает.
                let states = Planner.exerciseStates(history: history, library: F.library,
                                                    goal: .hypertrophy, equipment: F.fullEquipment)
                for e in session.exercises where F.candidate(e.slug).loadType == .dumbbell {
                    guard let state = states[e.slug] else { continue }
                    XCTAssertFalse(state.isInCalibration, "неделя \(w) день \(d): \(e.slug) снова в калибровке")
                    // Журнал ведётся: перерыв между появлениями упражнения не
                    // выходит за мягкую ступень §9.7 (до 21 дня). Со статичным
                    // журналом он растёт до 39 дней и дальше — ровно то, чего
                    // тест раньше не замечал.
                    let gap = state.lastPerformedAt.map { $0.days(until: week[d].date) } ?? .max
                    XCTAssertLessThanOrEqual(gap, 21, "неделя \(w) день \(d): \(e.slug) не тренировался \(gap) дней — журнал не пополняется")
                    XCTAssertNotNil(e.prescribedKg, "неделя \(w) день \(d): у \(e.slug) нет предписанного веса")
                    if let kg = e.prescribedKg {
                        XCTAssertTrue(F.fullEquipment.dumbbellsKg.contains(kg), "вес \(kg) вне лестницы гантелей")
                    }
                    if let baseline = state.baselineKg {
                        if firstBaseline[e.slug] == nil { firstBaseline[e.slug] = baseline }
                        lastBaseline[e.slug] = baseline
                    }
                }

                F.perform(session, on: week[d].date, completed: &completed, fatigue: &fatigue, history: &history)
                week[d].status = .done
            }
            weekly.append(glute)
        }
        for (w, g) in weekly.enumerated() {
            XCTAssertLessThanOrEqual(g, ceiling + 2.0, "неделя \(w): \(g)")
            XCTAssertGreaterThanOrEqual(g, norm / 2, "неделя \(w): \(g)")
        }
        let spread = (weekly.max() ?? 0) - (weekly.min() ?? 0)
        XCTAssertLessThanOrEqual(spread, 4.0, "недели не расходятся со временем: \(weekly)")

        XCTAssertFalse(firstBaseline.isEmpty, "фикстура: в сборку попадали упражнения с весом")
        for (slug, first) in firstBaseline {
            // Базовая линия не улетает вниз. Ровной она не остаётся намеренно: в
            // пятидневной неделе с акцентом упражнение с гантелями попадает в
            // сборку примерно раз в две недели, и §9.7 даёт мягкую ступень ×0.92
            // на каждый возврат, а синтетический фидбэк «нормально» вес обратно
            // не поднимает (это делает §9.4 на «легко»). Запас — один-два таких
            // шага за шесть недель.
            XCTAssertGreaterThanOrEqual(lastBaseline[slug] ?? 0, first * 0.8, "\(slug): базовая линия просела за шесть недель")
        }
    }
}
