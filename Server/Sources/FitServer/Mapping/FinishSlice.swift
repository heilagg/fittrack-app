//  Срез завершения тренировки (SPEC §8.1, §20.3, §20.6, §20.7).
//
//  ── Закрытие — условный переход, и только он пересчитывает ────────────────
//
//  `finished_at` ставится `update … where finished_at is null returning`.
//  Строка вернулась — переход случился в ЭТОМ запросе, и утомление применяется.
//  Не вернулась — тренировка уже закрыта, и повтор `/finish` ничего не
//  применяет второй раз (§20.3): `Recovery.applying` инкрементальна, и второй
//  вызов на тех же подходах удвоил бы вклад.
//
//  ── Утомление — по моменту КАЖДОГО подхода ───────────────────────────────
//
//  `Recovery.applying` принимает один момент на вызов, но коммутативна по
//  построению (doc `FatigueDecay`), поэтому подходы группируются по
//  `sets.completed_at` и применяются N вызовами. Один вызов на `finished_at`
//  засчитал бы первый подход часовой тренировки так, будто он сделан в момент
//  закрытия, — без часа распада.
//
//  Момент переводится на шкалу FitCore в зоне ЗАПРОСА один раз, здесь
//  (§20.7): `(completed_at at time zone tz)` даёт местное время без зоны, и его
//  epoch и есть значение шкалы. В `muscle_fatigue.updated_at` (`timestamp`
//  без зоны) оно ложится как есть.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import FitCore

extension Mapping {

    /// Закрывает тренировку, если она открыта. `true` — переход случился сейчас.
    public static func closeWorkout(_ tx: UserTransaction, id: UUID) async throws -> Bool {
        let rows = try await tx.query("""
            update workouts set finished_at = now(), updated_at = now()
             where id = \(id) and finished_at is null and deleted_at is null
            returning id
            """)
        for try await _ in rows { return true }
        return false
    }

    /// Чем закрывается день плана и какой причиной (§7.1, §20.3): хотя бы один
    /// выполненный подход — `done` и `workoutCompleted`, ни одного — `skipped`
    /// и `workoutSkipped`. «Выполнен» — то же `isPerformed`, что фильтрует
    /// свёртку и утомление; калибровочный считается — подход сделан, он лишь
    /// не идёт в утомление.
    public static func finishOutcome(_ sets: [SetRow]) -> (status: PlannedDayStatus, cause: RebuildCause) {
        sets.contains(where: \.isPerformed) ? (.done, .workoutCompleted) : (.skipped, .workoutSkipped)
    }

    /// Подход тренировки вместе с его моментом на шкале FitCore.
    public struct TimedSetRow: Sendable, Equatable {
        public var row: SetRow
        public var completedAt: Timestamp
    }

    /// Подходы ОДНОЙ тренировки с моментами в зоне запроса (§20.7).
    ///
    /// `completed_at` обязателен на входе (§20.3), но колонка допускает `null`
    /// у строк, записанных до этого правила; такие строки в утомление не идут —
    /// приписывать им момент значило бы выдумать его.
    public static func readTimedSets(_ tx: UserTransaction, workoutID: UUID,
                                     timeZone: TimeZone) async throws -> [TimedSetRow] {
        let zone = timeZone.identifier
        let rows = try await tx.query("""
            select s.exercise_slug, s.set_index, s.prescribed_kg::float8, s.actual_kg::float8,
                   s.actual_reps, s.feedback, s.skipped, s.pain_flag, s.is_calibration,
                   s.weight_readiness::float8,
                   to_char((w.started_at at time zone \(zone))::date, 'YYYY-MM-DD'),
                   extract(epoch from (s.completed_at at time zone \(zone)))::float8 / 3600
              from sets s
              join workout_exercises we on we.id = s.workout_exercise_id
              join workouts w on w.id = we.workout_id
             where w.id = \(workoutID) and s.completed_at is not null
             order by we.order_index, s.set_index
            """)
        var result: [TimedSetRow] = []
        for try await row in rows {
            let (slug, index, prescribed, actual, reps, feedback, skipped, pain,
                 calibration, readiness, date, hours) =
                try row.decode((String, Int, Double?, Double?, Int?, String?, Bool, Bool,
                                Bool, Double, String, Double).self)
            result.append(TimedSetRow(
                row: SetRow(exerciseSlug: slug, setIndex: index, prescribedKg: prescribed,
                            actualKg: actual, actualReps: reps, feedback: feedback,
                            skipped: skipped, painFlag: pain, isCalibration: calibration,
                            weightReadiness: readiness,
                            performedOn: try day(date, column: "workouts.started_at")),
                completedAt: Timestamp(hoursSinceEpoch: hours)))
        }
        return result
    }

    /// Утомление после подходов тренировки: группы по моменту, по вызову
    /// `Recovery.applying` на группу. Слаг вне среза контента пропускается —
    /// без вкладов мышц его нагрузку нечем выразить.
    public static func fatigue(after sets: [TimedSetRow], library: [ExerciseCandidate],
                               from states: [MuscleSlug: FatigueState]) -> [MuscleSlug: FatigueState] {
        let bySlug = Dictionary(library.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        var groups: [Timestamp: [FatigueSet]] = [:]
        for timed in sets {
            guard let candidate = bySlug[timed.row.exerciseSlug],
                  let set = fatigueSet(from: timed.row, candidate: candidate) else { continue }
            groups[timed.completedAt, default: []].append(set)
        }
        return groups.keys.sorted { $0.hoursSinceEpoch < $1.hoursSinceEpoch }
            .reduce(states) { Recovery.applying(groups[$1]!, at: $1, to: $0) }
    }

    /// Пишет состояния утомления: метка — значение шкалы FitCore как есть.
    public static func writeFatigue(_ tx: UserTransaction, userID: UUID,
                                    states: [MuscleSlug: FatigueState]) async throws {
        for (muscle, state) in states.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let seconds = state.updatedAt.hoursSinceEpoch * 3_600
            _ = try await tx.query("""
                insert into muscle_fatigue (user_id, muscle, value, updated_at)
                values (\(userID), \(muscle.rawValue), \(state.value),
                        to_timestamp(\(seconds)) at time zone 'UTC')
                on conflict (user_id, muscle)
                  do update set value = excluded.value, updated_at = excluded.updated_at
                """)
        }
    }
}
