//  `PATCH /v1/week-plans/{week_start}/days/{day_id}`: какие отметки статуса
//  принимает путь (SPEC §20.3).
//
//  `planned` и `skipped` — да; `done` — нет, его ставит только `/finish`
//  вместе с закрытием тренировки; `replaced` — нет, его не производит ни один
//  путь. Отказ проверяется вместе с тем, что строка не изменилась: 422 после
//  уже сделанной записи был бы отказом только на словах.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Testing
import FitAPI
import FitCore
import Vapor
import VaporTesting
@testable import FitServer

@Suite("PATCH …/days: отметка статуса (§20.3)", .enabled(if: Live.enabled), .serialized)
struct LiveDayStatusTests {

    private var today: CalendarDay {
        Mapping.LocalTime.day(of: Date(), in: TimeZone(identifier: "Europe/Moscow")!)
    }
    private var weekStart: String { Mapping.LocalTime.iso(Mapping.LocalTime.mondayOfWeek(today)) }

    private func generatedDay(_ app: Application, _ user: Live.User,
                              logger: Logger) async throws -> String {
        try await Live.seed(app, user, logger: logger, weekdays: [(today.dayNumber + 3) % 7 + 1])
        var dayID: String?
        let generate = GenerateWeekPlanRequest(weekStart: weekStart, day: Live.today)
        try await app.testing().test(.POST, "/v1/week-plans", headers: user.headers,
                                     beforeRequest: { try $0.content.encode(generate) }) { response in
            #expect(response.status == .created, Comment(rawValue: String(buffer: response.body)))
            dayID = try JSONDecoder().decode(WeekPlanResponseDTO.self,
                                             from: Data(buffer: response.body)).plan.days.first?.dayID
        }
        return try #require(dayID)
    }

    private func patch(_ app: Application, _ user: Live.User, dayID: String,
                       status: PlannedDayStatus) async throws -> (Int, Data) {
        var captured: (Int, Data) = (0, Data())
        let body = PatchPlannedDayRequest(status: status, day: Live.today)
        try await app.testing().test(
            .PATCH, "/v1/week-plans/\(weekStart)/days/\(dayID)", headers: user.headers,
            beforeRequest: { try $0.content.encode(body) }
        ) { response in
            captured = (Int(response.status.code), Data(buffer: response.body))
        }
        return captured
    }

    private func storedStatus(_ database: Database, _ user: Live.User,
                              dayID: String) async throws -> String? {
        try await database.withUserTransaction(authorization: "Bearer \(user.token)") { tx in
            let rows = try await tx.query("""
                select status from planned_days where id = \(UUID(uuidString: dayID)!)
                """)
            for try await row in rows { return try row.decode(String.self) }
            return nil
        }
    }

    @Test("done и replaced отклоняются с validation_failed, строка не меняется")
    func doneAndReplacedAreRefused() async throws {
        let user = try await Live.signUpLinked()
        let logger = Live.quietLogger("day.status.refused")
        try await Live.withServer("day.status.refused") { app, database in
            let dayID = try await self.generatedDay(app, user, logger: logger)
            for status in [PlannedDayStatus.done, .replaced] {
                let (code, raw) = try await self.patch(app, user, dayID: dayID, status: status)
                #expect(code == 422, Comment(rawValue: String(decoding: raw, as: UTF8.self)))
                let envelope = try JSONDecoder().decode(APIErrorEnvelope.self, from: raw)
                #expect(envelope.error.code == .validationFailed)
                #expect(envelope.error.details?["field"] == .string("status"))
                #expect(try await self.storedStatus(database, user, dayID: dayID) == "planned",
                        "\(status.rawValue): отказ после записи")
            }
        }
    }

    @Test("skipped и обратно planned принимаются и пишутся")
    func skippedAndPlannedAreAccepted() async throws {
        let user = try await Live.signUpLinked()
        let logger = Live.quietLogger("day.status.accepted")
        try await Live.withServer("day.status.accepted") { app, database in
            let dayID = try await self.generatedDay(app, user, logger: logger)
            let (skipped, raw) = try await self.patch(app, user, dayID: dayID, status: .skipped)
            #expect(skipped == 200, Comment(rawValue: String(decoding: raw, as: UTF8.self)))
            #expect(try await self.storedStatus(database, user, dayID: dayID) == "skipped")
            let (planned, _) = try await self.patch(app, user, dayID: dayID, status: .planned)
            #expect(planned == 200)
            #expect(try await self.storedStatus(database, user, dayID: dayID) == "planned")
        }
    }

    @Test("день done (после /finish) не правится ничем — 409 day_not_planned, строка цела")
    func doneDayIsClosedToPatch() async throws {
        let user = try await Live.signUpLinked()
        let logger = Live.quietLogger("day.status.done")
        try await Live.withServer("day.status.done") { app, database in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            let dayID = try #require(workout.plannedDayID)
            let exercise = try #require(workout.exercises.first)
            let set = LogSetRequest(id: UUID().uuidString, setIndex: 1,
                                    prescribedKg: exercise.prescribedKg,
                                    actualKg: exercise.prescribedKg ?? (exercise.weighted ? 20 : nil),
                                    actualReps: exercise.targetRepMin, feedback: .ok,
                                    completedAt: "2026-10-08T10:00:00Z", day: Live.today)
            try await app.testing().test(
                .POST, "/v1/workouts/\(workout.id)/exercises/\(exercise.id)/sets",
                headers: user.headers, beforeRequest: { try $0.content.encode(set) }
            ) { #expect($0.status == .ok) }
            try await app.testing().test(
                .POST, "/v1/workouts/\(workout.id)/finish", headers: user.headers,
                beforeRequest: { try $0.content.encode(FinishWorkoutRequest(day: Live.today)) }
            ) { #expect($0.status == .ok) }
            // Контроль: день действительно закрыт, иначе отказ ниже ничего не значит.
            #expect(try await self.storedStatus(database, user, dayID: dayID) == "done")

            let bodies: [PatchPlannedDayRequest] = [
                PatchPlannedDayRequest(status: .planned, day: Live.today),
                PatchPlannedDayRequest(status: .skipped, day: Live.today),
                PatchPlannedDayRequest(sessionKind: .upper, day: Live.today),
            ]
            for body in bodies {
                var captured: (Int, Data) = (0, Data())
                try await app.testing().test(
                    .PATCH, "/v1/week-plans/\(self.weekStart)/days/\(dayID)", headers: user.headers,
                    beforeRequest: { try $0.content.encode(body) }
                ) { captured = (Int($0.status.code), Data(buffer: $0.body)) }
                #expect(captured.0 == 409, Comment(rawValue: String(decoding: captured.1, as: UTF8.self)))
                let envelope = try JSONDecoder().decode(APIErrorEnvelope.self, from: captured.1)
                #expect(envelope.error.code == .dayNotPlanned)
                #expect(try await self.storedStatus(database, user, dayID: dayID) == "done",
                        "отказ после записи")
            }
        }
    }
}
