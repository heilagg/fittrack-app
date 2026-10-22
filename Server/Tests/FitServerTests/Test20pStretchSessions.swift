//  20p. Сессии растяжки через HTTP (SPEC §12.2, §20.3, §20.15).
//
//  Утверждения ставятся на строки `stretch_sessions`, прочитанные транзакцией
//  пользовательницы (RLS §3.2), а не только на тело ответа: идемпотентность,
//  которую проверяет второй ответ того же сервера, проверяет сама себя.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Testing
import FitAPI
import FitContent
import FitCore
import Vapor
import VaporTesting
@testable import FitServer

@Suite("20p: сессии растяжки (§12.2, §20.3)", .enabled(if: Live.enabled), .serialized)
struct Test20pStretchSessions {

    private func start(_ app: Application, _ user: Live.User, id: String, kind: String = "standalone",
                       template: String? = "hip_opening", day: DayContext = Live.today) async throws -> (Int, Data) {
        var captured: (Int, Data) = (0, Data())
        let body = StartStretchSessionRequest(id: id, kind: kind, templateSlug: template, day: day)
        try await app.testing().test(.POST, "/v1/stretch-sessions", headers: user.headers,
                                     beforeRequest: { try $0.content.encode(body) }) { response in
            captured = (Int(response.status.code), Data(buffer: response.body))
        }
        return captured
    }

    private func finish(_ app: Application, _ user: Live.User, id: String) async throws -> (Int, Data) {
        var captured: (Int, Data) = (0, Data())
        try await app.testing().test(.POST, "/v1/stretch-sessions/\(id)/finish", headers: user.headers,
                                     beforeRequest: { try $0.content.encode(FinishStretchSessionRequest(day: Live.today)) }
        ) { response in
            captured = (Int(response.status.code), Data(buffer: response.body))
        }
        return captured
    }

    private func history(_ app: Application, _ user: Live.User) async throws -> StretchHistoryDTO {
        var dto: StretchHistoryDTO?
        try await app.testing().test(.GET, "/v1/stretch-sessions?date=\(Live.today.date)&tz=Europe%2FMoscow",
                                     headers: user.headers) { response in
            #expect(response.status == .ok, Comment(rawValue: String(buffer: response.body)))
            dto = try JSONDecoder().decode(StretchHistoryDTO.self, from: Data(buffer: response.body))
        }
        return try #require(dto)
    }

    private func rowCount(_ database: Database, _ user: Live.User) async throws -> Int {
        try await database.withUserTransaction(authorization: "Bearer \(user.token)") { tx in
            for try await row in try await tx.query("select count(*)::int from stretch_sessions") {
                return try row.decode(Int.self)
            }
            return 0
        }
    }

    @Test("20p: повтор старта — та же строка; finish идемпотентен; день — присланный")
    func startFinishIdempotent() async throws {
        let user = try await Live.signUpAnonymous()
        try await Live.withServer("20p.idempotent") { app, database in
            try await Live.seedProfile(app, user)
            let id = UUID().uuidString
            let first = try await self.start(app, user, id: id)
            #expect(first.0 == 201, Comment(rawValue: String(decoding: first.1, as: UTF8.self)))
            let session = try JSONDecoder().decode(StretchSessionDTO.self, from: first.1)
            #expect(session.performedOn == Live.today.date)
            #expect(session.finishedAt == nil && session.durationSeconds == nil)
            #expect(session.templateSlug == "hip_opening")

            // Повтор с тем же id, даже с другим шаблоном, — та же строка.
            let again = try await self.start(app, user, id: id, template: "full_stretch")
            #expect(again.0 == 200)
            #expect(try JSONDecoder().decode(StretchSessionDTO.self, from: again.1) == session)
            #expect(try await self.rowCount(database, user) == 1)

            let done = try await self.finish(app, user, id: id)
            #expect(done.0 == 200)
            let finished = try JSONDecoder().decode(StretchSessionDTO.self, from: done.1)
            #expect(finished.finishedAt != nil && finished.durationSeconds != nil)
            // Метка — с точностью до секунды: пауза больше секунды, иначе
            // сдвинутый finished_at неотличим от прежнего.
            try await Task.sleep(nanoseconds: 1_200_000_000)
            let repeated = try await self.finish(app, user, id: id)
            #expect(try JSONDecoder().decode(StretchSessionDTO.self, from: repeated.1) == finished,
                    "повтор finish не сдвигает finished_at")
        }
    }

    @Test("20p: история — только завершённые; заминка без шаблона; предложенный шаблон есть")
    func historyShowsFinishedOnly() async throws {
        let user = try await Live.signUpAnonymous()
        try await Live.withServer("20p.history") { app in
            try await Live.seedProfile(app, user)
            let finishedID = UUID().uuidString
            _ = try await self.start(app, user, id: finishedID)
            _ = try await self.finish(app, user, id: finishedID)
            let cooldownID = UUID().uuidString
            let cooldown = try await self.start(app, user, id: cooldownID, kind: "static_cooldown", template: nil)
            #expect(cooldown.0 == 201, Comment(rawValue: String(decoding: cooldown.1, as: UTF8.self)))
            _ = try await self.start(app, user, id: UUID().uuidString)  // начатая и брошенная

            let body = try await self.history(app, user)
            #expect(body.sessions.map(\.id).map { $0.lowercased() } == [finishedID.lowercased()])
            #expect(SuggestedTemplate(rawValue: body.suggestedTemplate) == .morningMobility,
                    "профиля и силовых нет — утренняя мобильность (§12.2)")
        }
    }

    @Test("20p: неверное тело — validation_failed")
    func invalidBodies() async throws {
        let user = try await Live.signUpAnonymous()
        try await Live.withServer("20p.invalid") { app in
            try await Live.seedProfile(app, user)
            for (kind, template) in [("standalone", nil), ("standalone", "nope"),
                                     ("static_cooldown", "hip_opening"), ("mobility_warmup", nil)] as [(String, String?)] {
                let result = try await self.start(app, user, id: UUID().uuidString, kind: kind, template: template)
                #expect(result.0 == 422, "\(kind) \(template ?? "nil")")
                #expect(String(decoding: result.1, as: UTF8.self).contains("validation_failed"))
            }
        }
    }

    /// Старт допуска не имеет (§20.3), поэтому «другой день» даёт не дата, а
    /// зона: из двух крайних зон в любой момент хотя бы в одной местная дата не
    /// совпадает с датой UTC (Киритимати +14 — с 10:00 UTC, Паго-Паго −11 — до
    /// 11:00 UTC), и проверка не зависит от часа прогона.
    @Test("20p: performed_on — присланный день, а не день базы (§20.7)")
    func performedOnIsTheSentDay() async throws {
        let user = try await Live.signUpAnonymous()
        try await Live.withServer("20p.day") { app in
            try await Live.seedProfile(app, user)
            let now = Date()
            let utc = Mapping.LocalTime.day(of: now, in: TimeZone(identifier: "UTC")!)
            let zone = try #require(["Pacific/Kiritimati", "Pacific/Pago_Pago"]
                .compactMap(TimeZone.init(identifier:))
                .first { Mapping.LocalTime.day(of: now, in: $0) != utc })
            let local = Mapping.LocalTime.iso(Mapping.LocalTime.day(of: now, in: zone))
            let result = try await self.start(app, user, id: UUID().uuidString,
                                              day: DayContext(date: local, tz: zone.identifier))
            #expect(result.0 == 201, Comment(rawValue: String(decoding: result.1, as: UTF8.self)))
            let performed = try JSONDecoder().decode(StretchSessionDTO.self, from: result.1).performedOn
            #expect(performed == local)
            #expect(performed != Mapping.LocalTime.iso(utc), "день базы (UTC) совпал бы и с ошибочной реализацией")
        }
    }

    @Test("заминка соблюдает ограничения §14.4: avoid по всем суставам — только позы без нагрузки")
    func cooldownRespectsRestrictions() async throws {
        let user = try await Live.signUpLinked()
        let logger = Live.quietLogger("20p.restrict")
        try await Live.withServer("20p.restrict") { app, database in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            try await database.withUserTransaction(authorization: "Bearer \(user.token)") { tx -> Void in
                for joint in Joint.allCases {
                    _ = try await tx.query("""
                        insert into user_restrictions (id, user_id, joint, severity)
                        values (\(UUID()), \(user.id), \(joint.rawValue), 'avoid')
                        """)
                }
            }
            for exercise in workout.exercises {
                let body = LogSetRequest(id: UUID().uuidString, setIndex: 1, prescribedKg: exercise.prescribedKg,
                                         actualKg: exercise.prescribedKg, actualReps: exercise.targetRepMin,
                                         feedback: .ok, completedAt: ISO8601DateFormatter().string(from: Date()),
                                         day: Live.today)
                try await app.testing().test(.POST, "/v1/workouts/\(workout.id)/exercises/\(exercise.id)/sets",
                                             headers: user.headers, beforeRequest: { try $0.content.encode(body) }) { _ in }
            }
            var dto: FinishWorkoutResponseDTO?
            try await app.testing().test(.POST, "/v1/workouts/\(workout.id)/finish", headers: user.headers,
                                         beforeRequest: { try $0.content.encode(FinishWorkoutRequest(day: Live.today)) }) { response in
                dto = try JSONDecoder().decode(FinishWorkoutResponseDTO.self, from: Data(buffer: response.body))
            }
            let library = try Content.loadBundled()
            for pose in try #require(dto).cooldown {
                let stress = library.poseBySlug[pose.pose]?.jointStress ?? [:]
                #expect(stress.values.allSatisfy { $0 < .medium }, "\(pose.pose): \(stress)")
            }
        }
    }

    @Test("20p: без строки профиля — profile_incomplete, а не internal")
    func noProfileRow() async throws {
        let user = try await Live.signUpAnonymous()
        try await Live.withServer("20p.noprofile") { app in
            let result = try await self.start(app, user, id: UUID().uuidString)
            #expect(result.0 == 409, Comment(rawValue: String(decoding: result.1, as: UTF8.self)))
            #expect(String(decoding: result.1, as: UTF8.self).contains("profile_incomplete"))
        }
    }

    @Test("20p (20a): чужая сессия недоступна — ни старт с её id, ни finish, ни история")
    func isolation() async throws {
        let alice = try await Live.signUpAnonymous()
        let bob = try await Live.signUpAnonymous()
        try await Live.withServer("20p.isolation") { app in
            try await Live.seedProfile(app, alice)
            try await Live.seedProfile(app, bob)
            let id = UUID().uuidString
            _ = try await self.start(app, alice, id: id)
            _ = try await self.finish(app, alice, id: id)

            let steal = try await self.start(app, bob, id: id)
            #expect(steal.0 == 403, Comment(rawValue: String(decoding: steal.1, as: UTF8.self)))
            #expect(try await self.finish(app, bob, id: id).0 == 404)
            #expect(try await self.history(app, bob).sessions.isEmpty)
            #expect(try await self.history(app, alice).sessions.count == 1)
        }
    }

    @Test("заминка в ответе /finish: массив, и повтор отдаёт ту же (§12.2)")
    func finishCarriesCooldown() async throws {
        let user = try await Live.signUpLinked()
        let logger = Live.quietLogger("20p.cooldown")
        try await Live.withServer("20p.cooldown") { app in
            let workout = try await Live.startedWorkout(app, user, logger: logger)
            for exercise in workout.exercises {
                let body = LogSetRequest(id: UUID().uuidString, setIndex: 1, prescribedKg: exercise.prescribedKg,
                                         actualKg: exercise.prescribedKg, actualReps: exercise.targetRepMin,
                                         feedback: .ok, completedAt: ISO8601DateFormatter().string(from: Date()),
                                         day: Live.today)
                try await app.testing().test(.POST, "/v1/workouts/\(workout.id)/exercises/\(exercise.id)/sets",
                                             headers: user.headers, beforeRequest: { try $0.content.encode(body) }) { _ in }
            }
            var bodies: [FinishWorkoutResponseDTO] = []
            for _ in 0..<2 {
                try await app.testing().test(.POST, "/v1/workouts/\(workout.id)/finish", headers: user.headers,
                                             beforeRequest: { try $0.content.encode(FinishWorkoutRequest(day: Live.today)) }
                ) { response in
                    #expect(response.status == .ok, Comment(rawValue: String(buffer: response.body)))
                    bodies.append(try JSONDecoder().decode(FinishWorkoutResponseDTO.self, from: Data(buffer: response.body)))
                }
            }
            #expect(bodies.count == 2)
            #expect(bodies[0].cooldown == bodies[1].cooldown)
            #expect(bodies[0].cooldown.count <= Stretching.cooldownMaxPoses)
            let library = try Content.loadBundled()
            for pose in bodies[0].cooldown {
                #expect(library.poseBySlug[pose.pose]?.kind == .static, "\(pose.pose) — статическая поза")
            }
        }
    }
}
