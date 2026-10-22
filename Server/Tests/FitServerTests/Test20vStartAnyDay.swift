//  20v. Старт не сегодняшнего дня (SPEC §7.1, §20.3, §20.15).
//
//  Любой день текущей недели со статусом `planned` начинается сегодня и
//  выполняется сегодня: `performed_on` — день старта, а день плана остаётся на
//  своей дате и закрывается `done`. Утверждения о дате выполнения ставятся
//  против строк `sets`, прочитанных транзакцией пользовательницы, а не только
//  против ответа.
//
//  От дня недели прогона тест зависит только выбором «другого» дня: будущий,
//  когда сегодня не воскресенье, иначе прошедший. Прошедший проверяется своим
//  тестом и в понедельник пропускается — прошедших дней недели тогда нет.

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

@Suite("20v: старт не сегодняшнего дня (§7.1)", .enabled(if: Live.enabled), .serialized)
struct Test20vStartAnyDay {

    private static let zone = TimeZone(identifier: "Europe/Moscow")!
    private static var today: CalendarDay { Mapping.LocalTime.day(of: Date(), in: zone) }
    private static var weekday: Int { (today.dayNumber + 3) % 7 + 1 }
    private var iso: (CalendarDay) -> String { Mapping.LocalTime.iso }
    private var query: String { "date=\(Live.today.date)&tz=Europe%2FMoscow" }

    /// Неделя из двух дней — сегодняшнего и `other` (ISO-номер дня недели).
    private func week(_ app: Application, _ user: Live.User, other: Int,
                      logger: Logger) async throws -> WeekPlanResponseDTO {
        try await Live.seed(app, user, logger: logger, weekdays: [Self.weekday, other].sorted())
        var dto: WeekPlanResponseDTO?
        let body = GenerateWeekPlanRequest(weekStart: iso(Self.today.mondayOfWeek), day: Live.today)
        try await app.testing().test(.POST, "/v1/week-plans", headers: user.headers,
                                     beforeRequest: { try $0.content.encode(body) }) { response in
            #expect(response.status == .created, Comment(rawValue: String(buffer: response.body)))
            dto = try JSONDecoder().decode(WeekPlanResponseDTO.self, from: Data(buffer: response.body))
        }
        return try #require(dto)
    }

    private func start(_ app: Application, _ user: Live.User, dayID: String) async throws -> (Int, Data) {
        var captured: (Int, Data) = (0, Data())
        let body = StartWorkoutRequest(plannedDayID: dayID, day: Live.today)
        try await app.testing().test(.POST, "/v1/workouts", headers: user.headers,
                                     beforeRequest: { try $0.content.encode(body) }) { response in
            captured = (Int(response.status.code), Data(buffer: response.body))
        }
        return captured
    }

    private func logOneSet(_ app: Application, _ user: Live.User, _ workout: WorkoutDTO) async throws {
        let exercise = try #require(workout.exercises.first)
        let body = LogSetRequest(id: UUID().uuidString, setIndex: 1, prescribedKg: exercise.prescribedKg,
                                 actualKg: exercise.prescribedKg ?? (exercise.weighted ? 20 : nil),
                                 actualReps: exercise.targetRepMin, feedback: .ok,
                                 completedAt: ISO8601DateFormatter().string(from: Date()), day: Live.today)
        try await app.testing().test(.POST, "/v1/workouts/\(workout.id)/exercises/\(exercise.id)/sets",
                                     headers: user.headers, beforeRequest: { try $0.content.encode(body) }) { response in
            #expect(response.status == .ok, Comment(rawValue: String(buffer: response.body)))
        }
    }

    private func finish(_ app: Application, _ user: Live.User, _ id: String) async throws -> FinishWorkoutResponseDTO {
        var dto: FinishWorkoutResponseDTO?
        try await app.testing().test(.POST, "/v1/workouts/\(id)/finish", headers: user.headers,
                                     beforeRequest: { try $0.content.encode(FinishWorkoutRequest(day: Live.today)) }) { response in
            #expect(response.status == .ok, Comment(rawValue: String(buffer: response.body)))
            dto = try JSONDecoder().decode(FinishWorkoutResponseDTO.self, from: Data(buffer: response.body))
        }
        return try #require(dto)
    }

    private func performedOn(_ database: Database, _ user: Live.User, workout: String) async throws -> [String] {
        try await database.withUserTransaction(authorization: "Bearer \(user.token)") { tx in
            var out: [String] = []
            for try await row in try await tx.query("""
                select distinct s.performed_on::text from sets s
                  join workout_exercises we on we.id = s.workout_exercise_id
                 where we.workout_id = \(UUID(uuidString: workout)!)
                """) { out.append(try row.decode(String.self)) }
            return out
        }
    }

    private func error(_ raw: Data) throws -> APIErrorEnvelope.Body {
        try JSONDecoder().decode(APIErrorEnvelope.self, from: raw).error
    }

    @Test("20v: другой день недели начинается сегодня, выполняется сегодня и закрывается на своей дате")
    func otherDayStartsAndIsDoneToday() async throws {
        let user = try await Live.signUpLinked()
        let logger = Live.quietLogger("20v.other")
        let other = Self.weekday < 7 ? Self.weekday + 1 : Self.weekday - 1
        try await Live.withServer("20v.other") { app, database in
            let plan = try await self.week(app, user, other: other, logger: logger).plan
            let today = try #require(plan.days.first { $0.date == Live.today.date })
            let target = try #require(plan.days.first { $0.date != Live.today.date })

            let (status, raw) = try await self.start(app, user, dayID: target.dayID)
            #expect(status == 201, Comment(rawValue: String(decoding: raw, as: UTF8.self)))
            let workout = try JSONDecoder().decode(WorkoutDTO.self, from: raw)
            #expect(workout.plannedDayID == target.dayID)
            #expect(workout.sessionKind.rawValue == target.sessionKind, "тип — дня плана")

            // Пока она идёт, сегодняшний день не начать: одна идущая за раз.
            let (busy, busyRaw) = try await self.start(app, user, dayID: today.dayID)
            #expect(busy == 409, Comment(rawValue: String(decoding: busyRaw, as: UTF8.self)))
            #expect(try self.error(busyRaw).code == .dayNotPlanned)
            #expect(try self.error(busyRaw).details?["workout_id"] == .string(workout.id))

            try await self.logOneSet(app, user, workout)
            #expect(try await self.performedOn(database, user, workout: workout.id) == [Live.today.date],
                    "подходы датированы днём старта, а не днём плана")

            let finished = try await self.finish(app, user, workout.id)
            let week = try #require(finished.week).plan.days
            let closed = try #require(week.first { $0.dayID == target.dayID })
            #expect(closed.date == target.date, "день плана остаётся на своей дате")
            #expect(closed.cause?.cause == .done)
            #expect(closed.performedOn == Live.today.date, "выполнение — на фактической дате")
            let own = try #require(week.first { $0.dayID == today.dayID })
            #expect(own.kind == "session", "сегодняшний день остаётся собранным")
            #expect(own.performedOn == nil)

            // И начинается вторым.
            let (second, secondRaw) = try await self.start(app, user, dayID: today.dayID)
            #expect(second == 201, Comment(rawValue: String(decoding: secondRaw, as: UTF8.self)))
        }
    }

    @Test("20v: прошедший не отмеченный день — предпросмотр от сегодня, старт сегодня, performed_on — сегодня",
          .enabled(if: Test20vStartAnyDay.weekday > 1))
    func pastDayIsDoneToday() async throws {
        let user = try await Live.signUpLinked()
        let logger = Live.quietLogger("20v.past")
        try await Live.withServer("20v.past") { app, database in
            let plan = try await self.week(app, user, other: Self.weekday - 1, logger: logger).plan
            let past = try #require(plan.days.first { $0.date < Live.today.date })
            #expect(past.cause?.cause == .past, "в неделе прошедший день не собран")

            var preview: WeekPlanResponseDTO?
            try await app.testing().test(
                .GET, "/v1/week-plans/\(self.iso(Self.today.mondayOfWeek))/preview?\(self.query)&day=\(past.date)",
                headers: user.headers
            ) { response in
                #expect(response.status == .ok, Comment(rawValue: String(buffer: response.body)))
                preview = try JSONDecoder().decode(WeekPlanResponseDTO.self, from: Data(buffer: response.body))
            }
            let shown = try #require(preview?.plan.days.first)
            #expect(shown.kind == "session", "предпросмотр прошедшего дня — его состав на сегодня")
            #expect(shown.date == past.date, "дата в ответе — плановая")

            let (status, raw) = try await self.start(app, user, dayID: past.dayID)
            #expect(status == 201, Comment(rawValue: String(decoding: raw, as: UTF8.self)))
            let workout = try JSONDecoder().decode(WorkoutDTO.self, from: raw)
            try await self.logOneSet(app, user, workout)
            let finished = try await self.finish(app, user, workout.id)
            let closed = try #require(finished.week?.plan.days.first { $0.dayID == past.dayID })
            #expect(closed.cause?.cause == .done)
            #expect(closed.performedOn == Live.today.date)
            #expect(try await self.performedOn(database, user, workout: workout.id) == [Live.today.date])
        }
    }

    @Test("20v: день сегодняшнего оверрайда rest — растяжка: чужой день сегодня силовой не начать")
    func todaysOverrideAppliesToTheMovedDay() async throws {
        let user = try await Live.signUpLinked()
        let logger = Live.quietLogger("20v.override")
        let other = Self.weekday < 7 ? Self.weekday + 1 : Self.weekday - 1
        try await Live.withServer("20v.override") { app in
            let plan = try await self.week(app, user, other: other, logger: logger).plan
            let target = try #require(plan.days.first { $0.date != Live.today.date })
            #expect(target.kind == "session" || target.cause?.cause == .past)
            try await Live.setOverride(user, on: Self.today, value: "rest", logger: logger)
            let (status, raw) = try await self.start(app, user, dayID: target.dayID)
            #expect(status == 409, Comment(rawValue: String(decoding: raw, as: UTF8.self)))
            #expect(try self.error(raw).details?["kind"] == .string("stretching"),
                    "день, начатый сегодня, получает сегодняшний оверрайд")
        }
    }

    @Test("20v: день другой недели — day_not_planned other_week")
    func otherWeekIsRefused() async throws {
        let user = try await Live.signUpLinked()
        let logger = Live.quietLogger("20v.week")
        try await Live.withServer("20v.week") { app in
            try await Live.seed(app, user, logger: logger, weekdays: [1, 3, 5])
            var next: WeekPlanResponseDTO?
            let body = GenerateWeekPlanRequest(weekStart: self.iso(Self.today.mondayOfWeek.adding(days: 7)),
                                               day: Live.today)
            try await app.testing().test(.POST, "/v1/week-plans", headers: user.headers,
                                         beforeRequest: { try $0.content.encode(body) }) { response in
                #expect(response.status == .created, Comment(rawValue: String(buffer: response.body)))
                next = try JSONDecoder().decode(WeekPlanResponseDTO.self, from: Data(buffer: response.body))
            }
            let day = try #require(next?.plan.days.first)
            let (status, raw) = try await self.start(app, user, dayID: day.dayID)
            #expect(status == 409, Comment(rawValue: String(decoding: raw, as: UTF8.self)))
            #expect(try self.error(raw).details?["reason"] == .string("other_week"))
        }
    }
}
