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

    /// Пара (`week_start`, дата) для проверки допуска в сутки: дата смещена на
    /// `offset`, а понедельник берётся ОТ ЭТОЙ даты. Вынесено, чтобы согласованность
    /// пары проверялась без живой базы на всех днях недели (`ToleranceCaseTests`).
    static func toleranceCase(today: CalendarDay, offset: Int)
        -> (weekStart: CalendarDay, context: DayContext) {
        let date = today.adding(days: offset)
        return (Mapping.LocalTime.mondayOfWeek(date),
                DayContext(date: Mapping.LocalTime.iso(date), tz: "Europe/Moscow"))
    }

    // MARK: - 20a. Два пользователя, два JWT

    @Test("два пользователя не видят недель друг друга ни на одном недельном пути")
    func test20a_isolation() async throws {
        let alice = try await Live.signUpAnonymous()
        let bob = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("test.20a")

        try await Live.withServer("test.20a") { app in
            try await Live.seed(app, alice, logger: logger)
            try await Live.seed(app, bob, logger: logger)

            let (status, plan) = try await self.generate(app, as: alice)
            #expect(status == 201, "Алиса сгенерировала свою неделю")
            // `compactMap`, а не `map`: `day_id` необязателен с тех пор, как
            // §20.3 завела день без строки `planned_days`. У настоящей недели
            // такого дня нет, и это утверждается счётом — иначе `nil`
            // проскользнул бы в множество и дальше в URL как `Optional("…")`.
            let aliceDayList = plan?.plan.days ?? []
            let aliceDays = Set(aliceDayList.compactMap(\.dayID))
            #expect(!aliceDays.isEmpty)
            #expect(aliceDays.count == aliceDayList.count, "у каждого дня недели есть id")

            let path = "/v1/week-plans/\(Mapping.LocalTime.iso(self.weekStart))"
                + "?date=\(self.day.date)&tz=Europe%2FMoscow"

            // Своя неделя видна.
            try await app.testing().test(.GET, path, headers: alice.headers) { response in
                #expect(response.status == .ok)
                let body = try JSONDecoder().decode(WeekPlanResponseDTO.self,
                                                    from: Data(buffer: response.body))
                #expect(Set(body.plan.days.compactMap(\.dayID)) == aliceDays)
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
            let bobDays = Set((bobPlan?.plan.days ?? []).compactMap(\.dayID))
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

        try await Live.withServer("test.20d") { app in
            try await Live.seed(app, user, logger: Live.quietLogger("test.20d"))

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

        try await Live.withServer("test.20d.ok") { app in
            try await Live.seed(app, user, logger: Live.quietLogger("test.20d.ok"))

            for offset in [-1, 0, 1] {
                // Неделя считается от ПОСЫЛАЕМОЙ даты, а не от сегодняшней: по
                // воскресеньям `today + 1` уже следующая неделя, и понедельник
                // текущей для неё — прошлая, которую сервер не генерирует.
                let pair = Self.toleranceCase(today: self.today, offset: offset)
                let body = GenerateWeekPlanRequest(
                    weekStart: Mapping.LocalTime.iso(pair.weekStart), day: pair.context)
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

        try await Live.withServer("test.20j") { app in
            try await Live.seed(app, user, logger: Live.quietLogger("test.20j"))

            let (firstStatus, first) = try await self.generate(app, as: user)
            #expect(firstStatus == 201)
            let firstDays = try #require(first?.plan.days)

            let (secondStatus, second) = try await self.generate(app, as: user)
            #expect(secondStatus == 200, "повтор — не создание")
            let secondDays = try #require(second?.plan.days)

            #expect(secondDays.compactMap(\.dayID) == firstDays.compactMap(\.dayID), "те же дни")
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

        try await Live.withServer("test.20j.past") { app in
            try await Live.seed(app, user, logger: Live.quietLogger("test.20j.past"))

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

        try await Live.withServer("test.20j.next") { app in
            try await Live.seed(app, user, logger: Live.quietLogger("test.20j.next"))

            let (status, _) = try await self.generate(app, as: user,
                                                      weekStart: self.weekStart.adding(days: 7))
            #expect(status == 201)
        }
    }
}

/// Пара (`week_start`, дата) из теста 20d согласована в ЛЮБОЙ день недели.
///
/// Живой тест бежит на сегодняшнем дне и упал по воскресеньям; этот проходит
/// все семь дней подряд без часов и без базы, и именно он защищает от
/// возврата ошибки в остальные шесть.
@Suite("20d: пара week_start и date согласована в любой день недели")
struct ToleranceCaseTests {

    @Test("понедельник пары — понедельник недели посылаемой даты, для всех дней и смещений")
    func pairIsConsistentOnEveryWeekday() {
        // 14 подряд идущих дней: семь дней недели дважды, включая границу недель.
        let start = Mapping.LocalTime.day(iso: "2026-10-05")!  // понедельник
        var seenWeekdays = Set<Int>()
        for dayIndex in 0..<14 {
            let today = start.adding(days: dayIndex)
            seenWeekdays.insert((today.dayNumber + 3) % 7 + 1)
            for offset in [-1, 0, 1] {
                let pair = LiveWeekPlanTests.toleranceCase(today: today, offset: offset)
                let date = Mapping.LocalTime.day(iso: pair.context.date)!
                let delta = date.dayNumber - pair.weekStart.dayNumber
                #expect((pair.weekStart.dayNumber + 3) % 7 + 1 == 1, "week_start — понедельник")
                #expect((0...6).contains(delta),
                        "дата \(pair.context.date) лежит в неделе \(Mapping.LocalTime.iso(pair.weekStart))")
            }
        }
        #expect(seenWeekdays == Set(1...7), "проверены все семь дней недели")
    }

    @Test("в воскресенье смещение +1 даёт НОВУЮ неделю, а не понедельник текущей")
    func sundayPlusOneIsNextWeek() {
        let sunday = Mapping.LocalTime.day(iso: "2026-10-11")!
        let pair = LiveWeekPlanTests.toleranceCase(today: sunday, offset: 1)
        #expect(Mapping.LocalTime.iso(pair.weekStart) == "2026-10-12")
        #expect(pair.context.date == "2026-10-12")
    }
}
