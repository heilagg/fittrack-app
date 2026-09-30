//  `GET /v1/today` через HTTP против живой базы (SPEC §20.3, §20.6).
//
//  Карточка дня — проекция `planRemainingDays`, и проверять в ней стоит ровно
//  то, чего проекция не гарантирует сама: какой день выбран из недели, что
//  отдаётся, когда строки нет, и что путь НИЧЕГО не пишет.
//
//  ── Почему день двигается профилем, а не календарём ───────────────────────
//
//  §20.7 держит присланную дату в сутках от серверной, значит «пусть сегодня
//  будет вторник» в тесте недостижимо. Зато достижимо обратное: набор
//  `training_weekdays` выбирается так, чтобы сегодняшний ISO-номер в него
//  входил или не входил. Исходы те же, и они настоящие.
//
//  ── Чем проверяется «снимок не пишется» ───────────────────────────────────
//
//  Сравнить снимок до и после вызова мало: он и так не изменился бы, потому что
//  план тот же. Поэтому план сдвигается между генерацией и чтением — оверрайдом
//  `rest` на сегодня (§11.4), который фронтенд пишет напрямую, — и утверждение
//  ставится на СЛЕДУЮЩЕМ `GET` недели: он обязан напечатать `plan_changed`.
//  Напечатает он его только если снимок всё ещё хранит план ДО оверрайда, то
//  есть если `/today` в него не писал.

import Testing
import Foundation
import FitAPI
import FitCore
import Vapor
import VaporTesting
@testable import FitServer

@Suite("/v1/today: карточка дня через HTTP (§20.3)", .enabled(if: Live.enabled), .serialized)
struct LiveTodayTests {

    private let zone = "Europe/Moscow"

    private var today: CalendarDay {
        Mapping.LocalTime.day(of: Date(), in: TimeZone(identifier: "Europe/Moscow")!)
    }
    private var weekStart: CalendarDay { Mapping.LocalTime.mondayOfWeek(today) }

    /// ISO-номер дня недели, 1...7. Эпоха — четверг, отсюда `+3`.
    private var todayISOWeekday: Int { (today.dayNumber + 3) % 7 + 1 }

    /// Три дня недели, среди которых сегодняшнего нет.
    private var weekdaysWithoutToday: [Int] {
        Array((1...7).filter { $0 != todayISOWeekday }.prefix(3))
    }

    private var todayPath: String {
        "/v1/today?date=\(Mapping.LocalTime.iso(today))&tz=Europe%2FMoscow"
    }

    private var day: DayContext {
        DayContext(date: Mapping.LocalTime.iso(today), tz: zone)
    }

    private func generate(_ app: Application, as user: Live.User) async throws {
        let body = GenerateWeekPlanRequest(weekStart: Mapping.LocalTime.iso(weekStart), day: day)
        try await app.testing().test(.POST, "/v1/week-plans", headers: user.headers,
                                     beforeRequest: { try $0.content.encode(body) }) { response in
            #expect(response.status == .created, Comment(rawValue: String(buffer: response.body)))
        }
    }

    private func card(_ app: Application, as user: Live.User) async throws -> TodayCardDTO {
        var captured: TodayCardDTO?
        try await app.testing().test(.GET, todayPath, headers: user.headers) { response in
            #expect(response.status == .ok, Comment(rawValue: String(buffer: response.body)))
            captured = try? JSONDecoder().decode(TodayCardDTO.self, from: Data(buffer: response.body))
        }
        return try #require(captured)
    }

    /// Сырой JSON — чтобы утверждать об ОТСУТСТВИИ ключа, а не о `nil` после
    /// разбора: §20.3 обещает клиенту форму тела, и разобранный DTO её скрывает.
    private func rawDay(_ app: Application, as user: Live.User) async throws -> [String: Any] {
        var captured: [String: Any]?
        try await app.testing().test(.GET, todayPath, headers: user.headers) { response in
            let json = try JSONSerialization.jsonObject(with: Data(buffer: response.body))
            captured = (json as? [String: Any])?["day"] as? [String: Any]
        }
        return try #require(captured)
    }

    // MARK: - День есть

    @Test("сегодня тренировочный день — карточка отдаёт его, с id и составом")
    func trainingDay() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("today.training")

        try await Live.withServer("today.training") { app in
            try await Live.seed(app, user, logger: logger, weekdays: [self.todayISOWeekday])
            try await self.generate(app, as: user)

            let card = try await self.card(app, as: user)
            #expect(card.date == Mapping.LocalTime.iso(self.today))
            #expect(card.day.kind == "session", "единственный день недели — сегодняшний")
            #expect(card.day.dayID != nil, "строка есть, значит есть и id")
            #expect(card.day.cause == nil, "у собранного дня причины нет")
            #expect(card.day.session?.exercises.isEmpty == false)
            #expect(card.readiness > 0)
        }
    }

    // MARK: - Дня нет: два рода

    @Test("сегодня не тренировочный день — not_built с причиной not_a_training_day")
    func restDay() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("today.rest")

        try await Live.withServer("today.rest") { app in
            try await Live.seed(app, user, logger: logger, weekdays: self.weekdaysWithoutToday)
            try await self.generate(app, as: user)

            let card = try await self.card(app, as: user)
            #expect(card.day.kind == "not_built")
            #expect(card.day.cause?.cause == .notATrainingDay)
            #expect(card.day.session == nil)
            #expect(card.day.losesPlannedVolume == false, "планового объёма на этот день не было")

            let raw = try await self.rawDay(app, as: user)
            #expect(raw["day_id"] == nil, "строки нет — ключа тоже нет (§20.3)")
            let cause = try #require(raw["cause"] as? [String: Any])
            #expect(cause["code"] as? String == "not_a_training_day")
            #expect((cause["message"] as? String)?.isEmpty == false,
                    "формулировку отдаёт сервер (§20.3)")
        }
    }

    @Test("недели ещё нет — not_built без причины, но с готовностью и фазой")
    func weekNotGenerated() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("today.noweek")

        try await Live.withServer("today.noweek") { app in
            try await Live.seed(app, user, logger: logger)

            let card = try await self.card(app, as: user)
            #expect(card.day.kind == "not_built")
            #expect(card.day.cause == nil, "«недели нет» ни одним значением словаря не описано")
            #expect(card.readiness > 0, "готовность считается и без недели (§20.3)")
            #expect(card.reasons.isEmpty, "недельных строк нет, потому что нет недели")

            let raw = try await self.rawDay(app, as: user)
            #expect(raw["day_id"] == nil)
            #expect(raw["cause"] == nil)
        }
    }

    @Test("неполный профиль — путь работает, а не отвечает 409 (§20.6)")
    func incompleteProfile() async throws {
        let user = try await Live.signUpAnonymous()

        try await Live.withServer("today.incomplete") { app in
            // Только первый шаг онбординга: четырёх обязательных полей нет.
            let body = PatchProfileRequest(sexAtBirth: .some("female"), birthYear: .some(1994))
            try await app.testing().test(.PATCH, "/v1/profile", headers: user.headers,
                                         beforeRequest: { try $0.content.encode(body) }) { response in
                #expect(response.status == .ok)
            }

            let card = try await self.card(app, as: user)
            #expect(card.day.kind == "not_built")
            #expect(card.day.cause == nil)
        }
    }

    // MARK: - Путь ничего не пишет

    @Test("/today не трогает last_shown_plan — следующий GET недели печатает plan_changed")
    func todayDoesNotWriteTheSnapshot() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("today.snapshot")

        try await Live.withServer("today.snapshot") { app in
            try await Live.seed(app, user, logger: logger, weekdays: [self.todayISOWeekday])
            try await self.generate(app, as: user)

            // План сдвигается мимо сервера: оверрайд `rest` на сегодня (§11.4)
            // делает из силового дня растяжку.
            try await Live.setOverride(user, on: self.today, value: "rest", logger: logger)

            let card = try await self.card(app, as: user)
            #expect(card.day.kind == "stretching", "оверрайд виден в карточке")
            #expect(card.day.cause?.cause == .restOverride)

            let path = "/v1/week-plans/\(Mapping.LocalTime.iso(self.weekStart))"
                + "?date=\(self.day.date)&tz=Europe%2FMoscow"
            try await app.testing().test(.GET, path, headers: user.headers) { response in
                #expect(response.status == .ok, Comment(rawValue: String(buffer: response.body)))
                let body = try JSONDecoder().decode(WeekPlanResponseDTO.self,
                                                    from: Data(buffer: response.body))
                #expect(body.notice?.reason == .planChanged,
                        "снимок всё ещё хранит план до оверрайда — значит /today в него не писал")
            }
        }
    }
}
