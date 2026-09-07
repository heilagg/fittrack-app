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
        let heldSet = SetResult(prescribedKg: nil, actualKg: nil, actualReps: 9, feedback: .ok)  // в диапазоне, не у верха, не под rep_min

        var sessions = [
            ExerciseSession(performedAt: day(0), readiness: 1.0, isCalibration: false,
                             sets: [SetResult(prescribedKg: 10, actualKg: 10, actualReps: 9, feedback: .ok)])
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
                             sets: [SetResult(prescribedKg: 8, actualKg: 8, actualReps: 9, feedback: .ok)]),
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
                             sets: [SetResult(prescribedKg: 10, actualKg: 10, actualReps: 9, feedback: .ok)]),
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
                             sets: [SetResult(prescribedKg: 10, actualKg: 10, actualReps: 9, feedback: .ok)]),
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
            session(0, [(10, 10, 9, .ok)]),
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
            session(0, [(10, 10, 9, .ok)]),
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
            session(0, [(10, 10, 9, .ok)]),
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
                    session(0, [(10, 10, 9, .ok)]),
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
                session(0, [(10, 10, 9, .ok)]),
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
            session(0, [(20, 20, 9, .ok)]),
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
            session(0, [(10, 10, 9, .ok)]),
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
            session(0, [(10, 10, 9, .ok)]),
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
            session(0, [(10, 10, 9, .ok)]),
            session(1, [(10, 10, 5, .hard)]),
            session(2, [(10, 10, 9, .ok)]),
            session(3, [(10, 10, 5, .hard)]),
        ]
        let state = Progression.rebuildStates(from: sessions, baseRange: hypertrophyRange, ladder: ladder)
        XCTAssertEqual(state.baselineKg ?? -1, 9.0, accuracy: 0.0001)
        XCTAssertEqual(state.stallCount, 1)
    }

    func test_finding4_seedingSessionCountsTowardUnderRepMinRun() {
        // Сидирующая сессия тоже уходила по continue, теряя свой недобор:
        // у пользователя, чьи первые две сессии обе провалились по повторам,
        // понижение не срабатывало никогда.
        let ladder = WeightLadder.build(loadType: .dumbbell, profile: EquipmentProfile(dumbbellsKg: [4, 6, 8, 10]))
        let sessions = [
            session(0, [(10, 10, 5, .hard)]),
            session(1, [(10, 10, 5, .hard)]),
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
}
