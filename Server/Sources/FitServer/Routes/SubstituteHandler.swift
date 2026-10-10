//  `POST /v1/workouts/{id}/exercises/{we_id}/substitute` — замена упражнения
//  (SPEC §8.4 п.2, §13.4, §20.3).
//
//  ── Порядок ───────────────────────────────────────────────────────────────
//
//    1. Адресация по словарю кодов: нет тренировки — `workout_not_started`,
//       закрыта — `workout_finished`, `we_id` не из неё — `not_found`.
//    2. Повтор: текущий слаг уже `to_slug`, а `substituted_from` заполнен —
//       200 и то же упражнение (§20.3), ничего не пересчитывая.
//    3. Допуск `to_slug`: тот же `Planner.alternatives`, что у
//       `/alternatives`, без ограничения тройкой (§20.3). При `reason = pain`
//       — `purpose = pain` с суставами последнего подхода с флагом боли
//       ЭТОГО упражнения; флага нет — вырождается в `user_choice`, как там.
//    4. Состояние нового упражнения: своё (свёртка журнала) — оно; своего нет
//       и перенос §13.4 определён — подставленное В ПАМЯТИ с перенесённой
//       базовой линией и `last_performed_at` заменённого; иначе — нет
//       состояния, калибровка. В `exercise_states` перенос не пишется (§20.3).
//    5. Числа — `Planner.prescribe` на момент замены, диапазон —
//       `Planner.sessionRepRange` (состояние сессии, §9.7).
//    6. Запись строки и строки `exercise_states` нового слага (её требует
//       запись подхода), ответ — упражнение из того же `body`, что у чтения.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import FitAPI
import FitContent
import FitCore
import Vapor

extension WorkoutRoutes {

    static func substitute(_ request: Request, database: Database,
                           library: ContentLibrary) async throws -> Response {
        let input = RawInput(request)
        let rawWorkout = request.parameters.get("id")
        let rawExercise = request.parameters.get("we_id")
        return try await database.withUserTransaction(authorization: input.authorization) { tx in
            let workoutID = try WeekPlanRoutes.uuid(rawWorkout, "id")
            let exerciseID = try WeekPlanRoutes.uuid(rawExercise, "we_id")
            let sent = try input.decode(SubstituteExerciseRequest.self)
            let day = try RequestDay.validated(date: sent.date, tz: sent.tz)

            guard let workout = try await Mapping.readWorkout(tx, id: workoutID) else {
                throw APIError(.workoutNotStarted, details: ["id": .string(workoutID.uuidString)])
            }
            guard workout.finishedAt == nil else {
                throw APIError(.workoutFinished, details: ["id": .string(workoutID.uuidString)])
            }
            guard let location = try await Mapping.readWorkoutExercise(tx, id: exerciseID),
                  location.workoutID == workout.id
            else { throw APIError(.notFound, details: ["we_id": .string(exerciseID.uuidString)]) }
            let row = location.row

            if row.slug == sent.toSlug, row.substitutedFrom != nil {
                return try WeekPlanRoutes.json(
                    try await exerciseBody(tx, workout: workout, id: row.id, library: library))
            }

            let refuse = APIError(.validationFailed, details: ["field": .string("to_slug")])
            let bySlug = Dictionary(library.candidates.map { ($0.slug, $0) },
                                    uniquingKeysWith: { first, _ in first })
            guard let old = bySlug[row.slug], let new = bySlug[sent.toSlug] else { throw refuse }

            // День плана: `prescribe` сверяет сессию с ним. Тренировка без дня
            // (день удалён, `on delete set null`) предписать нечем.
            guard let plannedDayID = workout.plannedDayID.flatMap(UUID.init(uuidString:)),
                  let dayLocation = try await Mapping.readPlannedDay(tx, id: plannedDayID),
                  let plannedDay = Mapping.plannedDays(
                      from: try await Mapping.readPlannedDays(tx, weekPlanID: dayLocation.weekPlanID),
                      vectors: library.vectors).first(where: { $0.id == dayLocation.day.id })
            else {
                throw APIError(.dayNotPlanned, details: ["workout_id": .string(workout.id)])
            }

            let inputs = try await WeekPlanRoutes.inputs(tx, on: day)
            let equipment = try await Mapping.readEquipment(
                tx, id: workout.equipmentProfileID.flatMap(UUID.init(uuidString:)))

            var purpose = SubstitutionPurpose.userChoice
            if sent.reason == .pain {
                let sets = try await Mapping.readWorkoutSets(tx, workoutID: workoutID)
                let pairs = zip(sets.body[row.id] ?? [], sets.journal[row.id] ?? [])
                let flagged = pairs.filter { $0.1.exerciseSlug == row.slug && $0.0.painFlag }
                    .max { $0.0.setIndex < $1.0.setIndex }
                if let joints = flagged?.0.painJoints, !joints.isEmpty {
                    purpose = .pain(joints: Set(joints))
                }
            }
            let admitted = Planner.alternatives(
                to: old, purpose: purpose, library: library.candidates, safety: inputs.safety,
                availability: equipment.availability, equipment: equipment.profile,
                on: day.date, limit: .max)
            guard admitted.contains(where: { $0.slug == new.slug }) else { throw refuse }

            var prescription = Mapping.prescriptionInput(
                day: plannedDay, startMoment: day.now, library: library.candidates,
                profile: inputs.complete, equipment: equipment, safety: inputs.safety,
                cycle: inputs.cycle, checkin: inputs.checkin, override: inputs.override,
                fatigue: inputs.fatigue, journal: inputs.journal)
            let ladder = WeightLadder.build(loadType: new.loadType, profile: equipment.profile)
            let isCalibration: Bool
            if prescription.exerciseStates[new.slug] == nil,
               let oldState = prescription.exerciseStates[old.slug],
               let transferred = Planner.transferredBaseline(from: old, to: new,
                                                             baselineKg: oldState.baselineKg,
                                                             ladder: ladder) {
                prescription.exerciseStates[new.slug] = ExerciseState(
                    baselineKg: transferred, lastPerformedAt: oldState.lastPerformedAt,
                    isInCalibration: false)
                isCalibration = false
            } else {
                isCalibration = try await Mapping.readCalibrationFlags(tx)[new.slug] ?? true
            }

            let range = Planner.sessionRepRange(goal: inputs.complete.goal,
                                                state: prescription.exerciseStates[new.slug],
                                                ladder: ladder, on: plannedDay.date)
            let draft = PrescribedExercise(
                slug: new.slug, orderIndex: row.orderIndex, targetSets: row.targetSets,
                targetRepMin: range.lowerBound, targetRepMax: range.upperBound,
                targetRIR: row.targetRIR, prescribedKg: nil, weightReadiness: 1.0)
            let session = BuiltSession(dayID: plannedDay.id, exercises: [draft], estimatedSeconds: 0,
                                       effectiveVolume: [:], leadingMuscle: nil, scale: 1, reasons: [])
            guard let prescribed = Planner.prescribe(session, on: prescription)?.exercises.first else {
                throw APIError(.internal)
            }

            guard let userID = UUID(uuidString: tx.token.subject) else { throw APIError(.internal) }
            try await Mapping.substituteExercise(tx, id: exerciseID, to: prescribed,
                                                 isCalibration: isCalibration, from: row.slug,
                                                 reason: sent.reason.rawValue)
            try await Mapping.writeSessionRepRanges(
                tx, userID: userID, ranges: [new.slug: prescribed.targetRepMin...prescribed.targetRepMax])

            return try WeekPlanRoutes.json(
                try await exerciseBody(tx, workout: workout, id: row.id, library: library))
        }
    }

    /// Одно упражнение из того же `body`, что у чтения тренировки: две сборки
    /// одного `WorkoutExerciseDTO` разъехались бы полем.
    static func exerciseBody(_ tx: UserTransaction, workout: Mapping.WorkoutRow, id: String,
                             library: ContentLibrary) async throws -> WorkoutExerciseDTO {
        guard let exercise = try await body(tx, workout: workout, library: library)
            .exercises.first(where: { $0.id == id })
        else { throw APIError(.internal) }
        return exercise
    }
}
