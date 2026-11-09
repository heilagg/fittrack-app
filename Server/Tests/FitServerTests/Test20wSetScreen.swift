//  20w. Подход с экрана без счётчика повторов (SPEC §13.2, §20.9, 2026-11-09).
//
//  Контракт `POST …/sets` не менялся, и тест держит именно это: подход уходит
//  ОДИН раз — после оценки, с `completed_at` момента «Подход выполнен», то есть
//  раньше самого запроса, и с `actual_reps`, равными цели или ответу на «Сколько
//  повторов получилось?». Строка рождается с оценкой и повторами, и сверяется
//  она против `sets`, прочитанных транзакцией пользовательницы.

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

@Suite("20w: подход с экрана без счётчика повторов (§13.2, §20.9)", .enabled(if: Live.enabled), .serialized)
struct Test20wSetScreen {

    private func post(_ app: Application, _ user: Live.User, workout: String, exercise: String,
                      _ body: LogSetRequest) async throws -> (Int, Data) {
        var captured: (Int, Data) = (0, Data())
        try await app.testing().test(.POST, "/v1/workouts/\(workout)/exercises/\(exercise)/sets",
                                     headers: user.headers, beforeRequest: { try $0.content.encode(body) }) { response in
            captured = (Int(response.status.code), Data(buffer: response.body))
        }
        return captured
    }

    @Test("20w: оценка с целью и «Не смог» с ответом — один запрос каждый, completed_at — момент «Подход выполнен»")
    func ratedSetsKeepTheContract() async throws {
        let user = try await Live.signUpLinked()
        let logger = Live.quietLogger("20w")
        try await Live.withServer("20w") { app, database in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            let exercise = try #require(workout.exercises.first)
            let kg = exercise.prescribedKg ?? (exercise.weighted ? 20 : nil)
            let formatter = ISO8601DateFormatter()
            // «Подход выполнен» нажата за полторы минуты до оценки.
            let doneAt = formatter.string(from: Date().addingTimeInterval(-90))

            let ok = LogSetRequest(id: UUID().uuidString, setIndex: 1, prescribedKg: kg, actualKg: kg,
                                   actualReps: exercise.targetRepMax, feedback: .ok, completedAt: doneAt,
                                   day: Live.today)
            let (okStatus, okRaw) = try await self.post(app, user, workout: workout.id, exercise: exercise.id, ok)
            #expect(okStatus == 200, Comment(rawValue: String(decoding: okRaw, as: UTF8.self)))
            let afterOk = try JSONDecoder().decode(LogSetResponseDTO.self, from: okRaw)
            #expect(afterOk.set.actualReps == exercise.targetRepMax)
            #expect(afterOk.set.completedAt.map { formatter.date(from: $0) } == formatter.date(from: doneAt),
                    "completed_at — присланный момент, а не время запроса")

            let failed = LogSetRequest(id: UUID().uuidString, setIndex: 2, prescribedKg: kg, actualKg: kg,
                                       actualReps: 3, feedback: .failed, completedAt: doneAt, day: Live.today)
            let (failedStatus, failedRaw) = try await self.post(app, user, workout: workout.id,
                                                                exercise: exercise.id, failed)
            #expect(failedStatus == 200, Comment(rawValue: String(decoding: failedRaw, as: UTF8.self)))
            let afterFailed = try JSONDecoder().decode(LogSetResponseDTO.self, from: failedRaw)
            #expect(afterFailed.set.actualReps == 3, "ответ на вопрос уходит в журнал")
            // Ветка `failed` повторов не читает: второй «не смог» подряд завершает упражнение.
            let root = try #require(afterFailed.decisionTree.nodes[afterFailed.decisionTree.start])
            let next = try #require(root.transitions[TreeBranch.failed.rawValue])
            #expect(afterFailed.decisionTree.nodes[next]?.terminates == true)

            let rows = try await database.withUserTransaction(authorization: "Bearer \(user.token)") { tx in
                var out: [String] = []
                for try await row in try await tx.query("""
                    select concat_ws('|', set_index, feedback, actual_reps) from sets order by set_index
                    """) { out.append(try row.decode(String.self)) }
                return out
            }
            #expect(rows == ["1|ok|\(exercise.targetRepMax)", "2|failed|3"], "по строке на подход, с оценкой сразу")
        }
    }
}
