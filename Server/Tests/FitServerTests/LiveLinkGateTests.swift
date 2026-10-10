//  Гейт линковки на `POST /v1/workouts` через HTTP (SPEC §20.5).
//
//  «Начать тренировку» требует привязанного аккаунта: защищается потерянная
//  история тренировок, а не план. Правило стоит на сервере, а не в кнопке, —
//  иначе запрос мимо интерфейса создал бы ровно ту историю, ради сохранности
//  которой гейт введён. Раньше `requireLinkedAccount()` существовал и
//  проверялся на значении токена (20b), но ни один путь его не вызывал.
//
//  Анонимному пользователю при этом остаются доступны профиль, инвентарь и
//  генерация недели (§20.5): иначе онбординг §5, который идёт до линковки, не
//  работал бы.

import Testing
import Foundation
import FitAPI
import FitCore
import Vapor
import VaporTesting
@testable import FitServer

@Suite("Гейт линковки: POST /v1/workouts (§20.5)", .enabled(if: Live.enabled), .serialized)
struct LiveLinkGateTests {

    private var day: DayContext { Live.today }

    private func plannedDayID(_ app: Application, as user: Live.User) async throws -> String {
        let today = Mapping.LocalTime.day(of: Date(), in: TimeZone(identifier: "Europe/Moscow")!)
        let body = GenerateWeekPlanRequest(
            weekStart: Mapping.LocalTime.iso(Mapping.LocalTime.mondayOfWeek(today)), day: day)
        var id: String?
        try await app.testing().test(.POST, "/v1/week-plans", headers: user.headers,
                                     beforeRequest: { try $0.content.encode(body) }) { response in
            #expect(response.status == .created, Comment(rawValue: String(buffer: response.body)))
            id = (try? JSONDecoder().decode(WeekPlanResponseDTO.self, from: Data(buffer: response.body)))?
                .plan.days.first?.dayID
        }
        return try #require(id)
    }

    private func seedWeek(_ app: Application, _ user: Live.User) async throws -> String {
        let today = Mapping.LocalTime.day(of: Date(), in: TimeZone(identifier: "Europe/Moscow")!)
        let weekday = (today.dayNumber + 3) % 7 + 1
        try await Live.seed(app, user, logger: Live.quietLogger("gate.seed"), weekdays: [weekday])
        return try await plannedDayID(app, as: user)
    }

    private func start(_ app: Application, as user: Live.User, dayID: String) async throws
        -> (Int, APIErrorCode?) {
        let body = StartWorkoutRequest(plannedDayID: dayID, day: day)
        var captured: (Int, APIErrorCode?) = (0, nil)
        try await app.testing().test(.POST, "/v1/workouts", headers: user.headers,
                                     beforeRequest: { try $0.content.encode(body) }) { response in
            let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: Data(buffer: response.body))
            captured = (Int(response.status.code), envelope?.error.code)
        }
        return captured
    }

    @Test("анонимный токен получает unlinked_account и 403, хотя план у него есть")
    func anonymousIsRefused() async throws {
        let user = try await Live.signUpAnonymous()
        try await Live.withServer("gate.anonymous") { app in
            // Онбординг и генерация недели анонимному доступны (§20.5)…
            let dayID = try await self.seedWeek(app, user)
            // …а старт — нет.
            let (status, code) = try await self.start(app, as: user, dayID: dayID)
            #expect(status == 403)
            #expect(code == .unlinkedAccount)
        }
    }

    @Test("гейт стоит до разбора тела: анонимному не отвечают про ошибки запроса")
    func gateComesBeforeBodyValidation() async throws {
        let user = try await Live.signUpAnonymous()
        try await Live.withServer("gate.beforebody") { app in
            try await app.testing().test(.POST, "/v1/workouts", headers: user.headers,
                                         beforeRequest: { $0.headers.contentType = .json
                                             $0.body = ByteBuffer(string: "{}") }) { response in
                #expect(response.status == .forbidden, "403, а не 422 на пустое тело")
            }
        }
    }

    @Test("привязанный пользователь стартует тренировку: 201")
    func linkedMayStart() async throws {
        let user = try await Live.signUpLinked()
        try await Live.withServer("gate.linked") { app in
            let dayID = try await self.seedWeek(app, user)
            let (status, _) = try await self.start(app, as: user, dayID: dayID)
            #expect(status == 201)
        }
    }
}
