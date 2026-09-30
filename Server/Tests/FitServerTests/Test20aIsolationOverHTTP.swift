//  Тесты 20a, 20d и 20j на недельном блоке (SPEC §20.15).
//
//  Первый прогон эндпоинтов через настоящий HTTP с настоящими JWT против живого
//  Postgres с включённой RLS. До него весь недельный блок был написан и ни разу
//  не выполнен.
//
//  Условия запуска — в `LiveHarness.swift`; без переменных среды набор
//  пропускается, и `swift test` остаётся зелёным без Docker.

import Testing
import Foundation
import FitAPI
import FitCore
import Vapor
import VaporTesting
@testable import FitServer

@Suite("20a/20d/20j: недельный блок через HTTP (§20.15)", .enabled(if: Live.enabled), .serialized)
struct LiveWeekPlanTests {

    /// Понедельник текущей недели по часам машины: §20.3 принимает только
    /// текущую и ближайшую следующую, и фиксированная дата в тесте протухла бы
    /// через неделю.
    private var today: CalendarDay {
        Mapping.LocalTime.day(of: Date(), in: TimeZone(identifier: "Europe/Moscow")!)
    }
    private var weekStart: CalendarDay { Mapping.LocalTime.mondayOfWeek(today) }

    private var day: DayContext {
        DayContext(date: Mapping.LocalTime.iso(today), tz: "Europe/Moscow")
    }

    private func generate(_ app: Application, as user: Live.User,
                          weekStart: CalendarDay? = nil) async throws -> (Int, WeekPlanResponseDTO?) {
        let body = GenerateWeekPlanRequest(
            weekStart: Mapping.LocalTime.iso(weekStart ?? self.weekStart), day: day)
        var captured: (Int, WeekPlanResponseDTO?) = (0, nil)
        try await app.testing().test(.POST, "/v1/week-plans", headers: user.headers,
                                     beforeRequest: { try $0.content.encode(body) }) { response in
            captured = (Int(response.status.code),
                        try? JSONDecoder().decode(WeekPlanResponseDTO.self,
                                                  from: Data(buffer: response.body)))
        }
        return captured
    }

    // MARK: - 20a. Два пользователя, два JWT

    @Test("два пользователя не видят недель друг друга ни на одном недельном пути")
    func test20a_isolation() async throws {
        let alice = try await Live.signUpAnonymous()
        let bob = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("test.20a")
        try await Live.seedProfile(alice, logger: logger)
        try await Live.seedProfile(bob, logger: logger)

        try await Live.withServer("test.20a") { app in
            let (status, plan) = try await self.generate(app, as: alice)
            #expect(status == 201, "Алиса сгенерировала свою неделю")
            let aliceDays = Set((plan?.plan.days ?? []).map(\.dayID))
            #expect(!aliceDays.isEmpty)

            let path = "/v1/week-plans/\(Mapping.LocalTime.iso(self.weekStart))"
                + "?date=\(self.day.date)&tz=Europe%2FMoscow"

            // Своя неделя видна.
            try await app.testing().test(.GET, path, headers: alice.headers) { response in
                #expect(response.status == .ok)
                let body = try JSONDecoder().decode(WeekPlanResponseDTO.self,
                                                    from: Data(buffer: response.body))
                #expect(Set(body.plan.days.map(\.dayID)) == aliceDays)
            }

            // Чужая — нет. Не «пустая неделя», а 404: RLS не отдала строку, и
            // для Боба недели с этим `week_start` не существует.
            try await app.testing().test(.GET, path, headers: bob.headers) { response in
                #expect(response.status == .notFound, "Боб не видит неделю Алисы")
                let envelope = try JSONDecoder().decode(APIErrorEnvelope.self,
                                                        from: Data(buffer: response.body))
                #expect(envelope.error.code == .notFound)
            }

            // И правка чужого дня не проходит: `day_id` настоящий, но чужой.
            let aliceDayID = try #require(aliceDays.first)
            let patch = PatchPlannedDayRequest(accentMuscle: .some(.gluteMax), day: self.day)
            try await app.testing().test(.PATCH, "\(path.split(separator: "?")[0])/days/\(aliceDayID)",
                                         headers: bob.headers,
                                         beforeRequest: { try $0.content.encode(patch) }) { response in
                #expect(response.status == .notFound, "чужой день не правится")
            }

            // Пересборка чужой недели — тоже нет.
            let rebuild = RebuildWeekPlanRequest(cause: .equipmentChanged, day: self.day)
            try await app.testing().test(.POST, "\(path.split(separator: "?")[0])/rebuild",
                                         headers: bob.headers,
                                         beforeRequest: { try $0.content.encode(rebuild) }) { response in
                #expect(response.status == .notFound)
            }

            // Боб генерирует свою — и она своя, не Алисина.
            let (bobStatus, bobPlan) = try await self.generate(app, as: bob)
            #expect(bobStatus == 201)
            let bobDays = Set((bobPlan?.plan.days ?? []).map(\.dayID))
            #expect(bobDays.isDisjoint(with: aliceDays), "ни одного общего дня")
        }
    }

    @Test("без токена недельные пути не отвечают")
    func test20a_noToken() async throws {
        try await Live.withServer("test.20a.anon") { app in
            let path = "/v1/week-plans/\(Mapping.LocalTime.iso(self.weekStart))"
                + "?date=\(self.day.date)&tz=Europe%2FMoscow"
            try await app.testing().test(.GET, path) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    // MARK: - 20d. Суточный допуск даты

    @Test("дата, расходящаяся с серверной больше чем на сутки → 422 (§20.7)")
    func test20d_dateSkew() async throws {
        let user = try await Live.signUpAnonymous()
        try await Live.seedProfile(user, logger: Live.quietLogger("test.20d"))

        try await Live.withServer("test.20d") { app in
            let skewed = DayContext(date: Mapping.LocalTime.iso(self.today.adding(days: 5)),
                                    tz: "Europe/Moscow")
            let body = GenerateWeekPlanRequest(
                weekStart: Mapping.LocalTime.iso(self.weekStart), day: skewed)
            try await app.testing().test(.POST, "/v1/week-plans", headers: user.headers,
                                         beforeRequest: { try $0.content.encode(body) }) { response in
                #expect(response.status == .unprocessableEntity)
                let envelope = try JSONDecoder().decode(APIErrorEnvelope.self,
                                                        from: Data(buffer: response.body))
                #expect(envelope.error.code == .dateSkew)
                #expect(envelope.error.details?["sent"] != nil)
                #expect(envelope.error.details?["server"] != nil)
            }

            // И на GET, где пара едет в query, — тот же отказ.
            let path = "/v1/week-plans/\(Mapping.LocalTime.iso(self.weekStart))"
                + "?date=\(Mapping.LocalTime.iso(self.today.adding(days: -5)))&tz=Europe%2FMoscow"
            try await app.testing().test(.GET, path, headers: user.headers) { response in
                #expect(response.status == .unprocessableEntity)
            }
        }
    }

    @Test("вчера и завтра принимаются: полночь и запись вчерашней тренировки")
    func test20d_toleranceIsADay() async throws {
        let user = try await Live.signUpAnonymous()
        try await Live.seedProfile(user, logger: Live.quietLogger("test.20d.ok"))

        try await Live.withServer("test.20d.ok") { app in
            for offset in [-1, 0, 1] {
                let context = DayContext(date: Mapping.LocalTime.iso(self.today.adding(days: offset)),
                                         tz: "Europe/Moscow")
                let body = GenerateWeekPlanRequest(
                    weekStart: Mapping.LocalTime.iso(self.weekStart), day: context)
                try await app.testing().test(.POST, "/v1/week-plans", headers: user.headers,
                                             beforeRequest: { try $0.content.encode(body) }) { response in
                    #expect(response.status != .unprocessableEntity,
                            "смещение \(offset) укладывается в сутки")
                }
            }
        }
    }

    // MARK: - 20j. Идемпотентность генерации

    @Test("повторный POST не создаёт второй недели и не перегенерирует первую")
    func test20j_idempotent() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("test.20j")
        try await Live.seedProfile(user, logger: logger)

        try await Live.withServer("test.20j") { app in
            let (firstStatus, first) = try await self.generate(app, as: user)
            #expect(firstStatus == 201)
            let firstDays = try #require(first?.plan.days)

            let (secondStatus, second) = try await self.generate(app, as: user)
            #expect(secondStatus == 200, "повтор — не создание")
            let secondDays = try #require(second?.plan.days)

            #expect(secondDays.map(\.dayID) == firstDays.map(\.dayID), "те же дни")
            #expect(secondDays.map(\.kind) == firstDays.map(\.kind), "те же типы")
            #expect(secondDays.map { $0.session?.exercises.map(\.slug) }
                    == firstDays.map { $0.session?.exercises.map(\.slug) }, "тот же состав")
            #expect(secondDays.map { $0.session?.exercises.map(\.targetSets) }
                    == firstDays.map { $0.session?.exercises.map(\.targetSets) }, "тот же объём")
        }
    }

    @Test("прошлая неделя не генерируется вовсе (§20.3)")
    func test20j_pastWeekRejected() async throws {
        let user = try await Live.signUpAnonymous()
        try await Live.seedProfile(user, logger: Live.quietLogger("test.20j.past"))

        try await Live.withServer("test.20j.past") { app in
            let (status, _) = try await self.generate(app, as: user,
                                                      weekStart: self.weekStart.adding(days: -7))
            #expect(status == 422, "прошлая неделя отклоняется")

            let (far, _) = try await self.generate(app, as: user,
                                                   weekStart: self.weekStart.adding(days: 21))
            #expect(far == 422, "дальняя тоже: набор дней ещё может смениться")
        }
    }

    @Test("ближайшая следующая неделя генерируется")
    func test20j_nextWeekAllowed() async throws {
        let user = try await Live.signUpAnonymous()
        try await Live.seedProfile(user, logger: Live.quietLogger("test.20j.next"))

        try await Live.withServer("test.20j.next") { app in
            let (status, _) = try await self.generate(app, as: user,
                                                      weekStart: self.weekStart.adding(days: 7))
            #expect(status == 201)
        }
    }
}
