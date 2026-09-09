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
    ///
    /// Switch исчерпывающий, без `default`, намеренно: `MuscleSlug` закрыт
    /// (§6.4 — фиксированный список), и новая мышца обязана не скомпилироваться,
    /// пока ей не назначили период полураспада явно. Неклассифицированные
    /// мышцы вынесены отдельной веткой, а не слиты с «мелкими», чтобы граница
    /// между значением из SPEC и выбранным дефолтом оставалась видна в коде.
    public static func fatigueHalfLifeHours(for muscle: MuscleSlug) -> Double {
        switch muscle {
        case .gluteMax, .quads, .hamstrings, .lats, .pecs:
            return 30
        case .biceps, .triceps, .sideDelts, .calves:
            return 20
        case .erectors:
            return 40
        case .gluteMed, .adductors, .trapsMid, .trapsUpper, .rearDelts,
             .frontDelts, .forearms, .abs, .obliques:
            return 20
        }
    }

    /// Доля утомления, дожившая за `hours` (SPEC §8.1). `hours <= 0` — множитель
    /// 1: назад во времени утомление не экстраполируется.
    private static func decayFactor(hours: Double, muscle: MuscleSlug) -> Double {
        guard hours > 0 else { return 1 }
        return pow(0.5, hours / fatigueHalfLifeHours(for: muscle))
    }

    /// Утомление мышцы, перенесённое распадом с `state.updatedAt` на
    /// `timestamp`. `timestamp` раньше `state.updatedAt` не увеличивает
    /// значение: это запрос «сколько сейчас», а не экстраполяция в прошлое.
    public static func decayed(_ state: FatigueState, to timestamp: Timestamp, muscle: MuscleSlug) -> Double {
        state.value * decayFactor(hours: state.updatedAt.hours(until: timestamp), muscle: muscle)
    }

    /// Применяет подходы одной тренировки к текущим состояниям утомления:
    /// `Δfatigue[m] = Σ muscleLoad[m] × intensityFactor(feedback)` (SPEC §8.1).
    /// Мышцы без предшествующего состояния стартуют с 0.
    ///
    /// Инкрементально, а не сверткой по всей истории: утомление линейно по
    /// вкладам, `F(T) = Σ dᵢ · 0.5^((T − tᵢ)/H)`, поэтому одного
    /// `(value, updatedAt)` на мышцу достаточно — ровно то, что хранит таблица
    /// `muscle_fatigue` (SPEC §3.1).
    ///
    /// **Порядок вызовов не влияет на результат, и `updatedAt` не убывает.**
    /// Обе величины — накопленное значение и новая дельта — приводятся к более
    /// позднему из двух моментов, поэтому запоздавший подход (SPEC §4.3:
    /// offline-first, две сессии с двух устройств приходят в произвольном
    /// порядке) засчитывается со своим собственным распадом, а не как
    /// произошедший только что. Свернуть журнал в любом порядке — значит
    /// получить то же состояние.
    ///
    /// Коммутативность опирается на неотрицательность дельт
    /// (`muscleLoad ≥ 0`, `intensityFactor > 0`), при которой клэмп `max(0,…)`
    /// ниже никогда не срабатывает и потому не зависит от порядка.
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

        // Единый момент на весь вызов, а не свой на каждую мышцу: только так
        // представление получается каноническим. С «своим» моментом порядок
        // свёртки менял бы updatedAt (последний вызов с ранней меткой не
        // подтягивает вперёд остальные мышцы), и две сошедшиеся по смыслу
        // строки `muscle_fatigue` отличались бы побайтово — §18 сценарий 37
        // («состояния сошлись») это бы не прошёл.
        let latestKnown = states.values.map(\.updatedAt).max()
        let at = latestKnown.map { max($0, timestamp) } ?? timestamp

        var result: [MuscleSlug: FatigueState] = [:]
        for muscle in Set(states.keys).union(deltas.keys) {
            let prior = states[muscle]
            let carried = (prior?.value ?? 0)
                * decayFactor(hours: prior.map { $0.updatedAt.hours(until: at) } ?? 0, muscle: muscle)
            let added = (deltas[muscle] ?? 0) * decayFactor(hours: timestamp.hours(until: at), muscle: muscle)
            result[muscle] = FatigueState(value: max(0, carried + added), updatedAt: at)
        }
        return result
    }

    /// SPEC §8.1: мышца восстановлена ниже этого значения.
    public static let recoveredBelow = 0.8
    /// SPEC §8.1: выше этого значения мышца не восстановлена.
    public static let notRecoveredAbove = 1.8
    /// SPEC §8.3: максимальный срез объёма на переутомлённую мышцу (−30%).
    public static let maxVolumeCut = 0.3

    /// SPEC §8.1: пороги восстановления.
    public static func recoveryStatus(forFatigue value: Double) -> RecoveryStatus {
        if value < recoveredBelow { return .recovered }
        if value <= notRecoveredAbove { return .partial }
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
            let t = (value - recoveredBelow) / (notRecoveredAbove - recoveredBelow)
            return RecoveryAdjustment(targetRIRDelta: 0, volumeMultiplier: 1.0 - maxVolumeCut * t)
        case .notRecovered:
            return RecoveryAdjustment(targetRIRDelta: 1, volumeMultiplier: 1.0 - maxVolumeCut)
        }
    }
}
