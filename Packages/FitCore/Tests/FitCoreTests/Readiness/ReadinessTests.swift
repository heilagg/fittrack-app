//  Readiness — контракт SPEC §10, тесты для сценариев §18, закрытых этим
//  модулем (см. doc-комментарий Cycle.swift, «Границы теста»): 23,
//  23a (часть — «на готовность действует»), 23b (часть — сама формула
//  замены), 24a, 25, 25a, 25b, 25c. 24b/24c — чистая функция фазы ×
//  уверенность без чек-ина/оверрайда, проверены в CycleTests, не здесь.
//
//  Остальные тесты — контракт композиции (targetRIR/volumeFactor/
//  weightReadiness/±1 на сессию), помечены `// MARK:`, а не `test_scenarioN`.
//
//  XCTest, а не Swift Testing — окружение только с Command Line Tools
//  (`swift test` падает на `no such module`), логика прогнана вручную через
//  временный executable, см. implement-feature §5.

import XCTest
@testable import FitCore

final class ReadinessTests: XCTestCase {

    // MARK: - Построение CycleState напрямую

    // Readiness не вызывает функции Cycle — он только читает готовый
    // CycleState (см. doc-комментарий Readiness.swift). Состояния собраны
    // вручную, а не через Cycle.state(...), чтобы точно контролировать
    // cycleConfidence/periodization в каждом тесте, не гоняясь за историей
    // событий, которая дала бы то же число.

    private func phaseState(
        phase: Phase,
        cycleConfidence: Double,
        periodization: PhasePeriodization? = nil
    ) -> CycleState {
        CycleState(
            phaseMode: .phases,
            noPhaseReason: nil,
            hasAnchor: true,
            phase: phase,
            cycleConfidence: cycleConfidence,
            periodization: periodization ?? Cycle.periodization(phase: phase, cycleConfidence: cycleConfidence),
            effectivePhaseAdjustment: Cycle.defaultReadinessAdjustment(for: phase)
        )
    }

    private func noAnchorState() -> CycleState {
        CycleState(
            phaseMode: .phases, noPhaseReason: nil, hasAnchor: false,
            phase: nil, cycleConfidence: nil, periodization: nil, effectivePhaseAdjustment: nil
        )
    }

    private func noPhasesState() -> CycleState {
        CycleState(
            phaseMode: .noPhases, noPhaseReason: .userChoice, hasAnchor: false,
            phase: nil, cycleConfidence: nil, periodization: nil, effectivePhaseAdjustment: nil
        )
    }

    // MARK: - Сценарий 23: оверрайд заменяет фазовую поправку, не складывается

    func test_scenario23_pushInMenstrualPhase_replacesPhaseTermEntirely() {
        // Менструальная: effectivePhaseAdjustment = −0.10, confidence = 1.0 →
        // без оверрайда phaseTerm был бы −0.10. push обязан ЗАМЕНИТЬ это на
        // +0.08, а не сложить (+0.08 + −0.10 = −0.02 — неверно).
        let state = phaseState(phase: .menstrual, cycleConfidence: 1.0)

        let readiness = Readiness.value(cycleState: state, override: .push, checkin: DailyCheckin())

        XCTAssertEqual(readiness, 1.08, accuracy: 0.0001,
            "push должен полностью заменить фазовую поправку −0.10 на +0.08")
    }

    func test_scenario23_easeInEarlyLutealPhase_replacesPositivePhaseTerm() {
        // Ранняя лютеиновая: effectivePhaseAdjustment = 0.00 — вырожденный
        // случай замены (0 → −0.10), проверяет, что замена срабатывает и
        // когда фазовая поправка сама по себе нулевая, а не только ненулевая.
        let state = phaseState(phase: .earlyLuteal, cycleConfidence: 1.0)

        let readiness = Readiness.value(cycleState: state, override: .ease, checkin: DailyCheckin())

        XCTAssertEqual(readiness, 0.90, accuracy: 0.0001)
    }

    // MARK: - Сценарий 23a: оверрайд действует на готовность без фазы

    func test_scenario23a_overrideActsInNoPhasesMode() {
        let readiness = Readiness.value(cycleState: noPhasesState(), override: .push, checkin: DailyCheckin())
        XCTAssertEqual(readiness, 1.08, accuracy: 0.0001,
            "в режиме без фаз оверрайд всё равно двигает готовность")
    }

    func test_scenario23a_overrideActsWhenNoAnchorAtAll() {
        let readiness = Readiness.value(cycleState: noAnchorState(), override: .ease, checkin: DailyCheckin())
        XCTAssertEqual(readiness, 0.90, accuracy: 0.0001,
            "без опорной даты оверрайд всё равно двигает готовность")
    }

    // MARK: - Сценарий 23b: формула замены — по итоговому значению за день

    func test_scenario23b_finalOverrideValueIsAllThatMatters() {
        // Readiness не хранит историю нажатий за день — «push, затем ease»
        // уже свёрнуто источником (daily_checkins.override — одна колонка) в
        // одно итоговое значение до вызова этой функции. Тест фиксирует, что
        // формула зависит только от него: результат с override = .ease не
        // отличается от вызова, где .push никогда не нажимался.
        let state = phaseState(phase: .menstrual, cycleConfidence: 1.0)
        let afterPushThenEase = Readiness.value(cycleState: state, override: .ease, checkin: DailyCheckin())
        let easeOnly = Readiness.value(cycleState: state, override: .ease, checkin: DailyCheckin())

        XCTAssertEqual(afterPushThenEase, easeOnly, accuracy: 0.0001)
        XCTAssertEqual(afterPushThenEase, 0.90, accuracy: 0.0001)
    }

    func test_scenario23c_restOverride_numericallyEqualsEase() {
        // §10: «Если пользователь всё же начинает тренировку в день rest —
        // оверрайд численно считается за ease». (Обучение профиля по rest не
        // идёт — это Cycle, сценарий 23c там же.)
        let state = phaseState(phase: .earlyLuteal, cycleConfidence: 1.0)
        let rest = Readiness.value(cycleState: state, override: .rest, checkin: DailyCheckin())
        let ease = Readiness.value(cycleState: state, override: .ease, checkin: DailyCheckin())
        XCTAssertEqual(rest, ease, accuracy: 0.0001)
    }

    // MARK: - Сценарий 24a: checkinScale — непрерывная стыковка с §11.5

    func test_scenario24a_checkinScaleAtFullConfidenceIsOne() {
        let state = phaseState(phase: .follicular, cycleConfidence: 1.0)
        XCTAssertEqual(Readiness.checkinScale(cycleState: state), 1.0, accuracy: 0.0001)
    }

    func test_scenario24a_checkinScaleAtZeroConfidenceIsSixteen() {
        let state = phaseState(phase: .follicular, cycleConfidence: 0.0)
        XCTAssertEqual(Readiness.checkinScale(cycleState: state), 1.6, accuracy: 0.0001)
    }

    func test_scenario24a_checkinScaleInNoPhasesModeIsSixteen() {
        XCTAssertEqual(Readiness.checkinScale(cycleState: noPhasesState()), 1.6, accuracy: 0.0001,
            "режим без фаз — тот же предельный случай, что confidence → 0, не отдельная ветка")
    }

    func test_scenario24a_checkinScaleAtHalfConfidence() {
        let state = phaseState(phase: .follicular, cycleConfidence: 0.5)
        XCTAssertEqual(Readiness.checkinScale(cycleState: state), 1.3, accuracy: 0.0001)
    }

    // MARK: - Сценарий 25: push при переутомлении мышцы не снимает защиту

    func test_scenario25_pushOverride_doesNotLiftFatigueProtection() {
        let state = phaseState(phase: .earlyLuteal, cycleConfidence: 1.0) // rirShift = 0, не мешает
        let readiness = Readiness.value(cycleState: state, override: .push, checkin: DailyCheckin())
        XCTAssertEqual(readiness, 1.08, accuracy: 0.0001)

        let notRecovered = RecoveryAdjustment(targetRIRDelta: 1, volumeMultiplier: 0.7)

        // RIR: надбавка утомления (+1) добавляется поверх потолка фазы+готовности,
        // а не заменяется push'ем.
        let rir = Readiness.targetRIR(
            baseRIR: 2, readiness: readiness, cycleState: state, fatigueRIRBump: notRecovered.targetRIRDelta
        )
        XCTAssertEqual(rir, 3, "push не снимает надбавку RIR от утомления")

        // Объём: min(plannedFactor, fatigueFactor) — push не поднимает plannedFactor
        // (оверрайд не входит в plannedVolumeFactor вовсе), а срез утомления остаётся.
        let planned = Readiness.plannedVolumeFactor(cycleState: state, isDeloadWeek: false)
        let volume = Readiness.volumeFactor(plannedFactor: planned, fatigueFactor: notRecovered.volumeMultiplier)
        XCTAssertEqual(volume, 0.7, accuracy: 0.0001, "push не снимает срез утомления")

        // Вес: надбавка выше 1.0 срезана до 1.0, несмотря на readiness = 1.08.
        let weight = Readiness.weightReadiness(readiness: readiness, contributingMuscleAdjustments: [notRecovered])
        XCTAssertEqual(weight, 1.0, accuracy: 0.0001, "push не снимает срез веса на невосстановленной мышце")

        // +1 подход на сессию (readiness 1.08 > 1.05) не ложится на упражнение
        // с утомлённой мышцей.
        let delta = Readiness.sessionSetDelta(readiness: readiness)
        XCTAssertEqual(delta, 1)
        let target = Readiness.exerciseForSessionSetIncrease(hasFatiguedMuscle: [true])
        XCTAssertNil(target, "единственное упражнение сессии утомлено — +1 не даётся вовсе")
    }

    /// Усиление сценария 25: тест выше проверяет только зафиксированные числа
    /// на одном примере (push). Здесь — то же fatigue-состояние под push,
    /// ease и «не нажимали» одновременно: срез от утомления обязан остаться
    /// НЕИЗМЕННЫМ, независимо от того, куда override и чек-ин двигают
    /// readiness. Так проверяется сам порядок композиции (готовность первой,
    /// утомление — на её результат, а не наоборот), а не совпадение чисел
    /// на одном частном случае.
    func test_scenario25_fatigueProtectionInvariantAcrossOverride() {
        let state = phaseState(phase: .earlyLuteal, cycleConfidence: 1.0) // rirShift = 0, не мешает интерпретации
        let notRecovered = RecoveryAdjustment(targetRIRDelta: 1, volumeMultiplier: 0.7)

        let readinessByOverride: [Override?: Double] = [
            .push: Readiness.value(cycleState: state, override: .push, checkin: DailyCheckin()),
            .ease: Readiness.value(cycleState: state, override: .ease, checkin: DailyCheckin()),
            nil: Readiness.value(cycleState: state, override: nil, checkin: DailyCheckin())
        ]

        for (override, readiness) in readinessByOverride {
            let label = override.map { "\($0)" } ?? "nil"

            // RIR: разница между «с утомлением» и «без утомления» на ОДНОМ и
            // том же readiness обязана равняться ровно надбавке утомления —
            // она не растворяется и не усиливается фазой/готовностью,
            // независимо от того, что дало это readiness.
            let rirWithFatigue = Readiness.targetRIR(
                baseRIR: 2, readiness: readiness, cycleState: state, fatigueRIRBump: notRecovered.targetRIRDelta)
            let rirWithoutFatigue = Readiness.targetRIR(
                baseRIR: 2, readiness: readiness, cycleState: state, fatigueRIRBump: 0)
            XCTAssertEqual(rirWithFatigue - rirWithoutFatigue, notRecovered.targetRIRDelta,
                "override = \(label): надбавка утомления к RIR не зависит от readiness")

            // Объём: план не читает override вовсе (не параметр
            // plannedVolumeFactor) — срез утомления одинаков для любого override.
            let planned = Readiness.plannedVolumeFactor(cycleState: state, isDeloadWeek: false)
            let volume = Readiness.volumeFactor(plannedFactor: planned, fatigueFactor: notRecovered.volumeMultiplier)
            XCTAssertEqual(volume, 0.7, accuracy: 0.0001,
                "override = \(label): срез объёма от утомления одинаков независимо от override")

            // Вес: срез сверху 1.0 держится при ЛЮБОМ readiness, включая
            // readiness < 1.0 (ease/nil), где срезать по факту нечего —
            // формула не «включается только при push», а действует всегда.
            let weight = Readiness.weightReadiness(readiness: readiness, contributingMuscleAdjustments: [notRecovered])
            XCTAssertLessThanOrEqual(weight, 1.0, "override = \(label): вес на невосстановленной мышце не выше 1.0")
            XCTAssertEqual(weight, min(readiness, 1.0), accuracy: 0.0001,
                "override = \(label): срез — это ровно min(readiness, 1.0), не отдельная ветка под push")

            // +1/−1 на сессию: какое бы readiness ни дал override, утомлённое
            // единственное упражнение сессии никогда не получает +1.
            XCTAssertNil(Readiness.exerciseForSessionSetIncrease(hasFatiguedMuscle: [true]),
                "override = \(label): +1 не ложится на утомлённое упражнение ни при каком readiness")
        }
    }

    // MARK: - Сценарий 25a: RIR — сумма с потолком +1, утомление сверх

    func test_scenario25a_lateLutealPlusLowReadiness_cappedAtPlusOne() {
        // Поздняя лютеиновая (+1) + readiness < 0.85 (+1) → сумма 2, потолок 1.
        let state = phaseState(phase: .lateLuteal, cycleConfidence: 1.0)
        let rir = Readiness.targetRIR(baseRIR: 2, readiness: 0.80, cycleState: state, fatigueRIRBump: 0)
        XCTAssertEqual(rir, 3, "base 2 + потолок 1 = 3, не 4")
    }

    func test_scenario25a_follicularNegativePhase_ordinaryDay_notErasedByMax() {
        // Фолликулярная (−1) + обычная готовность (0) → сумма −1, а не 0.
        // (Наивный максимум стёр бы отрицательный фазовый вклад.)
        let state = phaseState(phase: .follicular, cycleConfidence: 1.0)
        let rir = Readiness.targetRIR(baseRIR: 2, readiness: 1.0, cycleState: state, fatigueRIRBump: 0)
        XCTAssertEqual(rir, 1, "base 2 − 1 = 1")
    }

    func test_scenario25a_follicularNegativePhase_lowReadiness_sumIsZero() {
        // Фолликулярная (−1) + readiness < 0.85 (+1) → сумма 0, фаза учтена
        // (не потолок +1, который стёр бы фазовое −1 вовсе — это и есть
        // разница между «суммой с потолком» и «максимумом»).
        let state = phaseState(phase: .follicular, cycleConfidence: 1.0)
        let rir = Readiness.targetRIR(baseRIR: 2, readiness: 0.80, cycleState: state, fatigueRIRBump: 0)
        XCTAssertEqual(rir, 2, "base 2 + 0 = 2")
    }

    func test_scenario25a_fatigueBumpAddsOnTopOfCeiling_notRecoveredMuscle() {
        // Та же связка (поздняя лютеиновая + низкая готовность → потолок +1),
        // но с надбавкой утомления невосстановленной мышцы — она добавляется
        // СВЕРХ потолка, не участвует в min(…, +1).
        let state = phaseState(phase: .lateLuteal, cycleConfidence: 1.0)
        let rir = Readiness.targetRIR(baseRIR: 2, readiness: 0.80, cycleState: state, fatigueRIRBump: 1)
        XCTAssertEqual(rir, 4, "потолок 1 + надбавка утомления 1 = 2, база 2 + 2 = 4")
    }

    func test_scenario25a_invariant_fatigueRIRNeverBelowBase() {
        // Инвариант §10: при fatigue > 1.8 итоговый RIR не ниже базового —
        // проверка при самом отрицательном фазовом вкладе (−1) и нейтральной
        // готовности: потолок min(−1 + 0, +1) = −1, плюс надбавка утомления
        // +1 → сумма 0, итог не ниже базы.
        let state = phaseState(phase: .follicular, cycleConfidence: 1.0)
        let rir = Readiness.targetRIR(baseRIR: 2, readiness: 1.0, cycleState: state, fatigueRIRBump: 1)
        XCTAssertGreaterThanOrEqual(rir, 2)
    }

    // MARK: - Сценарий 25b: композиция объёма, восемь случаев + режим без фаз

    func test_scenario25b_volumeCompositionEightCases() {
        let earlyLuteal = phaseState(phase: .earlyLuteal, cycleConfidence: 1.0) // volumeMultiplier = 1.15
        let menstrual = phaseState(phase: .menstrual, cycleConfidence: 1.0)     // volumeMultiplier = 0.75

        func planned(_ state: CycleState) -> Double {
            Readiness.plannedVolumeFactor(cycleState: state, isDeloadWeek: false)
        }

        // свежая + ранняя лютеиновая → 1.15
        XCTAssertEqual(
            Readiness.volumeFactor(plannedFactor: planned(earlyLuteal), fatigueFactor: 1.0),
            1.15, accuracy: 0.0001)

        // свежая + менструальная → 0.75
        XCTAssertEqual(
            Readiness.volumeFactor(plannedFactor: planned(menstrual), fatigueFactor: 1.0),
            0.75, accuracy: 0.0001)

        // утомлённая + менструальная → 0.70 (не 0.75 × 0.70 = 0.525)
        XCTAssertEqual(
            Readiness.volumeFactor(plannedFactor: planned(menstrual), fatigueFactor: 0.70),
            0.70, accuracy: 0.0001)

        // утомлённая + ранняя лютеиновая → 0.70 (min стирает фазовую надбавку)
        XCTAssertEqual(
            Readiness.volumeFactor(plannedFactor: planned(earlyLuteal), fatigueFactor: 0.70),
            0.70, accuracy: 0.0001)

        // частично утомлённая (0.9) + менструальная → 0.75 (сильнейший срез — плановый)
        XCTAssertEqual(
            Readiness.volumeFactor(plannedFactor: planned(menstrual), fatigueFactor: 0.9),
            0.75, accuracy: 0.0001)

        // разгрузочная неделя (без фаз) + свежая мышца → 0.85
        let deload = Readiness.plannedVolumeFactor(cycleState: noPhasesState(), isDeloadWeek: true)
        XCTAssertEqual(Readiness.volumeFactor(plannedFactor: deload, fatigueFactor: 1.0), 0.85, accuracy: 0.0001)

        // разгрузочная неделя + сильно утомлённая → 0.70, не 0.85 × 0.70 = 0.595
        XCTAssertEqual(Readiness.volumeFactor(plannedFactor: deload, fatigueFactor: 0.70), 0.70, accuracy: 0.0001)

        // разгрузочная неделя + частично утомлённая (0.9) → 0.85
        XCTAssertEqual(Readiness.volumeFactor(plannedFactor: deload, fatigueFactor: 0.9), 0.85, accuracy: 0.0001)
    }

    func test_scenario25b_noAccumulationWeek_noPhasesMode_isNeutral() {
        XCTAssertEqual(Readiness.plannedVolumeFactor(cycleState: noPhasesState(), isDeloadWeek: false), 1.0,
            accuracy: 0.0001, "неделя накопления в режиме без фаз — плановый срез нейтрален")
    }

    func test_scenario25b_noAnchor_plannedFactorIsNeutral() {
        XCTAssertEqual(Readiness.plannedVolumeFactor(cycleState: noAnchorState(), isDeloadWeek: false), 1.0,
            accuracy: 0.0001, "без опорной даты срезать нечем — 1.0")
    }

    // MARK: - Сценарий 25c: без опорной даты — checkinScale = 1.6, готовность вычислима

    func test_scenario25c_noAnchor_checkinScaleSixteenAndReadinessComputable() {
        let state = noAnchorState()
        XCTAssertEqual(Readiness.checkinScale(cycleState: state), 1.6, accuracy: 0.0001)

        let checkin = DailyCheckin(energy: 5, soreness: 1, sleepQuality: 5, stress: 1)
        let readiness = Readiness.value(cycleState: state, override: nil, checkin: checkin)
        // checkinAdjustment = (5-3)*0.02 + (3-1)*0.015 + (5-3)*0.015 + (3-1)*0.01 = 0.04+0.03+0.03+0.02 = 0.12
        // readiness = 1.0 + 0 + 0.12*1.6 = 1.192 → clamp к 1.10
        XCTAssertEqual(readiness, 1.10, accuracy: 0.0001, "готовность вычислима и без опорной даты")
    }

    // MARK: - Контракт: checkinAdjustment — пропуск нейтрален

    func test_missingCheckinComponents_areNeutral() {
        XCTAssertEqual(Readiness.checkinAdjustment(DailyCheckin()), 0, accuracy: 0.0001)
        XCTAssertEqual(Readiness.checkinAdjustment(DailyCheckin(energy: 3, soreness: 3, sleepQuality: 3, stress: 3)),
            0, accuracy: 0.0001, "ответ 3 по всем компонентам эквивалентен пропуску")
    }

    func test_partialCheckin_onlyFilledComponentsContribute() {
        let checkin = DailyCheckin(energy: 5) // остальные не заполнены
        XCTAssertEqual(Readiness.checkinAdjustment(checkin), 0.04, accuracy: 0.0001)
    }

    func test_noRowAtAll_readinessIsNeutralDay() {
        // «Нет строки — checkinAdjustment = 0» — нейтральный день, а не сниженный.
        let state = phaseState(phase: .earlyLuteal, cycleConfidence: 1.0) // effectiveAdjustment = 0
        let readiness = Readiness.value(cycleState: state, override: nil, checkin: DailyCheckin())
        XCTAssertEqual(readiness, 1.0, accuracy: 0.0001)
    }

    // MARK: - Контракт: clamp диапазона §10

    func test_readinessNeverExceedsRange() {
        let state = phaseState(phase: .earlyLuteal, cycleConfidence: 1.0)
        let extremeHigh = DailyCheckin(energy: 5, soreness: 1, sleepQuality: 5, stress: 1)
        let extremeLow = DailyCheckin(energy: 1, soreness: 5, sleepQuality: 1, stress: 5)

        XCTAssertLessThanOrEqual(
            Readiness.value(cycleState: state, override: .push, checkin: extremeHigh), Readiness.range.upperBound)
        XCTAssertGreaterThanOrEqual(
            Readiness.value(cycleState: state, override: .ease, checkin: extremeLow), Readiness.range.lowerBound)
    }

    // MARK: - Контракт: ±1 подход на сессию — пороги и размещение

    func test_sessionSetDelta_thresholdsAreStrict() {
        XCTAssertEqual(Readiness.sessionSetDelta(readiness: 0.9), 0, "0.9 сама поправки не даёт")
        XCTAssertEqual(Readiness.sessionSetDelta(readiness: 1.05), 0, "1.05 сама поправки не даёт")
        XCTAssertEqual(Readiness.sessionSetDelta(readiness: 0.89), -1)
        XCTAssertEqual(Readiness.sessionSetDelta(readiness: 1.06), 1)
        XCTAssertEqual(Readiness.sessionSetDelta(readiness: 1.0), 0)
    }

    func test_exerciseForSessionSetIncrease_picksFirstWithoutFatiguedMuscle() {
        XCTAssertEqual(Readiness.exerciseForSessionSetIncrease(hasFatiguedMuscle: [true, false, false]), 1)
        XCTAssertNil(Readiness.exerciseForSessionSetIncrease(hasFatiguedMuscle: [true, true]),
            "все упражнения утомлены — +1 не даётся вовсе")
        XCTAssertNil(Readiness.exerciseForSessionSetIncrease(hasFatiguedMuscle: []))
    }

    func test_exerciseForSessionSetDecrease_picksMostFatigued() {
        // Меньший volumeMultiplier — более утомлённая мышца.
        XCTAssertEqual(Readiness.exerciseForSessionSetDecrease(worstVolumeMultiplier: [1.0, 0.7, 0.9]), 1)
    }

    func test_exerciseForSessionSetDecrease_fallsBackToLastWhenNoneFatigued() {
        XCTAssertEqual(Readiness.exerciseForSessionSetDecrease(worstVolumeMultiplier: [1.0, 1.0, 1.0]), 2)
    }

    func test_exerciseForSessionSetDecrease_tiedMostFatigued_picksFirst() {
        // Индексы 1 и 2 равно утомлены (оба — минимум 0.7 в сессии). Правило
        // зеркалит exerciseForSessionSetIncrease («первый из равнозначных»,
        // не «любой»): −1 достаётся ПЕРВОМУ из них, индекс 1, а не 2 — важно
        // зафиксировать явно тестом, а не полагаться на прочтение исходника:
        // это ровно тот класс бага (направление тай-брейка при копировании
        // симметричного правила), который уже путал направления в
        // WeightLadder/Progression.
        XCTAssertEqual(Readiness.exerciseForSessionSetDecrease(worstVolumeMultiplier: [1.0, 0.7, 0.7, 0.9]), 1,
            "среди нескольких равно-утомлённых упражнений −1 достаётся первому по порядку сессии")
    }

    func test_exerciseForSessionSetDecrease_emptySessionReturnsNil() {
        XCTAssertNil(Readiness.exerciseForSessionSetDecrease(worstVolumeMultiplier: []))
    }

    // MARK: - Контракт: вес следует порогу RIR (0.8...1.8 — не срезает надбавку)

    func test_weightReadiness_partialFatigue_keepsBonus() {
        let partial = RecoveryAdjustment(targetRIRDelta: 0, volumeMultiplier: 0.85) // 0.8...1.8, targetRIRDelta == 0
        XCTAssertEqual(Readiness.weightReadiness(readiness: 1.08, contributingMuscleAdjustments: [partial]),
            1.08, accuracy: 0.0001, "частичное утомление не срезает надбавку к весу")
    }

    func test_weightReadiness_notRecovered_capsAboveOneButNotBelow() {
        let notRecovered = RecoveryAdjustment(targetRIRDelta: 1, volumeMultiplier: 0.7)
        XCTAssertEqual(Readiness.weightReadiness(readiness: 1.08, contributingMuscleAdjustments: [notRecovered]),
            1.0, accuracy: 0.0001)
        XCTAssertEqual(Readiness.weightReadiness(readiness: 0.9, contributingMuscleAdjustments: [notRecovered]),
            0.9, accuracy: 0.0001, "срез только сверху — низкая готовность режет вес как обычно")
    }

    func test_weightReadiness_noContributingMuscles_passesThrough() {
        XCTAssertEqual(Readiness.weightReadiness(readiness: 1.05, contributingMuscleAdjustments: []),
            1.05, accuracy: 0.0001)
    }

    // MARK: - Контракт: override.rest численно равен ease на уровне слагаемого

    func test_overrideAdjustment_restEqualsEase() {
        XCTAssertEqual(Readiness.overrideAdjustment(.rest), Readiness.overrideAdjustment(.ease), accuracy: 0.0001)
        XCTAssertEqual(Readiness.overrideAdjustment(.push), 0.08, accuracy: 0.0001)
        XCTAssertEqual(Readiness.overrideAdjustment(.ease), -0.10, accuracy: 0.0001)
    }
}
