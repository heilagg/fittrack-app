//  `GET /v1/cycle/calendar` — месячная сетка цикла (SPEC §11.6, §20.3).
//
//  Путь читающий и НИЧЕГО не пишет, как `/today` и `/preview` (§20.6):
//  закрытые циклы применяются к профилю в памяти, `cycle_profiles` и её
//  `sync_seq` после запроса те же (20n).
//
//  ── Сетка — показ того же конвейера, что карточка дня ──────────────────────
//
//  Состояние `cycle` в ответе — тот же `Cycle.state` на `date` с тем же входом,
//  что у `/today`, а сетку считает `Cycle.calendar` на тех же событиях и
//  профиле. Своей модели у пути нет; своё у него только `id` и `source`
//  событий (`readCycleMarks`), которые FitCore не нужны.
//
//  ── Режим здесь не решается ───────────────────────────────────────────────
//
//  Календарь показывается только в режиме фаз (§11.6), но решает это экран:
//  путь отвечает в любом режиме, просто без прогноза и фаз там, где их нет
//  (§20.3). Профиля может не быть вовсе — тогда, как у `/today`, режим
//  подставляется «без фаз» (`Mapping.cycleProfile`).
//
//  ── Окно ───────────────────────────────────────────────────────────────────
//
//  `from` и `to` — локальные даты включительно, `from ≤ to`, не больше
//  `Cycle.calendarHorizonDays` дней. Иначе `validation_failed` с именем поля:
//  окно без предела — способ заставить сервер считать сколько угодно дней.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import FitAPI
import FitCore
import Vapor

enum CycleRoutes {

    static func register(on routes: any RoutesBuilder, database: Database) {
        routes.get("cycle", "calendar") { request async throws -> Response in
            try await calendar(request, database: database)
        }
    }

    /// Окно из query. Отдельной функцией — чтобы правила окна проверялись без
    /// базы.
    static func window(_ query: [String: String]) throws -> (from: CalendarDay, to: CalendarDay) {
        guard let raw = query["from"], let from = Mapping.LocalTime.day(iso: raw) else {
            throw APIError(.validationFailed, details: ["field": .string("from")])
        }
        guard let raw = query["to"], let to = Mapping.LocalTime.day(iso: raw),
              from <= to, from.days(until: to) < Cycle.calendarHorizonDays
        else { throw APIError(.validationFailed, details: ["field": .string("to")]) }
        return (from, to)
    }

    static func calendar(_ request: Request, database: Database) async throws -> Response {
        let input = RawInput(request)
        return try await database.withUserTransaction(authorization: input.authorization) { tx in
            // Всё, что ниже, — уже после проверки токена (§20.5).
            let day = try input.day()
            let window = try window(input.query)

            let profile: Mapping.ProfileSlice
            do {
                profile = try await Mapping.readProfile(tx)
            } catch Mapping.ReadFailure.missingRow("profiles") {
                profile = .notStarted
            }
            let cycle = try await Mapping.readCycle(
                tx, tracking: profile.cycleTracking, asOf: day.date, persist: false).inputs

            let state = Cycle.state(events: cycle.events, profile: cycle.profile,
                                    responseProfiles: cycle.responseProfiles, asOf: day.date)
            let grid = Cycle.calendar(events: cycle.events, profile: cycle.profile,
                                      from: window.from, to: window.to, asOf: day.date)
            return try WeekPlanRoutes.json(CycleCalendarDTO(
                grid, from: window.from, to: window.to, cycle: CycleStateDTO(state),
                marks: try await Mapping.readCycleMarks(tx), iso: Mapping.LocalTime.iso))
        }
    }
}
