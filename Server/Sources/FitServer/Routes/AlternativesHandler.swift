//  `GET /v1/workouts/{id}/exercises/{we_id}/alternatives` — замена в один тап и
//  альтернативы по флагу боли (SPEC §8.4 п.2, §13.4, §20.3).
//
//  Путь читающий и ничего не пишет. Сама замена — `/substitute`, отдельный путь.
//
//  ── Что откуда берётся ────────────────────────────────────────────────────
//
//  * День — из `date`/`tz` запроса, обязательных, как у `/v1/today` (§20.3):
//    на нём считаются 14-дневное окно боли и ограничения профиля. `started_at`
//    тренировки его не заменяет — зону сервер не хранит (§20.7).
//  * Инвентарь — ТРЕНИРОВКИ (`workouts.equipment_profile_id`), как у дерева:
//    выбор профиля принадлежит моменту, а не аккаунту (§20.3).
//  * `SafetyProfile` — тем же `Mapping.readSafety`, что и на старте тренировки.
//  * Суставы при `purpose=pain` — из `sets.pain_joints` последнего подхода с
//    флагом боли на ЭТОМ упражнении (§20.3), клиент их не присылает. Флага нет —
//    `pain` вырождается в `user_choice`.
//
//  ── Отказы ────────────────────────────────────────────────────────────────
//
//  Нет такой тренировки или такого упражнения в ней — `not_found`, как у
//  `GET /v1/workouts/{id}`: путь читающий, и «не начата» ему сказать нечего.
//  Завершённая тренировка не отказ — список ничего не меняет. Слаг, которого
//  нет в срезе контента (разметка уехала), даёт пустой список, а не 500.

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

    static func alternatives(_ request: Request, database: Database,
                             library: ContentLibrary) async throws -> Response {
        let input = RawInput(request)
        let rawWorkout = request.parameters.get("id")
        let rawExercise = request.parameters.get("we_id")
        return try await database.withUserTransaction(authorization: input.authorization) { tx in
            let workoutID = try WeekPlanRoutes.uuid(rawWorkout, "id")
            let exerciseID = try WeekPlanRoutes.uuid(rawExercise, "we_id")
            let day = try RequestDay.fromQuery(request)
            let askedPurpose: String? = request.query["purpose"]
            guard askedPurpose == nil || askedPurpose == "user_choice" || askedPurpose == "pain" else {
                throw APIError(.validationFailed, details: ["field": .string("purpose")])
            }

            guard let workout = try await Mapping.readWorkout(tx, id: workoutID) else {
                throw APIError(.notFound, details: ["id": .string(workoutID.uuidString)])
            }
            guard let location = try await Mapping.readWorkoutExercise(tx, id: exerciseID),
                  location.workoutID == workout.id
            else { throw APIError(.notFound, details: ["we_id": .string(exerciseID.uuidString)]) }

            let profile = try await Mapping.readProfile(tx)
            guard let complete = profile.complete else {
                throw APIError(.profileIncomplete, details: [
                    "missing": .string(Mapping.missingProfileFields(profile).joined(separator: ","))
                ])
            }
            let equipment = try await Mapping.readEquipment(
                tx, id: workout.equipmentProfileID.flatMap(UUID.init(uuidString:)))
            let safety = try await Mapping.readSafety(tx, level: complete.level,
                                                      timeZone: day.timeZone)

            guard let exercise = library.candidates.first(where: { $0.slug == location.row.slug })
            else { return try WeekPlanRoutes.json([ExerciseAlternativeDTO]()) }

            var purpose = SubstitutionPurpose.userChoice
            if askedPurpose == "pain" {
                let sets = try await Mapping.readWorkoutSets(tx, workoutID: workoutID)
                let flagged = (sets.body[location.row.id] ?? [])
                    .filter(\.painFlag).max { $0.setIndex < $1.setIndex }
                if let joints = flagged?.painJoints, !joints.isEmpty {
                    purpose = .pain(joints: Set(joints))
                }
            }

            let found = Planner.alternatives(
                to: exercise, purpose: purpose, library: library.candidates, safety: safety,
                availability: equipment.availability, equipment: equipment.profile, on: day.date)
            return try WeekPlanRoutes.json(found.map(ExerciseAlternativeDTO.init))
        }
    }
}
