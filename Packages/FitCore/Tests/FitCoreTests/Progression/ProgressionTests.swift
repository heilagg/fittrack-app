//  Progression — сценарии 4–13 из SPEC §18 (1–3, 14 закрыты
//  Equipment/WeightLadderTests, см. doc-комментарий в Progression.swift)
//  плюс контрактные тесты на планирование прогрессии (§9.5), калибровку и
//  детренированность (§9.7/9.8), на которые эти сценарии опираются.
//
//  XCTest, а не Swift Testing — то же ограничение окружения (только Command
//  Line Tools), что и в WeightLadderTests.

import XCTest
@testable import FitCore

final class ProgressionTests: XCTestCase {

    private let hypertrophyRange = 8...12  // SPEC §9.1: гипертрофия 8–12

    private func day(_ n: Int) -> CalendarDay {
        CalendarDay(year: 2026, month: 1, day: 1).adding(days: n)
    }

    // MARK: - Сценарии SPEC §18
    //
    // У сид-сессий здесь по два квалифицирующих подхода («нормально»/«тяжело»
    // при попадании в диапазон), и это не украшение: `ExerciseState()`
    // стартует с `isInCalibration = true` — как и колонка `in_calibration` в
    // схеме, — а сценарии §18 описывают поведение ПОСЛЕ калибровки. Без
    // второго подхода условие выхода §9.8 не выполняется, сценарий целиком
    // исполняется по калибровочному пути, и §9.4 вообще не проверяется.
    // Код-ревью многосессионного прогона, 2026-09-08.

    func test_scenario4_bodyweightMaxedOutEscalatesToHarderVariant() {
        // Собственный вес, 30 повторов легко: нет достижимого веса тяжелее
        // (.none), повторы уже расширены до предела и подходы уже добавлены
        // до предела — следующий шаг эскалации (SPEC §9.5, п.3).
        let decision = Progression.planProgression(
            baselineKg: 0,
            baseRange: hypertrophyRange,
            repExtension: 4,
            extraSetsAdded: 2,
            ladder: .none
        )
        XCTAssertEqual(decision, .suggestHarderVariant)
    }

    func test_scenario5_twoFailedInARowTerminatesExercise() {
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [6, 8, 10]))
        let outcome = Progression.nextSet(
            priorFeedback: .failed,
            current: 8,
            feedback: .failed,
            actualReps: 3,
            range: hypertrophyRange,
            isCalibration: false,
            ladder: ladder
        )
        XCTAssertEqual(outcome, .terminateExercise)
    }

    func test_scenario6_failedFirstSetGivesCorrectWeightsForRemainingSets() {
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [2, 4, 6, 8, 10]))

        // Подход 1: failed на 10 кг → округляем вниз до достижимой ступени.
        let outcome1 = Progression.nextSet(
            priorFeedback: nil,
            current: 10,
            feedback: .failed,
            actualReps: 5,
            range: hypertrophyRange,
            isCalibration: false,
            ladder: ladder
        )
        XCTAssertEqual(outcome1, .nextWeight(8))

        // Подход 2: ok на 8 кг, в диапазоне — вес не трогаем.
        guard case .nextWeight(let weight2) = outcome1 else { return XCTFail("ожидался следующий вес") }
        let outcome2 = Progression.nextSet(
            priorFeedback: .failed,
            current: weight2,
            feedback: .ok,
            actualReps: 9,
            range: hypertrophyRange,
            isCalibration: false,
            ladder: ladder
        )
        XCTAssertEqual(outcome2, .nextWeight(8))

        // Подход 3: hard ровно на нижней границе диапазона — не откатываем.
        guard case .nextWeight(let weight3) = outcome2 else { return XCTFail("ожидался следующий вес") }
        let outcome3 = Progression.nextSet(
            priorFeedback: .ok,
            current: weight3,
            feedback: .hard,
            actualReps: 8,
            range: hypertrophyRange,
            isCalibration: false,
            ladder: ladder
        )
        XCTAssertEqual(outcome3, .nextWeight(8))

        // Подход 4: easy на верху диапазона — шаг вверх до следующей ступени.
        guard case .nextWeight(let weight4) = outcome3 else { return XCTFail("ожидался следующий вес") }
        let outcome4 = Progression.nextSet(
            priorFeedback: .hard,
            current: weight4,
            feedback: .easy,
            actualReps: 12,
            range: hypertrophyRange,
            isCalibration: false,
            ladder: ladder
        )
        XCTAssertEqual(outcome4, .nextWeight(10))
    }

    func test_scenario7_detrainingGapsGiveCorrectMultipliers() {
        XCTAssertEqual(Progression.detrainingAdjustment(daysSinceLastPerformed: 3), .none)
        XCTAssertEqual(Progression.detrainingAdjustment(daysSinceLastPerformed: 15), .mildDecay)
        XCTAssertEqual(Progression.detrainingAdjustment(daysSinceLastPerformed: 30), .moderateDecay)
        XCTAssertEqual(Progression.detrainingAdjustment(daysSinceLastPerformed: 60), .restartCalibration)
    }

    func test_scenario8_threeStagnantSessionsDeloadSixSuggestReplacement() {
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [8, 10, 12]))
        let heldSet = SetResult(prescribedKg: nil, actualKg: nil, actualReps: 9, feedback: .ok)  // в диапазоне, не у верха, не под rep_min

        var sessions = [
            ExerciseSession(performedAt: day(0), readiness: 1.0, isCalibration: false,
                             sets: [SetResult(prescribedKg: 10, actualKg: 10, actualReps: 9, feedback: .ok),
                                    SetResult(prescribedKg: 10, actualKg: 10, actualReps: 9, feedback: .ok)])
        ]
        for n in 1...6 {
            sessions.append(ExerciseSession(performedAt: day(n), readiness: 1.0, isCalibration: false, sets: [heldSet]))
        }

        // После трёх застойных сессий (n=1..3): deload −10%.
        let afterThree = Progression.rebuildStates(from: Array(sessions[0...3]), baseRange: hypertrophyRange, ladder: ladder)
        XCTAssertEqual(afterThree.stallCount, 1)
        XCTAssertEqual(afterThree.baselineKg ?? -1, 9.0, accuracy: 0.0001)

        // После шести (n=1..6): предложение замены, второго deload нет.
        let afterSix = Progression.rebuildStates(from: sessions, baseRange: hypertrophyRange, ladder: ladder)
        XCTAssertEqual(afterSix.stallCount, 2)
        XCTAssertEqual(afterSix.baselineKg ?? -1, 9.0, accuracy: 0.0001)
    }

    func test_scenario9_easyBelowRepMinDoesNotRaiseWeight() {
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [6, 8, 10]))
        // Пользователь сам снизил вес: повторы (5) ниже rep_min (8), но
        // ощущение — «легко». Верх диапазона не достигнут → вес не растим.
        let outcome = Progression.nextSet(
            priorFeedback: nil,
            current: 8,
            feedback: .easy,
            actualReps: 5,
            range: hypertrophyRange,
            isCalibration: false,
            ladder: ladder
        )
        XCTAssertEqual(outcome, .nextWeight(8))
    }

    func test_scenario10_userEnteredHeavierWeightRaisesBaseline() {
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [8, 10, 12]))
        let sessions = [
            ExerciseSession(performedAt: day(0), readiness: 1.0, isCalibration: false,
                             sets: [SetResult(prescribedKg: 8, actualKg: 8, actualReps: 9, feedback: .ok),
                                    SetResult(prescribedKg: 8, actualKg: 8, actualReps: 9, feedback: .ok)]),
            // Пользователь сам взял 12 кг (не 10, следующую по лестнице
            // ступень от 8) и отработал верх диапазона нормально.
            ExerciseSession(performedAt: day(1), readiness: 1.0, isCalibration: false,
                             sets: [SetResult(prescribedKg: 8, actualKg: 12, actualReps: 12, feedback: .ok)]),
        ]

        let state = Progression.rebuildStates(from: sessions, baseRange: hypertrophyRange, ladder: ladder)

        // Обычный каскад (SPEC §9.5) дал бы только следующую ступень от
        // старого baseline (10) — здесь baseline поднимается до фактически
        // уже поднятого и подтверждённого веса (12), а не до 10.
        XCTAssertEqual(state.baselineKg ?? -1, 12, accuracy: 0.0001)
    }

    func test_scenario11_userEnteredLighterWeightLowersBaselineAccountingForOverride() {
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [4, 6, 8, 10]))
        let sessions = [
            ExerciseSession(performedAt: day(0), readiness: 1.0, isCalibration: false,
                             sets: [SetResult(prescribedKg: 10, actualKg: 10, actualReps: 9, feedback: .ok),
                                    SetResult(prescribedKg: 10, actualKg: 10, actualReps: 9, feedback: .ok)]),
            // Пользователь сам снизил вес до 6 (на две ступени от 10, минуя
            // 8) и всё равно было тяжело.
            ExerciseSession(performedAt: day(1), readiness: 1.0, isCalibration: false,
                             sets: [SetResult(prescribedKg: 10, actualKg: 6, actualReps: 9, feedback: .hard)]),
        ]

        let state = Progression.rebuildStates(from: sessions, baseRange: hypertrophyRange, ladder: ladder)

        // Простое «на одну ступень вниз от старого baseline» дало бы 8 —
        // выше того, что пользователь уже показал как тяжёлое. Новая
        // базовая линия обязана учитывать уже сниженный вес и не
        // штрафовать дважды.
        XCTAssertEqual(state.baselineKg ?? -1, 6, accuracy: 0.0001)
    }

    func test_scenario12_lowReadinessDampensBaselineUpdate() {
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [4, 6, 8, 10]))
        let sessions = [
            ExerciseSession(performedAt: day(0), readiness: 1.0, isCalibration: false,
                             sets: [SetResult(prescribedKg: 10, actualKg: 10, actualReps: 9, feedback: .ok),
                                    SetResult(prescribedKg: 10, actualKg: 10, actualReps: 9, feedback: .ok)]),
            // Предписано 8 (baseline 10 × readiness 0.8, §9.6), взято 6 — оверрайд вниз.
            ExerciseSession(performedAt: day(1), readiness: 0.8, isCalibration: false,
                             sets: [SetResult(prescribedKg: 8, actualKg: 6, actualReps: 9, feedback: .hard)]),
        ]

        let state = Progression.rebuildStates(from: sessions, baseRange: hypertrophyRange, ladder: ladder)

        // Тот же ввод, что в сценарии 11, но readiness 0.8 → демпфирование
        // ×0.4: 10 + (6 − 10) × 0.4 = 8.4, а не полные 6.
        XCTAssertEqual(state.baselineKg ?? -1, 8.4, accuracy: 0.0001)
    }

    func test_scenario13_nonPositiveCurrentWeightClampsToLadderMinimum() {
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [2, 4, 6, 8]))

        let zero = Progression.nextSet(
            priorFeedback: nil, current: 0, feedback: .failed, actualReps: 0,
            range: hypertrophyRange, isCalibration: false, ladder: ladder
        )
        XCTAssertEqual(zero, .nextWeight(2))

        let negative = Progression.nextSet(
            priorFeedback: nil, current: -5, feedback: .failed, actualReps: 0,
            range: hypertrophyRange, isCalibration: false, ladder: ladder
        )
        XCTAssertEqual(negative, .nextWeight(2))
    }

    // MARK: - Контракт: planProgression (SPEC §9.5), не входит в номерные сценарии

    func test_planProgression_normalStepWithinTenPercent() {
        let ladder = WeightLadder.arithmetic(step: 0.5)
        let decision = Progression.planProgression(
            baselineKg: 10, baseRange: hypertrophyRange, repExtension: 0, extraSetsAdded: 0, ladder: ladder
        )
        XCTAssertEqual(decision, .increaseWeight(to: 10.5))
    }

    func test_planProgression_extendsRepsWhenJumpTooLargeAndExtensionAvailable() {
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [2, 4, 6, 8]))
        let decision = Progression.planProgression(
            baselineKg: 6, baseRange: hypertrophyRange, repExtension: 0, extraSetsAdded: 0, ladder: ladder
        )
        XCTAssertEqual(decision, .extendReps)
    }

    func test_planProgression_jumpsWithRepResetWhenExtensionExhausted() {
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [2, 4, 6, 8]))
        let decision = Progression.planProgression(
            baselineKg: 6, baseRange: hypertrophyRange, repExtension: 4, extraSetsAdded: 0, ladder: ladder
        )
        XCTAssertEqual(decision, .increaseWeightWithRepReset(to: 8, newRange: 8...10))
    }

    func test_planProgression_noHeavierWeightCascadesRepsThenSetsThenVariant() {
        // Нет ни гантелей, ни штанги, ни тренажёра — тяжелее нет вообще.
        // SPEC §9.5: сначала повторы, потом подходы, потом вариант.
        XCTAssertEqual(
            Progression.planProgression(baselineKg: 0, baseRange: hypertrophyRange, repExtension: 0, extraSetsAdded: 0, ladder: .none),
            .extendReps
        )
        XCTAssertEqual(
            Progression.planProgression(baselineKg: 0, baseRange: hypertrophyRange, repExtension: 4, extraSetsAdded: 0, ladder: .none),
            .addSet
        )
        XCTAssertEqual(
            Progression.planProgression(baselineKg: 0, baseRange: hypertrophyRange, repExtension: 4, extraSetsAdded: 2, ladder: .none),
            .suggestHarderVariant
        )
    }

    // MARK: - Контракт: калибровка и детренированность, не входит в номерные сценарии

    func test_calibrationExitsAfterTwoConsecutiveQualifyingSets() {
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [8, 10]))
        let session = ExerciseSession(
            performedAt: day(0), readiness: 1.0, isCalibration: true,
            sets: [
                SetResult(prescribedKg: 8, actualKg: 8, actualReps: 9, feedback: .ok),
                SetResult(prescribedKg: 8, actualKg: 8, actualReps: 9, feedback: .ok),
            ]
        )
        let state = Progression.rebuildStates(from: [session], baseRange: hypertrophyRange, ladder: ladder)
        XCTAssertFalse(state.isInCalibration)
        XCTAssertEqual(state.baselineKg ?? -1, 8, accuracy: 0.0001)
    }

    func test_detrainingRestartCalibrationAppliesMultiplierAndReentersCalibration() {
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [6, 8, 10]))
        let sessions = [
            ExerciseSession(
                performedAt: day(0), readiness: 1.0, isCalibration: true,
                sets: [
                    SetResult(prescribedKg: 10, actualKg: 10, actualReps: 9, feedback: .ok),
                    SetResult(prescribedKg: 10, actualKg: 10, actualReps: 9, feedback: .ok),
                ]
            ),
            // 60 дней спустя — перерыв > 45 дней.
            ExerciseSession(performedAt: day(60), readiness: 1.0, isCalibration: false,
                             sets: [SetResult(prescribedKg: nil, actualKg: nil, actualReps: 9, feedback: .ok)]),
        ]

        let state = Progression.rebuildStates(from: sessions, baseRange: hypertrophyRange, ladder: ladder)

        XCTAssertEqual(state.baselineKg ?? -1, 7.5, accuracy: 0.0001)
        XCTAssertTrue(state.isInCalibration)
    }

    // MARK: - Регрессии код-ревью feature/progression, 2026-09-07
    //
    // Каждый тест здесь закрывает подтверждённый прогоном дефект свёртки.
    // Держатся отдельно от обязательных сценариев §18: те описывают продукт,
    // эти — конкретные способы его сломать, найденные ревью.

    /// Хелпер: сессия из подходов вида (предписано, фактически, повторы, фидбэк).
    private func session(
        _ dayOffset: Int,
        readiness: Double = 1.0,
        isCalibration: Bool = false,
        _ sets: [(Double?, Double?, Int, Feedback)]
    ) -> ExerciseSession {
        ExerciseSession(
            performedAt: day(dayOffset), readiness: readiness, isCalibration: isCalibration,
            sets: sets.map { SetResult(prescribedKg: $0.0, actualKg: $0.1, actualReps: $0.2, feedback: $0.3) }
        )
    }

    func test_finding1_singleFailedSetDoesNotLowerBaseline() {
        // Опорный вес брался из ПОСЛЕДНЕГО подхода, а его понижает сама §9.3
        // на этом же 'failed' — признак «пользователь снизил вес» выполнялся
        // сам собой, и одна сессия с одним 'failed' роняла baseline 10 → 8.
        // §9.4 требует двух сессий подряд или двух 'failed' в одной.
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [4, 6, 8, 10]))
        let sessions = [
            session(0, [(10, 10, 9, .ok), (10, 10, 9, .ok)]),
            // Первый подход провален на предписанных 10, дальше §9.3 увела на 8.
            session(2, [(10, 10, 6, .failed), (8, 8, 9, .ok), (8, 8, 9, .ok)]),
        ]
        let state = Progression.rebuildStates(from: sessions, baseRange: hypertrophyRange, ladder: ladder)
        XCTAssertEqual(state.baselineKg ?? -1, 10, accuracy: 0.0001)
    }

    func test_finding1_acceptedPrescriptionOnLowReadinessDoesNotLowerBaseline() {
        // Сравнение опорного веса с baseline вместо предписания означало, что
        // на дне с readiness 0.8 принятое как есть предписание (8 при baseline
        // 10) читалось как «пользователь снизил вес». С 'hard' это давало
        // понижение — ровно случай, ради которого написан §9.6.
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [4, 6, 8, 10]))
        let sessions = [
            session(0, [(10, 10, 9, .ok), (10, 10, 9, .ok)]),
            session(2, readiness: 0.8, [(8, 8, 9, .hard)]),
        ]
        let state = Progression.rebuildStates(from: sessions, baseRange: hypertrophyRange, ladder: ladder)
        XCTAssertEqual(state.baselineKg ?? -1, 10, accuracy: 0.0001)
    }

    func test_finding6_acceptedPrescriptionOnHighReadinessDoesNotRaiseBaseline() {
        // Зеркальный дефект на стороне повышения: readiness доходит до 1.10
        // (§10), и принятое предписание 12 при baseline 10 читалось как
        // «пользователь взял тяжелее» → baseline прыгал на 12 в обход
        // проверки «прыжок ≤ 10%» (§9.5). Прыжок здесь 20%, поэтому
        // правильная реакция — расширение диапазона, а не повышение веса.
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [10, 12]))
        let sessions = [
            session(0, [(10, 10, 9, .ok), (10, 10, 9, .ok)]),
            session(2, readiness: 1.10, [(12, 12, 12, .ok)]),
        ]
        let state = Progression.rebuildStates(from: sessions, baseRange: hypertrophyRange, ladder: ladder)
        XCTAssertEqual(state.baselineKg ?? -1, 10, accuracy: 0.0001)
        XCTAssertEqual(state.repExtension, 2)
    }

    func test_finding2_longBreakResetsRepExtensionAndStallCount() {
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [10, 12]))

        // (а) repExtension: перерыв 22–45 дней его сбрасывал, а перерыв >45
        // дней — нет, из-за чего более длинный перерыв оставлял БОЛЕЕ жёсткую
        // цель по повторам на весе, срезанном на 25%.
        func afterBreak(_ gap: Int) -> ExerciseState {
            Progression.rebuildStates(
                from: [
                    session(0, [(10, 10, 9, .ok), (10, 10, 9, .ok)]),
                    session(1, [(10, 10, 12, .easy)]),   // прыжок 20% → extendReps
                    session(1 + gap, [(nil, nil, 9, .ok)]),
                ],
                baseRange: hypertrophyRange, ladder: ladder
            )
        }
        XCTAssertEqual(afterBreak(30).repExtension, 0, "перерыв 22–45 дней сбрасывает repExtension")
        XCTAssertEqual(afterBreak(60).repExtension, 0, "перерыв >45 дней не может сбрасывать меньше")

        // (б) stallCount: полный рестарт — надмножество .moderateDecay, он
        // обязан сбрасывать и счётчик застоя.
        let afterStallThenBreak = Progression.rebuildStates(
            from: [
                session(0, [(10, 10, 9, .ok), (10, 10, 9, .ok)]),
                session(1, [(10, 10, 9, .ok)]),
                session(2, [(10, 10, 9, .ok)]),
                session(3, [(10, 10, 9, .ok)]),   // третья застойная → stallCount 1, deload
                session(63, [(nil, nil, 9, .ok)]),
            ],
            baseRange: hypertrophyRange, ladder: ladder
        )
        XCTAssertEqual(afterStallThenBreak.stallCount, 0)
        XCTAssertTrue(afterStallThenBreak.isInCalibration)
    }

    func test_finding3_raiseBranchNeverLowersBaseline() {
        // roundToAchievable(.up) клэмпит ВНИЗ к максимуму лестницы, а baseline
        // сидируется из пользовательского actual_kg и лестницей не ограничен
        // (тренировка в зале при домашнем инвентаре). Ветка ПОВЫШЕНИЯ роняла
        // baseline 20 → 8. Смены инвентаря для этого не требуется.
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [4, 6, 8]))
        let sessions = [
            session(0, [(20, 20, 9, .ok), (20, 20, 9, .ok)]),
            session(1, [(20, 25, 12, .ok)]),   // оверрайд вверх, верх диапазона
        ]
        let state = Progression.rebuildStates(from: sessions, baseRange: hypertrophyRange, ladder: ladder)
        XCTAssertEqual(state.baselineKg ?? -1, 20, accuracy: 0.0001)
        // Тяжелее на лестнице нет → честный каскад §9.5: расширение повторов.
        XCTAssertEqual(state.repExtension, 2)
    }

    func test_finding4_calibrationSessionBreaksUnderRepMinRun() {
        // previousSessionUnderRepMin присваивался только в конце тела цикла,
        // а calibration-сессия уходила по continue — две несмежные сессии с
        // недобором считались «двумя подряд» и давали понижение.
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [4, 6, 8, 10]))
        let sessions = [
            session(0, [(10, 10, 9, .ok), (10, 10, 9, .ok)]),
            session(1, [(10, 10, 5, .hard)]),
            session(2, isCalibration: true, [(10, 10, 9, .ok)]),
            session(3, [(10, 10, 5, .hard)]),
        ]
        let state = Progression.rebuildStates(from: sessions, baseRange: hypertrophyRange, ladder: ladder)
        XCTAssertEqual(state.baselineKg ?? -1, 10, accuracy: 0.0001)
    }

    func test_finding4_control_twoConsecutiveUnderRepMinStillLowers() {
        // Положительный контроль: правка не должна была отключить сам §9.4.
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [4, 6, 8, 10]))
        let sessions = [
            session(0, [(10, 10, 9, .ok), (10, 10, 9, .ok)]),
            session(1, [(10, 10, 5, .hard)]),
            session(2, [(10, 10, 5, .hard)]),
        ]
        let state = Progression.rebuildStates(from: sessions, baseRange: hypertrophyRange, ladder: ladder)
        XCTAssertEqual(state.baselineKg ?? -1, 8, accuracy: 0.0001)
    }

    func test_finding4_control_normalSessionBetweenUnderRepMinDoesNotLower() {
        // Контрольный случай: недобор / обычная сессия / недобор. Две сессии
        // с недобором НЕ подряд, поэтому понижение срабатывать не должно.
        //
        // Три сессии без прогресса подряд при этом дают законный deload по
        // застою (§9.4), и именно он объясняет 9.0. Утверждение различает два
        // механизма однозначно: понижение дало бы шаг вниз по лестнице (8.0)
        // и обнулило бы stallCount, deload даёт ×0.90 (9.0) при stallCount 1.
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [4, 6, 8, 10]))
        let sessions = [
            session(0, [(10, 10, 9, .ok), (10, 10, 9, .ok)]),
            session(1, [(10, 10, 5, .hard)]),
            session(2, [(10, 10, 9, .ok)]),
            session(3, [(10, 10, 5, .hard)]),
        ]
        let state = Progression.rebuildStates(from: sessions, baseRange: hypertrophyRange, ladder: ladder)
        XCTAssertEqual(state.baselineKg ?? -1, 9.0, accuracy: 0.0001)
        XCTAssertEqual(state.stallCount, 1)
    }

    func test_twoConsecutiveUnderRepMinAfterCalibrationLower() {
        // Переписан после код-ревью многосессионного прогона (2026-09-08).
        // Прежняя версия называлась «сидирующая сессия участвует в прогоне по
        // недобору» и проверяла премиссу, ставшую НЕДОСТИЖИМОЙ: режим
        // калибровки определяется состоянием, `ExerciseState()` стартует с
        // `isInCalibration = true`, значит первая сессия любого упражнения —
        // калибровочная, а калибровка прогон обрывает. Ветка присвоения флага
        // смежности в сидировании осталась в коде как защитная, но при
        // текущем значении по умолчанию в неё не попасть.
        //
        // Проверяется то, что реально работает: две подряд сессии с недобором
        // ПОСЛЕ выхода из калибровки понижают базовую линию.
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [4, 6, 8, 10]))
        let sessions = [
            session(0, [(10, 10, 10, .ok), (10, 10, 10, .ok)]),   // выход из калибровки
            session(1, [(10, 10, 5, .hard)]),
            session(2, [(10, 10, 5, .hard)]),
        ]
        let state = Progression.rebuildStates(from: sessions, baseRange: hypertrophyRange, ladder: ladder)
        XCTAssertEqual(state.baselineKg ?? -1, 8, accuracy: 0.0001)
    }

    func test_sweep_calibrationExitCounterDoesNotSpanBreak() {
        // «Два подхода подряд» (§9.8) не может охватывать перерыв: подход до
        // 30-дневного перерыва и подход после него выводили из калибровки.
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [6, 8, 10]))
        let sessions = [
            session(0, isCalibration: true, [(8, 8, 9, .ok)]),
            session(30, [(nil, nil, 9, .ok)]),
        ]
        let state = Progression.rebuildStates(from: sessions, baseRange: hypertrophyRange, ladder: ladder)
        XCTAssertTrue(state.isInCalibration, "перерыв обрывает прогон подходов для выхода из калибровки")
    }


    // MARK: - Регрессии код-ревью 3b92caa, 2026-09-07
    //
    // Три находки на сам исправляющий коммит: он поставил guard «повышение не
    // может понизить» в ветке повышения и ничего симметричного — в ветке
    // понижения. Лечится не четвёртым guard'ом, а инвариантом направления в
    // BaselineMove.apply, через который теперь идёт всякий сдвиг baseline.

    func test_declinedReadinessBonusDoesNotLowerBaseline() {
        // readiness 1.10 → предписание 12 при baseline 10. Пользователь берёт
        // РОВНО свои 10, выполняет 12 повторов (верх диапазона) и отмечает
        // «тяжело». Раньше «взяла легче предписанного» + hard роняло baseline
        // до 8 — то есть все цели выполнены на своём рабочем весе, а вес
        // срезан. Отказ от надбавки готовности оверрайдом не является.
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [8, 10, 12]))
        let sessions = [
            session(0, [(10, 10, 9, .ok), (10, 10, 9, .ok)]),
            session(2, readiness: 1.10, [(12, 10, 12, .hard)]),
        ]
        let state = Progression.rebuildStates(from: sessions, baseRange: hypertrophyRange, ladder: ladder)
        XCTAssertEqual(state.baselineKg ?? -1, 10, accuracy: 0.0001)
    }

    func test_declinedBonusAboveOwnBaselineDoesNotLower() {
        // Тот же дефект, вариант со взятым весом строго ВЫШЕ базовой линии:
        // предписано 12, взято 11, baseline 10.
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [8, 10, 11, 12]))
        let sessions = [
            session(0, [(10, 10, 9, .ok), (10, 10, 9, .ok)]),
            session(2, readiness: 1.10, [(12, 11, 9, .hard)]),
        ]
        let state = Progression.rebuildStates(from: sessions, baseRange: hypertrophyRange, ladder: ladder)
        XCTAssertEqual(state.baselineKg ?? -1, 10, accuracy: 0.0001)
    }

    func test_control_genuineDownwardOverrideStillLowers() {
        // Контроль: настоящий оверрайд вниз (легче и предписания, и базовой
        // линии) обязан по-прежнему понижать — §18 сценарий 11 не отключён.
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [4, 6, 8, 10]))
        let sessions = [
            session(0, [(10, 10, 9, .ok), (10, 10, 9, .ok)]),
            session(1, [(10, 6, 9, .hard)]),
        ]
        let state = Progression.rebuildStates(from: sessions, baseRange: hypertrophyRange, ladder: ladder)
        XCTAssertEqual(state.baselineKg ?? -1, 6, accuracy: 0.0001)
    }

    func test_loweringNeverRaisesBaseline() {
        // roundToAchievable(_, .down) клэмпит ВВЕРХ к минимуму лестницы, а
        // baseline сидируется из пользовательского actual_kg и лестницей не
        // ограничен (первая сессия на чужом инвентаре, 3 кг при домашних
        // [4,6,8]). Ветка ПОНИЖЕНИЯ поднимала базовую линию 3 → 4.
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [4, 6, 8]))
        let sessions = [
            session(0, [(3, 3, 9, .ok), (3, 3, 9, .ok)]),
            session(1, [(3, 1, 9, .hard)]),
        ]
        let state = Progression.rebuildStates(from: sessions, baseRange: hypertrophyRange, ladder: ladder)
        XCTAssertEqual(state.baselineKg ?? -1, 3, accuracy: 0.0001, "понижать некуда — базовая линия остаётся на месте")
    }

    func test_calibrationSeedingSessionBreaksUnderRepMinRun() {
        // По §9.8 первые 2–3 тренировки калибровочные, то есть первая сессия
        // почти всегда И сидирующая, И калибровочная. Раньше сидирующая ветка
        // выходила раньше калибровочной проверки, и политика «калибровка
        // обрывает прогон» молча не применялась.
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [4, 6, 8, 10]))
        let sessions = [
            // Первому подходу нужны повторы в диапазоне, иначе сессия ничего
            // не устанавливает и сидировать будет нечем (см. establishedWeight);
            // проверяем здесь смежность прогонов, а не сидирование.
            session(0, isCalibration: true, [(10, 10, 10, .ok), (10, 10, 5, .hard)]),
            session(1, [(10, 10, 5, .hard)]),
        ]
        let state = Progression.rebuildStates(from: sessions, baseRange: hypertrophyRange, ladder: ladder)
        XCTAssertEqual(state.baselineKg ?? -1, 10, accuracy: 0.0001)
    }

    func test_control_calibrationSeedingSessionStillSeedsBaseline() {
        // Порядок веток изменён, но калибровочная сессия обязана остаться
        // источником начальной базовой линии: калибровка и есть способ
        // подобрать вес (§9.8).
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [4, 6, 8, 10]))
        let state = Progression.rebuildStates(
            from: [session(0, isCalibration: true, [(8, 8, 9, .ok)])],
            baseRange: hypertrophyRange, ladder: ladder
        )
        XCTAssertEqual(state.baselineKg ?? -1, 8, accuracy: 0.0001)
    }

    // MARK: - Инвариант направления (BaselineMove)

    func test_regressionNet_corpusProducesNoAnomalies() {
        // ЧЕСТНАЯ ОГОВОРКА: сегодня этот тест упасть не может, и доказывает он
        // меньше, чем кажется по названию. Каждая точка вызова move() внутри
        // свёртки предварительно отфильтрована raiseTarget/lowerTarget, так
        // что инвариант в BaselineMove.apply оттуда недостижим, и ноль
        // аномалий здесь — тавтология, а не свидетельство.
        //
        // Тест оставлен как СЕТЬ НА БУДУЩЕЕ: ветка, добавленная в обход
        // пред-фильтра, его повалит, не дожидаясь отдельного теста именно на
        // неё. Корпус подобран так, чтобы задеть каждую ветку, применяющую
        // сдвиг: оверрайд вверх и вниз, шаг по лестнице, deload по застою,
        // все три вердикта детренированности.
        //
        // Доказательство того, что инвариант действительно работает, дают три
        // прямых теста на applier ниже: test_invariant_rejectsRaiseThatWouldLower,
        // test_invariant_rejectsLowerThatWouldRaise и
        // test_invariant_rejectsOverrideOnWrongSideOfBaseline.
        let normal = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [4, 6, 8, 10, 12]))
        let sparse = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [4, 6, 8]))
        let single = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [8]))

        let corpus: [(String, [ExerciseSession], WeightLadder)] = [
            ("оверрайд вверх", [session(0, [(8, 8, 9, .ok), (8, 8, 9, .ok)]), session(1, [(8, 12, 12, .ok)])], normal),
            ("оверрайд вниз", [session(0, [(10, 10, 9, .ok), (10, 10, 9, .ok)]), session(1, [(10, 6, 9, .hard)])], normal),
            ("шаг по лестнице", [session(0, [(10, 10, 9, .ok), (10, 10, 9, .ok)]), session(1, [(10, 10, 12, .easy)])], normal),
            ("две подряд с недобором", [session(0, [(10, 10, 9, .ok), (10, 10, 9, .ok)]), session(1, [(10, 10, 5, .hard)]), session(2, [(10, 10, 5, .hard)])], normal),
            ("deload по застою", [session(0, [(10, 10, 9, .ok), (10, 10, 9, .ok)]), session(1, [(10, 10, 9, .ok)]), session(2, [(10, 10, 9, .ok)]), session(3, [(10, 10, 9, .ok)])], normal),
            ("детренированность 15д", [session(0, [(10, 10, 9, .ok), (10, 10, 9, .ok)]), session(15, [(10, 10, 9, .ok)])], normal),
            ("детренированность 30д", [session(0, [(10, 10, 9, .ok), (10, 10, 9, .ok)]), session(30, [(10, 10, 9, .ok)])], normal),
            ("детренированность 60д", [session(0, [(10, 10, 9, .ok), (10, 10, 9, .ok)]), session(60, [(10, 10, 9, .ok)])], normal),
            ("baseline выше максимума лестницы", [session(0, [(20, 20, 9, .ok), (20, 20, 9, .ok)]), session(1, [(20, 25, 12, .ok)])], sparse),
            ("baseline ниже минимума лестницы", [session(0, [(3, 3, 9, .ok), (3, 3, 9, .ok)]), session(1, [(3, 1, 9, .hard)])], sparse),
            ("отказ от надбавки готовности", [session(0, [(10, 10, 9, .ok), (10, 10, 9, .ok)]), session(2, readiness: 1.10, [(12, 10, 12, .hard)])], normal),
            ("исчерпанная лестница", [session(0, [(8, 8, 9, .ok), (8, 8, 9, .ok)]), session(1, [(8, 8, 20, .easy)]), session(2, [(8, 8, 20, .easy)]), session(3, [(8, 8, 20, .easy)])], single),
            ("калибровочная первой", [session(0, isCalibration: true, [(10, 10, 5, .hard)]), session(1, [(10, 10, 5, .hard)])], normal),
            // Калибровка теперь двигает базовую линию, значит у неё есть ход,
            // значит есть что проверять на нарушение направления.
            ("калибровка вверх", [session(0, isCalibration: true, [(4, 4, 20, .easy), (6, 6, 20, .easy)]),
                                  session(2, isCalibration: true, [(6, 8, 20, .easy), (8, 10, 12, .ok)])], normal),
            ("калибровка вниз", [session(0, isCalibration: true, [(10, 10, 12, .ok), (12, 12, 12, .ok)]),
                                 session(2, isCalibration: true, [(12, 12, 4, .failed), (10, 8, 12, .ok)])], normal),
            ("калибровка без установленного веса", [session(0, isCalibration: true, [(8, 8, 12, .ok)]),
                                                    session(2, isCalibration: true, [(8, 8, 3, .failed)])], normal),
        ]

        for (name, sessions, ladder) in corpus {
            let result = Progression.rebuildStatesWithDiagnostics(
                from: sessions, baseRange: hypertrophyRange, ladder: ladder
            )
            XCTAssertTrue(result.anomalies.isEmpty, "«\(name)» нарушил инвариант направления: \(result.anomalies)")
        }
    }

    func test_invariant_rejectsRaiseThatWouldLower() {
        // Ветка отката исполняется и в тестах — в этом весь смысл выбора
        // «возврат аномалии» вместо precondition/assert: при трапе XCTest
        // ничего не поймал бы, а при assert-в-debug эта ветка в тестах
        // никогда бы не исполнилась.
        var baseline: Double? = 20
        let anomaly = BaselineMove.apply(
            .raise(to: 8, reason: .ladderStep), to: &baseline, openingWeight: 25, readiness: 1.0
        )
        XCTAssertEqual(baseline, 20, "базовая линия не сдвинулась")
        XCTAssertEqual(anomaly, .raiseWouldNotRaise(from: 20, to: 8, reason: .ladderStep))
    }

    func test_invariant_rejectsLowerThatWouldRaise() {
        var baseline: Double? = 3
        let anomaly = BaselineMove.apply(
            .lower(to: 4, reason: .ladderStep), to: &baseline, openingWeight: 1, readiness: 1.0
        )
        XCTAssertEqual(baseline, 3)
        XCTAssertEqual(anomaly, .lowerWouldNotLower(from: 3, to: 4, reason: .ladderStep))
    }

    func test_invariant_rejectsOverrideOnWrongSideOfBaseline() {
        // Сеть под effectiveOverride: даже если триггер однажды снова начнёт
        // считать отказ от надбавки оверрайдом, сдвиг не применится.
        var baseline: Double? = 10
        let anomaly = BaselineMove.apply(
            .lower(to: 8, reason: .userOverride), to: &baseline, openingWeight: 10, readiness: 1.0
        )
        XCTAssertEqual(baseline, 10, "открывающий вес не ниже базовой линии — это не оверрайд вниз")
        XCTAssertEqual(anomaly, .overrideAgainstBaseline(opening: 10, baseline: 10, raising: false))
    }

    func test_invariant_appliesValidMovesAndDampsOnlyFeedbackDriven() {
        // Положительный контроль: корректные ходы проходят, и демпфирование
        // §9.6 применяется к фидбэк-обусловленным ходам, но не к
        // детренированности с deload'ом (те приходят готовым множителем).
        var feedbackDriven: Double? = 10
        XCTAssertNil(BaselineMove.apply(
            .lower(to: 6, reason: .userOverride), to: &feedbackDriven, openingWeight: 6, readiness: 0.8
        ))
        XCTAssertEqual(feedbackDriven ?? -1, 8.4, accuracy: 0.0001, "10 + (6 − 10) × 0.4")

        var decay: Double? = 10
        XCTAssertNil(BaselineMove.apply(
            .lower(to: 7.5, reason: .detraining), to: &decay, openingWeight: nil, readiness: 0.8
        ))
        XCTAssertEqual(decay ?? -1, 7.5, accuracy: 0.0001, "детренированность не демпфируется")
    }


    // MARK: - Регрессии код-ревью e1a7ee7, 2026-09-08

    func test_acceptedLowReadinessPrescriptionDoesNotDeepenTheDrop() {
        // lowerTarget спрашивал «пользователь сам снизил вес?» сырым
        // сравнением refWeight < baseline, а оно истинно и когда вес срезала
        // ГОТОВНОСТЬ, а пользователь предписание просто принял. Понижение по
        // двум 'failed' считалось тогда от сниженного предписания (6), а не
        // от базовой линии, и день с низкой готовностью бил по базовой линии
        // сильнее (8.4), чем тот же провал на полном весе (9.2).
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [2, 4, 6, 8, 10]))
        let sessions = [
            session(0, [(10, 10, 9, .ok), (10, 10, 9, .ok)]),
            // readiness 0.75 → предписано 6, принято как есть: оверрайда нет.
            session(1, readiness: 0.75, [(6, 6, 4, .failed), (6, 6, 4, .failed)]),
        ]
        let state = Progression.rebuildStates(from: sessions, baseRange: hypertrophyRange, ladder: ladder)
        // Шаг вниз от базовой линии (10 → 8), демпфированный ×0.4: 10 + (8−10)×0.4.
        XCTAssertEqual(state.baselineKg ?? -1, 9.2, accuracy: 0.0001)
    }

    func test_control_genuineOverrideDownStillUsesUserWeightAsTarget() {
        // Контроль к предыдущему: при том же readiness пользователь берёт 4 —
        // ниже и предписания (6), и базовой линии (10). Это настоящий
        // оверрайд, и цель обязана считаться от её веса, а не от ступени
        // лестницы (§18 сценарий 11 не сломан).
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [2, 4, 6, 8, 10]))
        let sessions = [
            session(0, [(10, 10, 9, .ok), (10, 10, 9, .ok)]),
            session(1, readiness: 0.75, [(6, 4, 9, .hard)]),
        ]
        let state = Progression.rebuildStates(from: sessions, baseRange: hypertrophyRange, ladder: ladder)
        // Цель — её собственные 4, демпфированные: 10 + (4−10)×0.4 = 7.6.
        XCTAssertEqual(state.baselineKg ?? -1, 7.6, accuracy: 0.0001)
    }

    func test_sessionWithNoRecordedWeightAtAllIsSkipped() {
        // Расщепление сидирующей ветки убрало общий continue, и взвешенное
        // упражнение с незаписанным весом проваливалось в расчёты с `?? 0`:
        // jump = (next − 0) / 0 = inf, каскад молча возвращал extendReps и
        // наращивал rep_extension упражнению без базовой линии.
        //
        // Переписан после код-ревью 433afa0: прежняя версия давала первому
        // подходу вес 10 кг и утверждала, что сидировать «было не от чего» —
        // то есть закрепляла дефект сидирования как ожидаемое поведение.
        // Теперь пропуск проверяется на сессиях, где веса нет НИ В ОДНОМ
        // подходе, а случай «вес есть, но не в последнем подходе» покрыт
        // тестом test_seedingFindsWeightRegardlessOfPosition.
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [4, 6, 8]))
        let sessions = [
            session(0, [(8, nil, 12, .easy), (8, nil, 12, .easy)]),
            session(1, [(8, nil, 12, .easy)]),
        ]
        let state = Progression.rebuildStates(from: sessions, baseRange: hypertrophyRange, ladder: ladder)
        XCTAssertNil(state.baselineKg, "сидировать было не от чего")
        XCTAssertEqual(state.repExtension, 0, "расширение диапазона не выводится из бесконечности")
    }

    func test_control_seedingRecoversOnceWeightIsRecorded() {
        // Контроль: пропуск сессий без веса не должен ломать сидирование
        // навсегда — как только вес записан, базовая линия заводится.
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [4, 6, 8]))
        let sessions = [
            session(0, [(8, nil, 12, .easy)]),
            session(1, [(8, 8, 9, .ok)]),
        ]
        let state = Progression.rebuildStates(from: sessions, baseRange: hypertrophyRange, ladder: ladder)
        XCTAssertEqual(state.baselineKg ?? -1, 8, accuracy: 0.0001)
    }


    // MARK: - Регрессии код-ревью 433afa0, 2026-09-08

    /// Модель пользовательницы для самосогласованной симуляции. Два явных
    /// порога, а не один «предел»: ниже `okFrom` вес даётся легко и с запасом
    /// повторов, от `okFrom` до `failAbove` — «нормально» на верху диапазона,
    /// выше `failAbove` — провал.
    ///
    /// Различие существенно: §9.3 поднимает вес только на «легко», поэтому
    /// откалиброванным окажется `okFrom` — ПЕРВЫЙ вес, переставший быть
    /// лёгким, а не максимум, который она в принципе могла бы поднять. Именно
    /// это §9.8 и называет концом калибровки («два подхода подряд с
    /// «нормально»/«тяжело» при попадании в целевой диапазон повторов»).
    private func simulatedFeedback(weight: Double, okFrom: Double, failAbove: Double) -> (reps: Int, feedback: Feedback) {
        if weight > failAbove + 0.005 { return (4, .failed) }
        if weight >= okFrom - 0.005 { return (12, .ok) }
        return (20, .easy)
    }

    func test_calibrationConvergesWithinThreeWorkouts() {
        // ЭТОТ ТЕСТ — ПОСТОЯННЫЙ МЕТОД ПРОВЕРКИ КАЛИБРОВКИ, а не разовая
        // регрессия. Он самосогласован: предписание каждой сессии выводится из
        // ExerciseState после предыдущей (§9.6), подъём внутри сессии даёт
        // настоящий Progression.nextSet (§9.3), а фидбэк — модель ёмкости выше.
        // Ничего не задаётся руками.
        //
        // Именно так был найден дефект, который этот тест закрывает: прежние
        // проверки подставляли предписания вручную, поэтому выглядели
        // согласованными, но скрывали, что состояние ни на что не влияет.
        // Калибровка «сходилась» на бумаге и не сходилась в жизни: каждая
        // сессия открывала с той же базовой линии и доходила до того же веса.
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [4, 6, 8, 10, 12]))
        let okFrom = 10.0, failAbove = 14.0
        var log: [ExerciseSession] = []
        var state = ExerciseState()
        var baselineByWorkout: [Double?] = []

        for workout in 0..<4 {
            // Открывающий вес — из состояния (холодный старт 4 кг для первой).
            var weight = state.baselineKg.map { ladder.roundToAchievable($0, direction: .down) } ?? 4.0
            var sets: [SetResult] = []
            var prior: Feedback? = nil

            for _ in 0..<3 {
                let (reps, feedback) = simulatedFeedback(weight: weight, okFrom: okFrom, failAbove: failAbove)
                sets.append(SetResult(prescribedKg: weight, actualKg: weight, actualReps: reps, feedback: feedback))
                let outcome = Progression.nextSet(
                    priorFeedback: prior, current: weight, feedback: feedback, actualReps: reps,
                    range: hypertrophyRange, isCalibration: true, ladder: ladder
                )
                guard case .nextWeight(let next) = outcome else { break }
                weight = next
                prior = feedback
            }

            log.append(ExerciseSession(performedAt: day(workout * 2), readiness: 1.0, isCalibration: true, sets: sets))
            state = Progression.rebuildStates(from: log, baseRange: hypertrophyRange, ladder: ladder)
            baselineByWorkout.append(state.baselineKg)
        }

        // Первая тренировка не дотягивает до откалиброванного веса: в сессии
        // три подхода, то есть два повышения, и с холодного старта 4 кг она
        // доходит только до 8.
        XCTAssertEqual(baselineByWorkout[0] ?? -1, 8, accuracy: 0.0001, "путь: \(baselineByWorkout)")

        // §9.8 обещает: «Намеренное занижение: безопасно, и алгоритм быстро
        // поднимет». «Быстро» — это 2–3 калибровочные тренировки. Ключевое,
        // чего не было до этой правки: рост МЕЖДУ тренировками. Раньше
        // baseline навсегда застревал на значении первой сессии.
        XCTAssertEqual(
            baselineByWorkout[2] ?? -1, okFrom, accuracy: 0.0001,
            "к третьей калибровочной базовая линия обязана дойти до откалиброванного веса; путь: \(baselineByWorkout)"
        )
        XCTAssertEqual(
            baselineByWorkout[3] ?? -1, okFrom, accuracy: 0.0001,
            "и дальше не уходить; путь: \(baselineByWorkout)"
        )
        XCTAssertGreaterThan(
            baselineByWorkout[2] ?? -1, baselineByWorkout[0] ?? .infinity,
            "базовая линия обязана расти МЕЖДУ калибровочными тренировками, а не только внутри первой"
        )
    }

    func test_calibrationDoesNotAdoptFailedWeight() {
        // «Перелёт» неизбежен по устройству §9.3: вес растёт, пока не станет
        // тяжело, поэтому калибровочная сессия обычно кончается провалом.
        // Базовой линией обязан стать самый тяжёлый ВЫПОЛНЕННЫЙ вес, а не тот,
        // на котором она провалилась.
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [4, 6, 8, 10, 12]))
        let sessions = [
            session(0, isCalibration: true, [(4, 4, 20, .easy), (6, 6, 20, .easy)]),   // сидирует 6
            session(2, isCalibration: true, [(6, 8, 20, .easy), (8, 10, 15, .easy), (10, 12, 4, .failed)]),
        ]
        let state = Progression.rebuildStates(from: sessions, baseRange: hypertrophyRange, ladder: ladder)
        XCTAssertEqual(state.baselineKg ?? -1, 10, accuracy: 0.0001, "12 кг провалены — базовой линией не становятся")
    }

    func test_calibrationLowersBaselineWhenSessionEstablishesLess() {
        // Калибровка двигает базовую линию в обе стороны: если прошлая сессия
        // перелетела, следующая её корректирует вниз.
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [4, 6, 8, 10, 12]))
        let sessions = [
            session(0, isCalibration: true, [(10, 10, 12, .ok), (12, 12, 12, .ok)]),   // сидирует 12
            session(2, isCalibration: true, [(12, 12, 4, .failed), (10, 8, 12, .ok)]),
        ]
        let state = Progression.rebuildStates(from: sessions, baseRange: hypertrophyRange, ladder: ladder)
        XCTAssertEqual(state.baselineKg ?? -1, 8, accuracy: 0.0001)
    }

    func test_seedingFindsWeightRegardlessOfPosition() {
        // Сидирование читало только sets.last, поэтому пустой закрывающий
        // подход терял всю сессию. Позиция пропуска не должна ни на что влиять.
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [4, 6, 8]))
        let variants: [(String, [(Double?, Double?, Int, Feedback)])] = [
            ("пусто / 8 / 8", [(8, nil, 10, .ok), (8, 8, 10, .ok), (8, 8, 10, .ok)]),
            ("8 / пусто / 8", [(8, 8, 10, .ok), (8, nil, 10, .ok), (8, 8, 10, .ok)]),
            ("8 / 8 / пусто", [(8, 8, 10, .ok), (8, 8, 10, .ok), (8, nil, 10, .ok)]),
        ]
        for (name, sets) in variants {
            let state = Progression.rebuildStates(from: [session(0, sets)], baseRange: hypertrophyRange, ladder: ladder)
            XCTAssertEqual(state.baselineKg ?? -1, 8, accuracy: 0.0001, "вариант «\(name)»")
        }

        let allEmpty = Progression.rebuildStates(
            from: [session(0, [(8, nil, 10, .ok), (8, nil, 10, .ok)])],
            baseRange: hypertrophyRange, ladder: ladder
        )
        XCTAssertNil(allEmpty.baselineKg, "весов нет ни в одном подходе — сидировать нечем")
    }

    func test_seedingIgnoresFailedAndUnderRepMinSets() {
        // Самый тяжёлый подход провален, а самый лёгкий недобран по повторам —
        // базовой линией становится единственный выполненный в диапазоне.
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [4, 6, 8, 10]))
        let state = Progression.rebuildStates(
            from: [session(0, [(4, 4, 5, .ok), (6, 6, 10, .ok), (10, 10, 3, .failed)])],
            baseRange: hypertrophyRange, ladder: ladder
        )
        XCTAssertEqual(state.baselineKg ?? -1, 6, accuracy: 0.0001)
    }

    // MARK: - Регрессии многосессионного прогона, 2026-09-08

    /// Прогон серии сессий с ОБРАТНОЙ СВЯЗЬЮ: предписание каждой сессии
    /// выводится из состояния, оставленного предыдущей, внутрисессионный
    /// подъём даёт настоящий `nextSet`, фидбэк — модель ниже. Ничего не
    /// задаётся руками.
    ///
    /// Модель пользовательницы: два порога. Ниже `okFrom` вес даётся легко и с
    /// запасом повторов, от `okFrom` до `failAbove` — «нормально» на верху
    /// диапазона, выше — провал. Различие существенно: §9.3 поднимает вес
    /// только на «легко», поэтому откалиброванным окажется первый вес,
    /// переставший быть лёгким, а не максимум, который она могла бы поднять.
    private func simulate(
        ladder: WeightLadder, okFrom: Double, failAbove: Double,
        setsPerSession: Int, workouts: Int, coldStart: Double, calibrationWorkouts: Int
    ) -> (path: [Double?], states: [ExerciseState]) {
        var log: [ExerciseSession] = []
        var state = ExerciseState()
        var path: [Double?] = []
        var states: [ExerciseState] = []

        for n in 0..<workouts {
            var weight = state.baselineKg.map { ladder.roundToAchievable($0, direction: .down) } ?? coldStart
            var sets: [SetResult] = []
            var prior: Feedback? = nil
            let isCalibration = n < calibrationWorkouts

            for _ in 0..<setsPerSession {
                let (reps, feedback): (Int, Feedback) =
                    weight > failAbove + 0.005 ? (4, .failed)
                  : weight >= okFrom - 0.005  ? (12, .ok)
                  : (20, .easy)
                sets.append(SetResult(prescribedKg: weight, actualKg: weight, actualReps: reps, feedback: feedback))
                guard case .nextWeight(let next) = Progression.nextSet(
                    priorFeedback: prior, current: weight, feedback: feedback, actualReps: reps,
                    range: hypertrophyRange, isCalibration: isCalibration, ladder: ladder
                ) else { break }
                weight = next
                prior = feedback
            }

            log.append(ExerciseSession(performedAt: day(n * 2), readiness: 1.0,
                                       isCalibration: isCalibration, sets: sets))
            state = Progression.rebuildStates(from: log, baseRange: hypertrophyRange, ladder: ladder)
            path.append(state.baselineKg)
            states.append(state)
        }
        return (path, states)
    }

    func test_flawlessPerformanceNeverSpiralsDown() {
        // Женщина, откалиброванная на 10 кг и каждую сессию отрабатывающая
        // цель ровно («нормально», верх диапазона), теряла вес: базовая линия
        // шла 10 → 9 → 8.1 → 7.29 → 6.5 → 5.83 за 30 сессий, потому что
        // .extendReps сбрасывал stallCount и deload повторялся бесконечно.
        //
        // Утверждение НЕ «baseline не падает»: буквально это недостижимо без
        // правки самой §9.4 — три сессии без повышения дают deload по
        // спецификации, и один deload здесь корректен. Проверяется то, что
        // отличает норму от спирали.
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [4, 6, 8, 10, 12]))
        let run = simulate(ladder: ladder, okFrom: 10, failAbove: 100,
                           setsPerSession: 3, workouts: 30, coldStart: 4, calibrationWorkouts: 3)
        let values = run.path.compactMap { $0 }

        var runningMax = 0.0
        var worstRatio = 1.0
        for v in values {
            runningMax = max(runningMax, v)
            worstRatio = min(worstRatio, v / runningMax)
        }
        XCTAssertGreaterThanOrEqual(worstRatio, 0.9 - 0.0001,
            "просадка глубже одного deload — это спираль; путь: \(values)")
        XCTAssertGreaterThanOrEqual(run.states.last!.stallCount, 2,
            "замена упражнения (§9.4) обязана стать достижимой")
        let tail = values.suffix(10)
        XCTAssertEqual(tail.min()!, tail.max()!, accuracy: 0.0001,
            "последние 10 сессий без дополнительных снижений")
    }

    func test_ladderExhaustedDoesNotAccumulateStall() {
        // На максимальной гантели рост идёт повторами и подходами — это каскад
        // §9.5, а не застой. deload на 10% здесь был бы шагом назад за
        // следование спецификации.
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [8]))
        let run = simulate(ladder: ladder, okFrom: 100, failAbove: 200,
                           setsPerSession: 3, workouts: 15, coldStart: 8, calibrationWorkouts: 2)
        XCTAssertEqual(run.states.last!.stallCount, 0)
        XCTAssertEqual(run.path.last.flatMap { $0 } ?? -1, 8, accuracy: 0.0001,
            "базовая линия не проседает; путь: \(run.path.compactMap { $0 })")
    }

    func test_calibrationConvergesOnSingleSetExercise() {
        // Одноподходное упражнение: внутрисессионного подъёма нет ни одного, а
        // межсессионного у калибровки не было вовсе — базовая линия навсегда
        // оставалась на холодном старте (проверено 12 сессий).
        for (name, rungs) in [("разрежённая", [4.0, 6, 8, 10, 12]),
                              ("плотная", [4.0, 5, 6, 7, 8, 9, 10, 11, 12])] {
            let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: rungs))
            let run = simulate(ladder: ladder, okFrom: 10, failAbove: 100,
                               setsPerSession: 1, workouts: 15, coldStart: 4, calibrationWorkouts: 15)
            let values = run.path.compactMap { $0 }
            XCTAssertGreaterThanOrEqual(values.last ?? -1, 10 - 0.0001,
                "«\(name)»: базовая линия обязана дойти до полосы «нормально»; путь: \(values)")
            let tail = values.suffix(3)
            XCTAssertEqual(tail.min()!, tail.max()!, accuracy: 0.0001,
                "«\(name)»: после сходимости не ползёт; путь: \(values)")
        }
    }

    func test_calibrationClosesGapOnSparseLadder() {
        // Холодный старт ×0.6 и разрыв больше 10%: §9.5 такой шаг не
        // пропускает, поэтому закрыть его обязана калибровка — иначе женщина
        // навсегда остаётся ниже того, что сама показала.
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [4, 6, 8, 10, 12]))
        let run = simulate(ladder: ladder, okFrom: 10, failAbove: 100,
                           setsPerSession: 2, workouts: 15, coldStart: 4, calibrationWorkouts: 2)
        let values = run.path.compactMap { $0 }
        XCTAssertGreaterThanOrEqual(values.max() ?? -1, 10 - 0.0001,
            "разрыв обязан закрыться; путь: \(values)")
    }

    func test_calibrationTerminatesWhenLadderExhausted() {
        // Условие 2: тяжелее ничего нет, искать больше нечего. Без него
        // упражнение на максимальной гантели с 20 лёгкими повторами застревало
        // бы в калибровке навсегда и не попадало в каскад §9.5.
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [8]))
        let run = simulate(ladder: ladder, okFrom: 100, failAbove: 200,
                           setsPerSession: 3, workouts: 10, coldStart: 8, calibrationWorkouts: 10)
        XCTAssertFalse(run.states.last!.isInCalibration)
        XCTAssertGreaterThan(run.states.last!.repExtension, 0, "упражнение ушло в каскад §9.5")
    }

    func test_calibrationTerminatesAtSessionCap() {
        // Условие 3: данные, при которых условие §9.8 не выполняется никогда
        // (всё «легко», повторы выше диапазона) — режим обязан кончиться сам.
        let rungs: [Double] = [4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24]
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: rungs))
        let run = simulate(ladder: ladder, okFrom: 100, failAbove: 200,
                           setsPerSession: 3, workouts: 10, coldStart: 4, calibrationWorkouts: 10)
        XCTAssertFalse(run.states[5].isInCalibration, "режим кончается на шестой сессии")
    }

    func test_detrainingCutSurvivesItsOwnSession() {
        // Перерыв >45 дней режет ×0.75 и возвращает в калибровку. Та же сессия
        // сразу обрабатывается как калибровочная, и если пользователь взяла
        // старый вес сама, калибровка его усваивала — срез отменялся в тот же
        // момент, и §9.7 переставал быть гарантией.
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [6, 8, 10]))
        let sessions = [
            session(0, isCalibration: true, [(10, 10, 9, .ok), (10, 10, 9, .ok)]),
            session(60, [(10, 10, 9, .ok)]),
        ]
        let state = Progression.rebuildStates(from: sessions, baseRange: hypertrophyRange, ladder: ladder)
        XCTAssertEqual(state.baselineKg ?? -1, 7.5, accuracy: 0.0001)
        XCTAssertTrue(state.isInCalibration)
    }
}
