#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// SPEC §8.1: накопление утомления по подходам и экспоненциальный распад.
public enum Recovery {

    /// SPEC §8.1: `intensity_factor(feedback)`.
    public static func intensityFactor(for feedback: Feedback) -> Double {
        switch feedback {
        case .easy: return 0.6
        case .ok: return 1.0
        case .hard: return 1.35
        case .failed: return 1.5
        }
    }

    /// Период полураспада утомления, часы (SPEC §8.1).
    ///
    /// SPEC называет явно только три группы (крупные/мелкие/erectors) и не
    /// относит к ним `gluteMed`, `adductors`, `trapsMid`, `trapsUpper`,
    /// `rearDelts`, `frontDelts`, `forearms`, `abs`, `obliques` — несостыковка
    /// со SPEC.md, см. описание PR. Для неперечисленных мышц выбрано 20ч
    /// (группа «мелкие») как консервативный дефолт: SPEC §8.2 требует не
    /// блокировать тренировку утомлением, а более быстрый распад для
    /// неклассифицированной мышцы реже завышает её утомление там, где это
    /// не подтверждено спекой.
    public static func fatigueHalfLifeHours(for muscle: MuscleSlug) -> Double {
        switch muscle {
        case .gluteMax, .quads, .hamstrings, .lats, .pecs:
            return 30
        case .biceps, .triceps, .sideDelts, .calves:
            return 20
        case .erectors:
            return 40
        default:
            return 20
        }
    }

    /// Утомление мышцы, перенесённое распадом с `state.updatedAt` на
    /// `timestamp`. `timestamp` раньше `state.updatedAt` не уменьшает
    /// значение (защита от рассинхронизированного порядка входа, а не
    /// «отрицательное время» из SPEC).
    public static func decayed(_ state: FatigueState, to timestamp: Timestamp, muscle: MuscleSlug) -> Double {
        let elapsedHours = state.updatedAt.hours(until: timestamp)
        guard elapsedHours > 0 else { return state.value }
        let halfLife = fatigueHalfLifeHours(for: muscle)
        return state.value * pow(0.5, elapsedHours / halfLife)
    }

    /// Применяет подходы одной тренировки к текущим состояниям утомления:
    /// сначала распад каждой затронутой мышцы до `timestamp`, затем
    /// добавление `Δfatigue[m] = Σ muscleLoad[m] × intensityFactor(feedback)`
    /// (SPEC §8.1). Мышцы без предшествующего состояния стартуют с 0.
    ///
    /// Инкрементально, а не сверткой по всей истории: экспоненциальный
    /// распад коммутативен по времени (распад на t₁, затем на t₂, даёт то
    /// же самое, что распад сразу на t₁+t₂), поэтому одного `(value,
    /// updatedAt)` на мышцу достаточно — как в самой таблице `muscle_fatigue`.
    public static func applying(
        _ sets: [FatigueSet],
        at timestamp: Timestamp,
        to states: [MuscleSlug: FatigueState]
    ) -> [MuscleSlug: FatigueState] {
        var deltas: [MuscleSlug: Double] = [:]
        for set in sets {
            let factor = intensityFactor(for: set.feedback)
            for (muscle, load) in set.muscleLoad {
                deltas[muscle, default: 0] += load * factor
            }
        }

        var result = states
        for muscle in Set(states.keys).union(deltas.keys) {
            let carried = states[muscle].map { decayed($0, to: timestamp, muscle: muscle) } ?? 0
            let newValue = max(0, carried + (deltas[muscle] ?? 0))
            result[muscle] = FatigueState(value: newValue, updatedAt: timestamp)
        }
        return result
    }

    /// SPEC §8.1: пороги восстановления.
    public static func recoveryStatus(forFatigue value: Double) -> RecoveryStatus {
        if value < 0.8 { return .recovered }
        if value <= 1.8 { return .partial }
        return .notRecovered
    }

    /// Поправка к рекомендации (SPEC §8.2, §8.3).
    ///
    /// SPEC даёт числа только для крайнего случая — «не восстановлена»
    /// (§8.3: RIR+1, объём ×0.7). Для «частично» (0.8...1.8) числа не даны,
    /// хотя §8.2 требует, чтобы утомление влияло на рекомендацию уже здесь,
    /// не только за порогом 1.8. Выбор: линейная интерполяция объёма между
    /// 1.0 на границе 0.8 и 0.7 на границе 1.8, RIR+1 — только при полном
    /// «не восстановлена» (§8.3 описывает конфликт «пятый день подряд»,
    /// то есть именно этот крайний случай). Не факт из SPEC — задокументированный
    /// выбор, см. описание PR.
    public static func adjustment(forFatigue value: Double) -> RecoveryAdjustment {
        switch recoveryStatus(forFatigue: value) {
        case .recovered:
            return RecoveryAdjustment(targetRIRDelta: 0, volumeMultiplier: 1.0)
        case .partial:
            let t = (value - 0.8) / (1.8 - 0.8)
            return RecoveryAdjustment(targetRIRDelta: 0, volumeMultiplier: 1.0 - 0.3 * t)
        case .notRecovered:
            return RecoveryAdjustment(targetRIRDelta: 1, volumeMultiplier: 0.7)
        }
    }
}
