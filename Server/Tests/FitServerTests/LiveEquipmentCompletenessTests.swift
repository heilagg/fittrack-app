//  Полнота профиля и инвентарь по умолчанию через HTTP (SPEC §20.3, §20.6).
//
//  Профиль полон, когда заполнены четыре поля `profiles` И есть строка
//  `equipment_profiles` с `is_default = true`. Раньше инвентарь в определение не
//  входил, и на состоянии «четыре поля есть, инвентаря нет» (шаги 6 и 7
//  онбординга §5) генерация недели читала несуществующую строку и отвечала
//  `not_found` — кодом про «ресурса нет» вместо «онбординг не закончен».
//
//  Три состояния, по одному тесту: инвентаря нет вовсе; строка есть, но без
//  флага; строка с флагом. Второе — отдельный случай, а не вариант первого:
//  схема не гарантирует, что единственная строка пользовательницы помечена
//  (`is_default boolean not null default false`), и сервер читает именно по
//  флагу, так что проверка «строка есть» дала бы полный профиль и тот же 404.

import Testing
import Foundation
import FitAPI
import FitCore
import Vapor
import VaporTesting
@testable import FitServer

@Suite("Полнота профиля и инвентарь по умолчанию (§20.3, §20.6)",
       .enabled(if: Live.enabled), .serialized)
struct LiveEquipmentCompletenessTests {

    private var today: CalendarDay {
        Mapping.LocalTime.day(of: Date(), in: TimeZone(identifier: "Europe/Moscow")!)
    }
    private var day: DayContext { DayContext(date: Mapping.LocalTime.iso(today), tz: "Europe/Moscow") }
    private var todayPath: String {
        "/v1/today?date=\(Mapping.LocalTime.iso(today))&tz=Europe%2FMoscow"
    }

    private func isComplete(_ app: Application, _ user: Live.User) async throws -> Bool? {
        var result: Bool?
        try await app.testing().test(.GET, "/v1/profile", headers: user.headers) { response in
            #expect(response.status == .ok)
            result = (try? JSONDecoder().decode(ProfileDTO.self,
                                                from: Data(buffer: response.body)))?.isComplete
        }
        return result
    }

    private func todayKind(_ app: Application, _ user: Live.User) async throws -> (String, String?)? {
        var result: (String, String?)?
        try await app.testing().test(.GET, todayPath, headers: user.headers) { response in
            #expect(response.status == .ok, "/today не отказывает на неполном профиле (§20.3)")
            if let card = try? JSONDecoder().decode(TodayCardDTO.self, from: Data(buffer: response.body)) {
                result = (card.day.kind, card.day.dayID)
            }
        }
        return result
    }

    /// Генерация недели, ожидаемо отказывающая: возвращает код и `missing`.
    private func generationRefusal(_ app: Application, _ user: Live.User)
        async throws -> (Int, APIErrorCode?, APIDetailValue?) {
        let body = GenerateWeekPlanRequest(
            weekStart: Mapping.LocalTime.iso(Mapping.LocalTime.mondayOfWeek(today)), day: day)
        var captured: (Int, APIErrorCode?, APIDetailValue?) = (0, nil, nil)
        try await app.testing().test(.POST, "/v1/week-plans", headers: user.headers,
                                     beforeRequest: { try $0.content.encode(body) }) { response in
            let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self,
                                                     from: Data(buffer: response.body))
            captured = (Int(response.status.code), envelope?.error.code,
                        envelope?.error.details?["missing"])
        }
        return captured
    }

    private func assertIncomplete(_ app: Application, _ user: Live.User) async throws {
        #expect(try await isComplete(app, user) == false)

        let card = try await todayKind(app, user)
        #expect(card?.0 == "not_built")
        #expect(card?.1 == nil, "строки planned_days нет, и идентификатора тоже")

        let (status, code, missing) = try await generationRefusal(app, user)
        #expect(status == 409, "profile_incomplete, а не 404 (§20.6)")
        #expect(code == .profileIncomplete)
        #expect(missing == .string("equipment_profile"))
    }

    @Test("четыре поля без строки инвентаря: профиль неполон, /today not_built, генерация — profile_incomplete")
    func noEquipmentRow() async throws {
        let user = try await Live.signUpAnonymous()
        try await Live.withServer("live.equipment.none") { app in
            try await Live.seedProfile(app, user)
            try await self.assertIncomplete(app, user)
        }
    }

    @Test("строка инвентаря есть, но is_default = false: то же самое")
    func rowWithoutDefaultFlag() async throws {
        let user = try await Live.signUpAnonymous()
        try await Live.withServer("live.equipment.notdefault") { app in
            try await Live.seedProfile(app, user)
            try await Live.seedEquipment(user, isDefault: false,
                                         logger: Live.quietLogger("live.equipment.notdefault.seed"))
            try await self.assertIncomplete(app, user)
        }
    }

    @Test("строка с is_default = true: профиль полон и неделя строится")
    func defaultRowCompletesProfile() async throws {
        let user = try await Live.signUpAnonymous()
        try await Live.withServer("live.equipment.default") { app in
            try await Live.seedProfile(app, user)
            try await Live.seedEquipment(user, isDefault: true,
                                         logger: Live.quietLogger("live.equipment.default.seed"))
            #expect(try await self.isComplete(app, user) == true)

            let body = GenerateWeekPlanRequest(
                weekStart: Mapping.LocalTime.iso(Mapping.LocalTime.mondayOfWeek(self.today)),
                day: self.day)
            try await app.testing().test(.POST, "/v1/week-plans", headers: user.headers,
                                         beforeRequest: { try $0.content.encode(body) }) { response in
                #expect(response.status == .created, Comment(rawValue: String(buffer: response.body)))
            }
        }
    }
}
