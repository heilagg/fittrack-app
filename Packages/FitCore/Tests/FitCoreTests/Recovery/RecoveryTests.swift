//  Recovery — контракт §8.1–§8.4. В номерном списке SPEC §18 модулю не
//  выделено сценариев (см. doc-комментарий Recovery.swift), поэтому все
//  тесты здесь помечены `// MARK:`, а не `test_scenarioN`.
//
//  XCTest, а не Swift Testing — то же ограничение окружения (только Command
//  Line Tools), что и в остальных тестах FitCore.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import XCTest
@testable import FitCore

final class RecoveryTests: XCTestCase {

    private func day(_ n: Int) -> CalendarDay {
        CalendarDay(year: 2026, month: 1, day: 1).adding(days: n)
    }

    // MARK: - intensity_factor (SPEC §8.1)

    func test_intensityFactorMatchesSpecTable() {
        XCTAssertEqual(Recovery.intensityFactor(for: .easy), 0.6, accuracy: 0.0001)
        XCTAssertEqual(Recovery.intensityFactor(for: .ok), 1.0, accuracy: 0.0001)
        XCTAssertEqual(Recovery.intensityFactor(for: .hard), 1.35, accuracy: 0.0001)
        XCTAssertEqual(Recovery.intensityFactor(for: .failed), 1.5, accuracy: 0.0001)
    }

    // MARK: - Период полураспада (SPEC §8.1)

    func test_halfLifeGroupsMatchSpec() {
        for m: MuscleSlug in [.gluteMax, .quads, .hamstrings, .lats, .pecs] {
            XCTAssertEqual(Recovery.fatigueHalfLifeHours(for: m), 30, "\(m)")
        }
        for m: MuscleSlug in [.biceps, .triceps, .sideDelts, .calves] {
            XCTAssertEqual(Recovery.fatigueHalfLifeHours(for: m), 20, "\(m)")
        }
        XCTAssertEqual(Recovery.fatigueHalfLifeHours(for: .erectors), 40)
    }

    func test_unclassifiedMusclesFallBackToTwentyHours() {
        // SPEC не относит эти мышцы ни к одной из трёх групп §8.1 — см.
        // описание PR. Дефолт задокументирован в Recovery.fatigueHalfLifeHours.
        for m: MuscleSlug in [.gluteMed, .adductors, .trapsMid, .trapsUpper, .rearDelts, .frontDelts, .forearms, .abs, .obliques] {
            XCTAssertEqual(Recovery.fatigueHalfLifeHours(for: m), 20, "\(m)")
        }
    }

    // MARK: - Накопление и распад (SPEC §8.1)

    func test_accumulationSumsWeightedContributionsAcrossSets() {
        let sets = [
            FatigueSet(muscleLoad: [.gluteMax: 0.6, .hamstrings: 0.2], feedback: .ok),
            FatigueSet(muscleLoad: [.gluteMax: 0.6, .hamstrings: 0.2], feedback: .hard)
        ]
        let result = Recovery.applying(sets, at: Timestamp(hoursSinceEpoch: 0), to: [:])
        // Δglute_max = 0.6×1.0 + 0.6×1.35 = 1.41; Δhamstrings = 0.2×1.0 + 0.2×1.35 = 0.47
        XCTAssertEqual(result[.gluteMax]!.value, 1.41, accuracy: 0.0001)
        XCTAssertEqual(result[.hamstrings]!.value, 0.47, accuracy: 0.0001)
    }

    func test_decayMatchesExponentialFormula() {
        let state = FatigueState(value: 2.0, updatedAt: Timestamp(hoursSinceEpoch: 0))
        // erectors: halfLife 40ч — через 40ч должно остаться ровно половина.
        let decayed = Recovery.decayed(state, to: Timestamp(hoursSinceEpoch: 40), muscle: .erectors)
        XCTAssertEqual(decayed, 1.0, accuracy: 0.0001)
    }

    func test_untouchedMusclesStillDecayWhenOtherMusclesAreWorked() {
        let seed: [MuscleSlug: FatigueState] = [.quads: FatigueState(value: 2.0, updatedAt: Timestamp(hoursSinceEpoch: 0))]
        let sets = [FatigueSet(muscleLoad: [.biceps: 1.0], feedback: .ok)]
        // quads: halfLife 30ч — через 30ч распад до половины, даже без своих подходов.
        let result = Recovery.applying(sets, at: Timestamp(hoursSinceEpoch: 30), to: seed)
        XCTAssertEqual(result[.quads]!.value, 1.0, accuracy: 0.0001)
        XCTAssertEqual(result[.biceps]!.value, 1.0, accuracy: 0.0001)
    }

    func test_muscleWithNoPriorStateStartsFromZero() {
        let result = Recovery.applying([FatigueSet(muscleLoad: [.abs: 0.5], feedback: .ok)],
                                        at: Timestamp(hoursSinceEpoch: 100), to: [:])
        XCTAssertEqual(result[.abs]!.value, 0.5, accuracy: 0.0001)
    }

    func test_outOfOrderTimestampDoesNotDecreaseValue() {
        // Свёртка ожидает хронологический порядок (как и rebuildStates
        // Progression); при рассинхронизации не «уезжаем» в отрицательное
        // время, а просто не применяем распад назад.
        let state = FatigueState(value: 1.0, updatedAt: Timestamp(hoursSinceEpoch: 100))
        let decayed = Recovery.decayed(state, to: Timestamp(hoursSinceEpoch: 50), muscle: .lats)
        XCTAssertEqual(decayed, 1.0, accuracy: 0.0001)
    }

    // MARK: - Пороги восстановления (SPEC §8.1)

    func test_recoveryStatusThresholds() {
        XCTAssertEqual(Recovery.recoveryStatus(forFatigue: 0.79), .recovered)
        XCTAssertEqual(Recovery.recoveryStatus(forFatigue: 0.8), .partial)
        XCTAssertEqual(Recovery.recoveryStatus(forFatigue: 1.8), .partial)
        XCTAssertEqual(Recovery.recoveryStatus(forFatigue: 1.81), .notRecovered)
    }

    // MARK: - Поправка к рекомендации (SPEC §8.2, §8.3), не входит в номерные сценарии

    func test_adjustmentIsNeutralWhenRecovered() {
        let adjustment = Recovery.adjustment(forFatigue: 0.5)
        XCTAssertEqual(adjustment.targetRIRDelta, 0)
        XCTAssertEqual(adjustment.volumeMultiplier, 1.0, accuracy: 0.0001)
    }

    func test_adjustmentMatchesSpecNumbersWhenNotRecovered() {
        // SPEC §8.3: RIR+1, объём ×0.7 (−30%).
        let adjustment = Recovery.adjustment(forFatigue: 2.5)
        XCTAssertEqual(adjustment.targetRIRDelta, 1)
        XCTAssertEqual(adjustment.volumeMultiplier, 0.7, accuracy: 0.0001)
    }

    func test_adjustmentInterpolatesVolumeAcrossThePartialBand() {
        let mid = Recovery.adjustment(forFatigue: 1.3) // середина 0.8...1.8
        XCTAssertEqual(mid.targetRIRDelta, 0)
        XCTAssertEqual(mid.volumeMultiplier, 0.85, accuracy: 0.0001)
        let atLowerEdge = Recovery.adjustment(forFatigue: 0.8)
        XCTAssertEqual(atLowerEdge.volumeMultiplier, 1.0, accuracy: 0.0001)
        let atUpperEdge = Recovery.adjustment(forFatigue: 1.8)
        XCTAssertEqual(atUpperEdge.volumeMultiplier, 0.7, accuracy: 0.0001)
    }

    func test_volumeNeverReachesZeroEvenAtExtremeFatigue() {
        // SPEC §8.2: утомление режет объём, но НЕ блокирует тренировку.
        for value in [1.81, 5.0, 50.0, 1000.0] {
            let adjustment = Recovery.adjustment(forFatigue: value)
            XCTAssertGreaterThanOrEqual(adjustment.volumeMultiplier, 0.7 - 0.0001, "fatigue=\(value)")
        }
    }

    // MARK: - Флаг боли: исключение на 14 дней (SPEC §8.4, п.3)

    func test_exerciseExcludedWithinFourteenDaysOfPainFlag() {
        let events = [PainEvent(exerciseSlug: "hip_thrust_barbell", joint: .hip, occurredOn: day(0))]
        XCTAssertTrue(Recovery.isExcluded(exerciseSlug: "hip_thrust_barbell", from: events, asOf: day(14)))
        XCTAssertFalse(Recovery.isExcluded(exerciseSlug: "hip_thrust_barbell", from: events, asOf: day(15)))
        XCTAssertFalse(Recovery.isExcluded(exerciseSlug: "other_exercise", from: events, asOf: day(1)))
    }

    // MARK: - Флаг боли: эскалация за 30 дней (SPEC §8.4, п.4–5)

    func test_twoFlagsOnSameExerciseWithinThirtyDaysSuggestsPermanentRestriction() {
        let events = [
            PainEvent(exerciseSlug: "squat_barbell", joint: .knee, occurredOn: day(0)),
            PainEvent(exerciseSlug: "squat_barbell", joint: .knee, occurredOn: day(20))
        ]
        XCTAssertEqual(Recovery.escalations(from: events, asOf: day(20)),
                       [.suggestPermanentRestriction(exerciseSlug: "squat_barbell")])
    }

    func test_singleFlagDoesNotEscalate() {
        let events = [PainEvent(exerciseSlug: "squat_barbell", joint: .knee, occurredOn: day(0))]
        XCTAssertEqual(Recovery.escalations(from: events, asOf: day(0)), [])
    }

    func test_threeFlagsOnDifferentExercisesSameJointSuggestsSpecialist() {
        let events = [
            PainEvent(exerciseSlug: "squat_barbell", joint: .knee, occurredOn: day(0)),
            PainEvent(exerciseSlug: "lunge_dumbbell", joint: .knee, occurredOn: day(10)),
            PainEvent(exerciseSlug: "leg_press", joint: .knee, occurredOn: day(20))
        ]
        XCTAssertEqual(Recovery.escalations(from: events, asOf: day(20)),
                       [.suggestSpecialist(joint: .knee)])
    }

    func test_twoDifferentExercisesSameJointDoesNotEscalate() {
        let events = [
            PainEvent(exerciseSlug: "squat_barbell", joint: .knee, occurredOn: day(0)),
            PainEvent(exerciseSlug: "lunge_dumbbell", joint: .knee, occurredOn: day(10))
        ]
        XCTAssertEqual(Recovery.escalations(from: events, asOf: day(10)), [])
    }

    func test_repeatedFlagsOnSameExerciseDoNotCountAsDifferentExercisesForJointRule() {
        // §8.4 п.5 явно требует «разных» упражнений — два флага на одном и
        // том же squat_barbell плюс один на другом упражнении того же
        // сустава — это 2 разных упражнения, не 3, специалист не предлагается.
        let events = [
            PainEvent(exerciseSlug: "squat_barbell", joint: .knee, occurredOn: day(0)),
            PainEvent(exerciseSlug: "squat_barbell", joint: .knee, occurredOn: day(5)),
            PainEvent(exerciseSlug: "lunge_dumbbell", joint: .knee, occurredOn: day(10))
        ]
        let escalations = Recovery.escalations(from: events, asOf: day(10))
        XCTAssertEqual(escalations, [.suggestPermanentRestriction(exerciseSlug: "squat_barbell")])
    }

    func test_eventsOlderThanThirtyDaysDoNotCountTowardsEscalation() {
        let events = [
            PainEvent(exerciseSlug: "squat_barbell", joint: .knee, occurredOn: day(0)),
            PainEvent(exerciseSlug: "squat_barbell", joint: .knee, occurredOn: day(31))
        ]
        XCTAssertEqual(Recovery.escalations(from: events, asOf: day(31)), [])
    }

    // MARK: - Флаг боли: выбор сустава (SPEC §6.2 joint_stress)

    func test_primaryJointPicksHighestStressLevel() {
        let stress: [Joint: JointStressLevel] = [.knee: .low, .hip: .medium, .lowerBack: .high]
        XCTAssertEqual(Recovery.primaryJoint(from: stress), .lowerBack)
    }

    func test_primaryJointBreaksTieByDeclarationOrder() {
        // Канонический пример §6.2 (hip_thrust_barbell) сам содержит ничью:
        // lower_back и hip оба medium. Тай-брейк — порядок объявления Joint,
        // повторяющий порядок из §3.1, где lowerBack идёт раньше hip.
        let stress: [Joint: JointStressLevel] = [.knee: .low, .lowerBack: .medium, .hip: .medium]
        XCTAssertEqual(Recovery.primaryJoint(from: stress), .lowerBack)
    }

    func test_primaryJointIsStableRegardlessOfDictionaryOrder() {
        // Словарь не хранит порядок вставки — резолвер обязан давать один и
        // тот же ответ, иначе две вызывающие стороны разошлись бы на ничьей.
        let stress: [Joint: JointStressLevel] = [.hip: .medium, .lowerBack: .medium, .knee: .low]
        for _ in 0..<50 {
            XCTAssertEqual(Recovery.primaryJoint(from: stress), .lowerBack)
        }
    }

    func test_primaryJointWithSingleEntryReturnsIt() {
        XCTAssertEqual(Recovery.primaryJoint(from: [.wrist: .low]), .wrist)
    }

    func test_primaryJointOfEmptyStressMapIsNil() {
        // Пустой joint_stress — ошибка разметки контента, ловится валидатором,
        // а не здесь; резолвер обязан лишь не падать.
        XCTAssertNil(Recovery.primaryJoint(from: [:]))
    }

    // MARK: - Многосессионный прогон (implement-feature skill §5а)
    //
    // Обязателен, потому что Recovery.applying(_:at:to:) — та же свёртка по
    // сессиям (новое состояние = f(старое состояние, новое событие)), что и
    // rebuildStates в Progression, где точечные и даже 4-сессионные тесты не
    // поймали накапливающееся расхождение (спираль deload, незавершённая
    // калибровка). Здесь состояние — экспоненциальный ряд, у которого есть
    // точный аналитический потолок, так что 30+-шаговый прогон проверяется
    // не «на глаз», а против формулы.

    func test_repeatedHeavySessionsConvergeAndNeverExceedTheoreticalCeiling() {
        // Одна и та же мышца, один и тот же интервал и вклад на каждой из 35
        // сессий подряд — КАЖДАЯ следующая точка строится из состояния,
        // оставленного предыдущей через Recovery.applying, а не задаётся
        // руками. r — доля утомления, доживающая до следующей сессии; ряд
        // V_{n+1} = r·V_n + Δ сходится к потолку Δ/(1−r) и никогда его не
        // превышает (по индукции: V_n ≤ потолок ⟹ V_{n+1} = r·V_n+Δ ≤
        // r·потолок+Δ = потолок). Превышение потолка на любом шаге означает,
        // что распад и накопление применяются в неверном порядке.
        let muscle = MuscleSlug.gluteMax
        let halfLife = Recovery.fatigueHalfLifeHours(for: muscle)
        let intervalHours = 24.0
        let delta = 1.0
        let r = pow(0.5, intervalHours / halfLife)
        let ceiling = delta / (1 - r)

        var states: [MuscleSlug: FatigueState] = [:]
        var timestamp = Timestamp(hoursSinceEpoch: 0)
        var path: [Double] = []

        for _ in 0..<35 {
            states = Recovery.applying([FatigueSet(muscleLoad: [muscle: delta], feedback: .ok)],
                                        at: timestamp, to: states)
            path.append(states[muscle]!.value)
            timestamp = timestamp.adding(hours: intervalHours)
        }

        for (i, v) in path.enumerated() {
            XCTAssertLessThanOrEqual(v, ceiling + 0.0001, "шаг \(i) превысил теоретический потолок; путь: \(path)")
        }
        let tail = path.suffix(10)
        XCTAssertEqual(tail.min()!, tail.max()!, accuracy: 0.001,
                       "должно сойтись к потолку задолго до 35-й сессии; путь: \(path)")
        XCTAssertEqual(tail.last!, ceiling, accuracy: 0.001)
    }

    func test_alternatingTrainingAndRestBlocksReturnToRecoveredEveryTimeWithoutResidualDrift() {
        // 6 повторов блока «3 тяжёлые сессии + долгий отдых» — 24 события,
        // каждое строится из состояния, оставленного предыдущим. Отдых
        // (10 суток = 240ч, ≥6 периодов полураспада для самой мышцы с
        // halfLife 30ч у glute_max) должен КАЖДЫЙ раз возвращать мышцу в
        // .recovered, а не давать растущий с каждым блоком остаток —
        // именно такой остаток был бы признаком дрейфа состояния.
        let muscle = MuscleSlug.gluteMax
        var states: [MuscleSlug: FatigueState] = [:]
        var timestamp = Timestamp(hoursSinceEpoch: 0)
        var statusAfterRest: [RecoveryStatus] = []

        for _ in 0..<6 {
            for _ in 0..<3 {
                states = Recovery.applying([FatigueSet(muscleLoad: [muscle: 1.0], feedback: .hard)],
                                            at: timestamp, to: states)
                timestamp = timestamp.adding(hours: 24)
            }
            timestamp = timestamp.adding(hours: 240)
            states = Recovery.applying([], at: timestamp, to: states)
            statusAfterRest.append(Recovery.recoveryStatus(forFatigue: states[muscle]!.value))
        }

        XCTAssertEqual(statusAfterRest, Array(repeating: .recovered, count: 6),
                       "каждый блок отдыха обязан возвращать в .recovered без остатка")
        XCTAssertLessThan(states[muscle]!.value, 0.01,
                          "после 6 циклов остаточное утомление не должно расти; итог: \(states[muscle]!.value)")
    }

    // MARK: - Регрессии код-ревью feature/recovery, 2026-09-08
    //
    // Вызов не по порядку — штатный вход, а не дефект вызывающего: SPEC §4.3
    // offline-first, две сессии с двух устройств приходят в произвольном
    // порядке. Раньше applying безусловно штамповал updatedAt переданным
    // моментом, отматывая метку времени назад; последующий распад считался
    // от неверной точки отсчёта.

    private func fatigueSet(_ muscle: MuscleSlug, _ load: Double, _ feedback: Feedback = .ok) -> FatigueSet {
        FatigueSet(muscleLoad: [muscle: load], feedback: feedback)
    }

    func test_applyingOutOfOrderNeverMovesUpdatedAtBackward() {
        // Мышца, которой запоздавшая сессия вообще не касается, обязана
        // сохранить и значение, и метку времени.
        let seeded = Recovery.applying([fatigueSet(.quads, 1.0)],
                                        at: Timestamp(hoursSinceEpoch: 100), to: [:])
        XCTAssertEqual(seeded[.quads]!.updatedAt.hoursSinceEpoch, 100, accuracy: 0.0001)

        let late = Recovery.applying([fatigueSet(.hamstrings, 1.0)],
                                      at: Timestamp(hoursSinceEpoch: 50), to: seeded)
        XCTAssertEqual(late[.quads]!.updatedAt.hoursSinceEpoch, 100, accuracy: 0.0001,
                       "updatedAt не должен уезжать назад")
        XCTAssertEqual(late[.quads]!.value, seeded[.quads]!.value, accuracy: 0.0001,
                       "нетронутая мышца не должна менять значение")
    }

    func test_lateArrivingSessionIsCreditedWithItsOwnDecay() {
        // Контроль к предыдущему: одного max() по updatedAt мало. Дельта
        // 50-часовой давности обязана прийти продекейненной, а не целиком.
        let seeded = Recovery.applying([fatigueSet(.quads, 1.0)],
                                        at: Timestamp(hoursSinceEpoch: 100), to: [:])
        let late = Recovery.applying([fatigueSet(.quads, 1.0)],
                                      at: Timestamp(hoursSinceEpoch: 50), to: seeded)

        let halfLife = Recovery.fatigueHalfLifeHours(for: .quads)
        let expected = seeded[.quads]!.value + 1.0 * pow(0.5, 50 / halfLife)
        XCTAssertEqual(late[.quads]!.value, expected, accuracy: 0.0001)
        XCTAssertLessThan(late[.quads]!.value, seeded[.quads]!.value + 1.0,
                          "запоздавшая дельта не должна засчитываться как только что произошедшая")
    }

    private func permutations<T>(_ items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        var result: [[T]] = []
        for index in items.indices {
            var rest = items
            let item = rest.remove(at: index)
            for tail in permutations(rest) { result.append([item] + tail) }
        }
        return result
    }

    func test_applyingIsOrderIndependent() {
        // Прямая проверка того, чем doc-комментарий модуля обосновывает весь
        // инкрементальный дизайн: свёртка журнала в ЛЮБОМ порядке даёт одно и
        // то же состояние — не только значение, но и updatedAt (иначе две
        // сошедшиеся по смыслу строки `muscle_fatigue` отличались бы
        // побайтово, см. §18 сценарий 37). Каждый шаг строится применением к
        // результату предыдущего, значения руками не задаются.
        //
        // Проверяются все 720 перестановок, а не выборка: именно накопление
        // расхождения по порядку событий — тот класс дефектов, который
        // точечные тесты этого модуля пропустили при ревью.
        let events: [(Timestamp, [FatigueSet])] = [
            (Timestamp(hoursSinceEpoch: 0), [fatigueSet(.quads, 1.0, .hard)]),
            (Timestamp(hoursSinceEpoch: 30), [fatigueSet(.hamstrings, 0.8)]),
            (Timestamp(hoursSinceEpoch: 55), [fatigueSet(.quads, 0.5, .easy), fatigueSet(.erectors, 1.2)]),
            (Timestamp(hoursSinceEpoch: 96), [fatigueSet(.biceps, 0.9, .failed)]),
            (Timestamp(hoursSinceEpoch: 130), [fatigueSet(.quads, 1.1)]),
            (Timestamp(hoursSinceEpoch: 175), [fatigueSet(.erectors, 0.4, .easy)])
        ]

        func fold(_ order: [(Timestamp, [FatigueSet])]) -> [MuscleSlug: FatigueState] {
            var states: [MuscleSlug: FatigueState] = [:]
            for (at, sets) in order {
                states = Recovery.applying(sets, at: at, to: states)
            }
            return states
        }

        let chronological = fold(events)
        XCTAssertEqual(chronological.count, 4)
        let orders = permutations(events)
        XCTAssertEqual(orders.count, 720)

        for (n, order) in orders.enumerated() {
            let out = fold(order)
            XCTAssertEqual(Set(out.keys), Set(chronological.keys), "перестановка \(n)")
            for (muscle, state) in chronological {
                XCTAssertEqual(out[muscle]!.value, state.value, accuracy: 0.0001,
                               "\(muscle), перестановка \(n): порядок свёртки не должен влиять на значение")
                XCTAssertEqual(out[muscle]!.updatedAt, state.updatedAt,
                               "\(muscle), перестановка \(n): порядок свёртки не должен влиять на updatedAt")
            }
        }
    }
}
