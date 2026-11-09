//  `POST /v1/workouts/{id}/finish` — закрытие тренировки (SPEC §7.1, §8.1,
//  §20.3, §20.6).
//
//  ── Порядок несущий ───────────────────────────────────────────────────────
//
//    1. Условное закрытие (`Mapping.closeWorkout`). Только переход
//       `finished_at: null → значение` пересчитывает производные: повтор
//       `/finish` (§20.3) отвечает тем же телом и ничего не применяет второй
//       раз.
//    2. На переходе — отметка дня плана (`done`, либо `skipped`, если не
//       выполнено ни одного подхода, §7.1) и утомление §8.1 по моменту каждого
//       подхода. ДО сборки недели: она читает и статус, и утомление.
//    3. Неделя — дня этой тренировки, без дня — по `date` запроса; нет недели —
//       `week: null`, `/finish` её не генерирует (§20.3).
//    4. На переходе — `rebuildNotice` против снимка, потом запись снимка
//       (§20.6: сначала сравнить, потом перезаписать). На повторе снимок НЕ
//       трогается и `notice` равен `null`: перезапись без сравнения проглотила
//       бы изменение, случившееся между двумя вызовами, а следующее чтение
//       недели честно его покажет.

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

    static func finish(_ request: Request, database: Database,
                       library: ContentLibrary) async throws -> Response {
        let input = RawInput(request)
        let rawID = request.parameters.get("id")
        return try await database.withUserTransaction(authorization: input.authorization) { tx in
            let workoutID = try WeekPlanRoutes.uuid(rawID, "id")
            let sent = try input.decode(FinishWorkoutRequest.self)
            let day = try RequestDay.validated(date: sent.date, tz: sent.tz)

            // Запись в тренировку, которой нет, — `workout_not_started` по
            // словарю кодов (§20.3), а не `not_found`: путь пишущий.
            guard try await Mapping.readWorkout(tx, id: workoutID) != nil else {
                throw APIError(.workoutNotStarted, details: ["id": .string(workoutID.uuidString)])
            }
            let closedNow = try await Mapping.closeWorkout(tx, id: workoutID)
            guard let workout = try await Mapping.readWorkout(tx, id: workoutID) else {
                throw APIError(.internal)
            }
            var location: Mapping.PlannedDayLocation?
            if let dayID = workout.plannedDayID.flatMap(UUID.init(uuidString:)) {
                location = try await Mapping.readPlannedDay(tx, id: dayID)
            }

            var cause = RebuildCause.workoutCompleted
            if closedNow {
                guard let userID = UUID(uuidString: tx.token.subject) else { throw APIError(.internal) }
                let journal = try await Mapping.readWorkoutSets(tx, workoutID: workoutID).journal
                let outcome = Mapping.finishOutcome(Array(journal.values.joined()))
                cause = outcome.cause
                if let location {
                    try await Mapping.updatePlannedDay(
                        tx, dayID: try WeekPlanRoutes.uuid(location.day.id, "planned_day_id"),
                        accent: nil, kind: nil, status: outcome.status)
                }

                let timed = try await Mapping.readTimedSets(tx, workoutID: workoutID,
                                                           timeZone: day.timeZone)
                let before = try await Mapping.readFatigue(tx)
                let after = Mapping.fatigue(after: timed, library: library.candidates, from: before)
                try await Mapping.writeFatigue(tx, userID: userID,
                                               states: after.filter { before[$0.key] != $0.value })
            }

            let weekStart = location?.weekStart ?? Mapping.LocalTime.mondayOfWeek(day.date)
            var week: WeekPlanResponseDTO?
            if let loaded = try await WeekPlanRoutes.loadWeek(tx, weekStart: weekStart) {
                let inputs = try await WeekPlanRoutes.inputs(tx, on: day)
                let context = WeekPlanRoutes.context(
                    inputs, weekStart: weekStart, today: day.date, days: loaded.days,
                    isDeload: loaded.isDeload, library: library,
                    userSeed: Mapping.userSeed(canonicalUUID: tx.token.subject))
                if closedNow {
                    let (plan, notice) = try await WeekPlanRoutes.planAndNotice(
                        tx, weekPlanID: loaded.id, context: context, cause: cause)
                    week = WeekPlanRoutes.response(plan, week: context.week, notice: notice, workoutDays: inputs.workoutDays)
                } else {
                    week = WeekPlanRoutes.response(Planner.planRemainingDays(context), week: context.week,
                                                   notice: nil, workoutDays: inputs.workoutDays)
                }
            }

            // Автозаминка (§12.2) — из выполненных подходов этой тренировки и
            // активных ограничений; считается на каждом ответе, поэтому повтор
            // `/finish` отдаёт ту же заминку.
            var setsBySlug: [String: Int] = [:]
            for set in try await Mapping.readWorkoutSets(tx, workoutID: workoutID).journal.values.joined()
            where set.isPerformed {
                setsBySlug[set.exerciseSlug, default: 0] += 1
            }
            let cooldown = Stretching.cooldown(
                setsBySlug: setsBySlug,
                library: Dictionary(uniqueKeysWithValues: library.candidates.map { ($0.slug, $0) }),
                poses: library.poses.map(\.stretchPose),
                restrictions: try await Mapping.readActiveRestrictions(tx))

            let dto = FinishWorkoutResponseDTO(
                workout: try await body(tx, workout: workout, library: library), week: week,
                cooldown: cooldown.map(CooldownPoseDTO.init))
            return try WeekPlanRoutes.json(dto)
        }
    }
}
