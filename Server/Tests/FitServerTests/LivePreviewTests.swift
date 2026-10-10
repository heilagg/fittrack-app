//  `GET /v1/week-plans/{week_start}/preview` через HTTP (SPEC §20.3, §20.6).
//
//  Проекция недели на один день. Своего расчёта у неё нет — заморозка §18 31b
//  уже внутри `planRemainingDays`, — поэтому проверяется ровно то, что добавляет
//  сам путь: какой день вырезан, что недельные строки НЕ отфильтрованы, что
//  чужая дата отклоняется, и что снимок остаётся нетронутым.
//
//  Две даты у одного пути (§20.3) — главный источник ошибок здесь, и тесты на
//  него смотрят с обеих сторон: `date` это «сегодня клиента», `day` — срез.

import Testing
import Foundation
import FitAPI
import FitCore
import Vapor
import VaporTesting
@testable import FitServer

@Suite("/preview: проекция недели на один день (§20.3)", .enabled(if: Live.enabled), .serialized)
struct LivePreviewTests {

    private var today: CalendarDay {
        Mapping.LocalTime.day(of: Date(), in: TimeZone(identifier: "Europe/Moscow")!)
    }
    private var weekStart: CalendarDay { Mapping.LocalTime.mondayOfWeek(today) }
    private var todayISOWeekday: Int { (today.dayNumber + 3) % 7 + 1 }

    private var day: DayContext {
        DayContext(date: Mapping.LocalTime.iso(today), tz: "Europe/Moscow")
    }

    private var weekPath: String { "/v1/week-plans/\(Mapping.LocalTime.iso(weekStart))" }

    private func previewPath(_ target: CalendarDay?) -> String {
        var path = "\(weekPath)/preview?date=\(day.date)&tz=Europe%2FMoscow"
        if let target { path += "&day=\(Mapping.LocalTime.iso(target))" }
        return path
    }

    private func generate(_ app: Application, as user: Live.User) async throws {
        let body = GenerateWeekPlanRequest(weekStart: Mapping.LocalTime.iso(weekStart), day: day)
        try await app.testing().test(.POST, "/v1/week-plans", headers: user.headers,
                                     beforeRequest: { try $0.content.encode(body) }) { response in
            #expect(response.status == .created, Comment(rawValue: String(buffer: response.body)))
        }
    }

    private func preview(_ app: Application, as user: Live.User,
                         on target: CalendarDay?) async throws -> WeekPlanResponseDTO {
        var captured: WeekPlanResponseDTO?
        try await app.testing().test(.GET, previewPath(target), headers: user.headers) { response in
            #expect(response.status == .ok, Comment(rawValue: String(buffer: response.body)))
            captured = try? JSONDecoder().decode(WeekPlanResponseDTO.self,
                                                 from: Data(buffer: response.body))
        }
        return try #require(captured)
    }

    private func week(_ app: Application, as user: Live.User) async throws -> WeekPlanResponseDTO {
        var captured: WeekPlanResponseDTO?
        try await app.testing().test(.GET, "\(weekPath)?date=\(day.date)&tz=Europe%2FMoscow",
                                     headers: user.headers) { response in
            #expect(response.status == .ok, Comment(rawValue: String(buffer: response.body)))
            captured = try? JSONDecoder().decode(WeekPlanResponseDTO.self,
                                                 from: Data(buffer: response.body))
        }
        return try #require(captured)
    }

    // MARK: - Срез

    @Test("срез отдаёт ровно один день — тот, чья дата пришла в day")
    func slicesByDay() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("preview.slice")

        try await Live.withServer("preview.slice") { app in
            // Понедельник, среда, пятница — три дня и три РАЗНЫЕ даты.
            try await Live.seed(app, user, logger: logger, weekdays: [1, 3, 5])
            try await self.generate(app, as: user)

            let full = try await self.week(app, as: user)
            #expect(full.plan.days.count == 3, "неделя целиком — три дня")

            for offset in [0, 2, 4] {
                let target = self.weekStart.adding(days: offset)
                let sliced = try await self.preview(app, as: user, on: target)
                #expect(sliced.plan.days.count == 1,
                        Comment(rawValue: "срез по \(Mapping.LocalTime.iso(target))"))

                // Тот же день, что и в недельном ответе: срез не пересчитывает.
                let id = try #require(sliced.plan.days.first?.dayID)
                let fromWeek = try #require(full.plan.days.first { $0.dayID == id })
                #expect(sliced.plan.days.first?.kind == fromWeek.kind)
                #expect(sliced.plan.days.first?.session?.exercises.map(\.slug)
                        == fromWeek.session?.exercises.map(\.slug))
            }
        }
    }

    @Test("недельные строки статуса не фильтруются срезом (§20.3)")
    func statusLinesStayWeekly() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("preview.lines")

        // Сегодня плюс соседний день: сегодняшний гарантированно собирается
        // (`classify` отдаёт `session`), и его можно пропустить, а срез
        // спрашивать по ВТОРОЙ дате. В воскресенье соседа впереди нет, поэтому
        // пара берётся назад — суббота прошедшая, но строку потери даёт не она.
        let pair = self.todayISOWeekday < 7
            ? [self.todayISOWeekday, self.todayISOWeekday + 1]
            : [6, 7]

        try await Live.withServer("preview.lines") { app in
            try await Live.seed(app, user, logger: logger, weekdays: pair)
            try await self.generate(app, as: user)

            // Дата → `day_id`: спрашивается у самого среза, а не выводится из
            // порядка дней в недельном ответе (он сортирован по id).
            var idByDate: [CalendarDay: String] = [:]
            for weekday in pair {
                let date = self.weekStart.adding(days: weekday - 1)
                let sliced = try await self.preview(app, as: user, on: date)
                idByDate[date] = sliced.plan.days.first?.dayID
            }
            let victim = try #require(idByDate[self.today], "сегодняшний день есть в неделе")
            let otherDate = try #require(idByDate.keys.first { $0 != self.today })

            // Пропуск дня даёт недельную строку потери объёма (§7.1).
            let patch = PatchPlannedDayRequest(status: .skipped, day: self.day)
            try await app.testing().test(.PATCH, "\(self.weekPath)/days/\(victim)",
                                         headers: user.headers,
                                         beforeRequest: { try $0.content.encode(patch) }) { response in
                #expect(response.status == .ok, Comment(rawValue: String(buffer: response.body)))
            }

            let after = try await self.week(app, as: user)
            #expect(!after.plan.statusLines.isEmpty, "пропуск дал недельную строку")

            // Срез по ДРУГОМУ дню несёт те же строки: они про всю неделю, и
            // §20.3 принял цену — на экране одного дня может стоять строка про
            // мышцу, которой в этом дне нет.
            let sliced = try await self.preview(app, as: user, on: otherDate)
            #expect(sliced.plan.days.count == 1)
            #expect(sliced.plan.days.first?.dayID != victim, "срезан не пропущенный день")
            #expect(sliced.plan.statusLines.map(\.reason) == after.plan.statusLines.map(\.reason),
                    "строки недельные и срезом не трогаются")
        }
    }

    // MARK: - Отказы

    @Test("day вне недели из пути — validation_failed с полем day")
    func dayOutsideTheWeek() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("preview.outside")

        try await Live.withServer("preview.outside") { app in
            try await Live.seed(app, user, logger: logger)
            try await self.generate(app, as: user)

            for target in [self.weekStart.adding(days: -1), self.weekStart.adding(days: 7)] {
                try await app.testing().test(.GET, self.previewPath(target),
                                             headers: user.headers) { response in
                    #expect(response.status == .unprocessableEntity,
                            Comment(rawValue: Mapping.LocalTime.iso(target)))
                    let envelope = try JSONDecoder().decode(APIErrorEnvelope.self,
                                                            from: Data(buffer: response.body))
                    #expect(envelope.error.code == .validationFailed)
                    #expect(envelope.error.details?["field"] == .string("day"))
                }
            }
        }
    }

    @Test("day не прислан вовсе — тот же validation_failed, а не срез по сегодня")
    func dayMissing() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("preview.missing")

        try await Live.withServer("preview.missing") { app in
            try await Live.seed(app, user, logger: logger)
            try await self.generate(app, as: user)

            try await app.testing().test(.GET, self.previewPath(nil),
                                         headers: user.headers) { response in
                #expect(response.status == .unprocessableEntity)
                let envelope = try JSONDecoder().decode(APIErrorEnvelope.self,
                                                        from: Data(buffer: response.body))
                #expect(envelope.error.details?["field"] == .string("day"))
            }
        }
    }

    // MARK: - Недели нет

    @Test("недели ещё нет — пустой план, а не 404 (§20.3)")
    func weekNotGenerated() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("preview.noweek")

        try await Live.withServer("preview.noweek") { app in
            try await Live.seed(app, user, logger: logger)

            let sliced = try await self.preview(app, as: user, on: self.weekStart)
            #expect(sliced.plan.days.isEmpty)
            #expect(sliced.plan.statusLines.isEmpty)
            #expect(sliced.notice == nil)
        }
    }

    // MARK: - Путь ничего не пишет

    @Test("/preview не трогает last_shown_plan — следующий GET недели печатает plan_changed")
    func previewDoesNotWriteTheSnapshot() async throws {
        let user = try await Live.signUpAnonymous()
        let logger = Live.quietLogger("preview.snapshot")

        try await Live.withServer("preview.snapshot") { app in
            try await Live.seed(app, user, logger: logger, weekdays: [self.todayISOWeekday])
            try await self.generate(app, as: user)

            try await Live.setOverride(user, on: self.today, value: "rest", logger: logger)

            let sliced = try await self.preview(app, as: user, on: self.today)
            #expect(sliced.plan.days.first?.kind == "stretching", "оверрайд виден в срезе")
            #expect(sliced.notice == nil, "проекция о показанном не сообщает")

            let after = try await self.week(app, as: user)
            #expect(after.notice?.reason == .planChanged,
                    "снимок всё ещё хранит план до оверрайда — значит /preview в него не писал")
        }
    }
}
