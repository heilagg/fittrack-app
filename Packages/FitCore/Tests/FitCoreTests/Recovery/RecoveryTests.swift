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
}
