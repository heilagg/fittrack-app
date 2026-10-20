//  `GET /v1/progress` (SPEC §13.7, §20.3): одно тело на весь экран.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import FitAPI
import FitContent
import FitCore
import Vapor

enum ProgressRoutes {

    /// Окно не длиннее 12 недель и месяца календаря вместе (§13.7: клиент
    /// берёт `from` как наименьшее из двух начал).
    static let maxWindowDays = 130

    static func register(on routes: any RoutesBuilder, database: Database, library: ContentLibrary) {
        routes.get("progress") { request async throws -> Response in
            try await show(request, database: database, library: library)
        }
    }

    static func window(_ query: [String: String], today: CalendarDay) throws -> (from: CalendarDay, to: CalendarDay) {
        guard let raw = query["from"], let from = Mapping.LocalTime.day(iso: raw) else {
            throw APIError(.validationFailed, details: ["field": .string("from")])
        }
        guard let raw = query["to"], let to = Mapping.LocalTime.day(iso: raw),
              from <= to, to <= today, from.days(until: to) < maxWindowDays
        else { throw APIError(.validationFailed, details: ["field": .string("to")]) }
        return (from, to)
    }

    static func show(_ request: Request, database: Database, library: ContentLibrary) async throws -> Response {
        let input = RawInput(request)
        return try await database.withUserTransaction(authorization: input.authorization) { tx in
            let day = try input.day()
            let window = try window(input.query, today: day.date)
            let profile: Mapping.ProfileSlice
            do {
                profile = try await Mapping.readProfile(tx)
            } catch Mapping.ReadFailure.missingRow("profiles") {
                profile = .notStarted
            }
            guard let complete = profile.complete else {
                throw APIError(.profileIncomplete, details: [
                    "missing": .string(Mapping.missingProfileFields(profile).joined(separator: ","))
                ])
            }
            let equipment = try await Mapping.readEquipment(tx, id: nil)
            let completed = try await Mapping.readCompleted(tx, since: nil, timeZone: day.timeZone)
            let journal = try await Mapping.readSets(tx, since: nil, timeZone: day.timeZone)
            let cycle = try await Mapping.readCycle(
                tx, tracking: profile.cycleTracking, asOf: day.date, persist: false).inputs
            let body = Mapping.progress(Mapping.ProgressInputs(
                from: window.from, to: window.to, today: day.date, level: complete.level, goal: complete.goal,
                equipment: equipment.profile,
                library: Dictionary(uniqueKeysWithValues: library.candidates.map { ($0.slug, $0) }),
                completed: Mapping.completedWorkouts(rows: completed.rows, sets: completed.sets),
                history: Mapping.exerciseHistory(from: journal),
                stretchDays: try await Mapping.readStretchDays(tx),
                skippedDays: try await Mapping.readSkippedDays(tx, from: window.from, to: window.to),
                cycle: cycle))
            return try WeekPlanRoutes.json(body)
        }
    }
}
