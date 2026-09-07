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
        let heldSet = SetResult(actualKg: nil, actualReps: 9, feedback: .ok)  // в диапазоне, не у верха, не под rep_min

        var sessions = [
            ExerciseSession(performedAt: day(0), readiness: 1.0, isCalibration: false,
                             sets: [SetResult(actualKg: 10, actualReps: 9, feedback: .ok)])
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
                             sets: [SetResult(actualKg: 8, actualReps: 9, feedback: .ok)]),
            // Пользователь сам взял 12 кг (не 10, следующую по лестнице
            // ступень от 8) и отработал верх диапазона нормально.
            ExerciseSession(performedAt: day(1), readiness: 1.0, isCalibration: false,
                             sets: [SetResult(actualKg: 12, actualReps: 12, feedback: .ok)]),
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
                             sets: [SetResult(actualKg: 10, actualReps: 9, feedback: .ok)]),
            // Пользователь сам снизил вес до 6 (на две ступени от 10, минуя
            // 8) и всё равно было тяжело.
            ExerciseSession(performedAt: day(1), readiness: 1.0, isCalibration: false,
                             sets: [SetResult(actualKg: 6, actualReps: 9, feedback: .hard)]),
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
                             sets: [SetResult(actualKg: 10, actualReps: 9, feedback: .ok)]),
            ExerciseSession(performedAt: day(1), readiness: 0.8, isCalibration: false,
                             sets: [SetResult(actualKg: 6, actualReps: 9, feedback: .hard)]),
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
                SetResult(actualKg: 8, actualReps: 9, feedback: .ok),
                SetResult(actualKg: 8, actualReps: 9, feedback: .ok),
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
                    SetResult(actualKg: 10, actualReps: 9, feedback: .ok),
                    SetResult(actualKg: 10, actualReps: 9, feedback: .ok),
                ]
            ),
            // 60 дней спустя — перерыв > 45 дней.
            ExerciseSession(performedAt: day(60), readiness: 1.0, isCalibration: false,
                             sets: [SetResult(actualKg: nil, actualReps: 9, feedback: .ok)]),
        ]

        let state = Progression.rebuildStates(from: sessions, baseRange: hypertrophyRange, ladder: ladder)

        XCTAssertEqual(state.baselineKg ?? -1, 7.5, accuracy: 0.0001)
        XCTAssertTrue(state.isInCalibration)
    }
}
