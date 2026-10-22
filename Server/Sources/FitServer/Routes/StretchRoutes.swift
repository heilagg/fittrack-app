//  Сессии растяжки (SPEC §12.2, §20.3): старт, завершение, история.
//
//  Гейта линковки нет (§20.3, «Пути растяжки и прогресса»): `unlinked_account`
//  защищает историю силовых тренировок, а растяжка подходов не логирует.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import FitAPI
import FitContent
import FitCore
import Vapor

enum StretchRoutes {

    static func register(on routes: any RoutesBuilder, database: Database, library: ContentLibrary) {
        routes.post("stretch-sessions") { request async throws -> Response in
            try await start(request, database: database, library: library)
        }
        routes.post("stretch-sessions", ":id", "finish") { request async throws -> Response in
            try await finish(request, database: database)
        }
        routes.get("stretch-sessions") { request async throws -> Response in
            try await history(request, database: database)
        }
    }

    /// Виды, которые пишет этап В3: разминка §12.1 открыта (§19.2 п.33).
    static let writableKinds: Set<String> = ["standalone", "static_cooldown"]

    /// Проверка тела до записи: самостоятельная сессия называет шаблон из
    /// контента, заминка шаблона не несёт (§3.1, §12.2).
    static func validate(_ body: StartStretchSessionRequest, library: ContentLibrary) throws -> UUID {
        guard let id = UUID(uuidString: body.id) else {
            throw APIError(.validationFailed, details: ["field": .string("id")])
        }
        guard writableKinds.contains(body.kind) else {
            throw APIError(.validationFailed, details: ["field": .string("kind")])
        }
        switch body.kind {
        case "standalone":
            guard let slug = body.templateSlug, library.templates.contains(where: { $0.slug == slug }) else {
                throw APIError(.validationFailed, details: ["field": .string("template_slug")])
            }
        default:
            guard body.templateSlug == nil else {
                throw APIError(.validationFailed, details: ["field": .string("template_slug")])
            }
        }
        return id
    }

    static func start(_ request: Request, database: Database, library: ContentLibrary) async throws -> Response {
        let input = RawInput(request)
        return try await database.withUserTransaction(authorization: input.authorization) { tx in
            let body = try input.decode(StartStretchSessionRequest.self)
            // Без допуска в сутки (§20.3): дата старта — сегодняшняя в зоне клиента.
            let day = try RequestDay.validated(date: body.date, tz: body.tz, skewDays: 0)
            let id = try validate(body, library: library)
            // Строка `stretch_sessions` ссылается на `profiles` (§3.1): без
            // профиля сессию записать не к чему. Онбординг создаёт строку на
            // шаге 3 (§5), и отказ здесь — тот же `profile_incomplete`, что у
            // остальных путей, а не нарушение внешнего ключа под видом `internal`.
            do {
                _ = try await Mapping.readProfile(tx)
            } catch Mapping.ReadFailure.missingRow("profiles") {
                throw APIError(.profileIncomplete, details: [
                    "missing": .string(Mapping.missingProfileFields(.notStarted).joined(separator: ","))
                ])
            }
            guard let userID = UUID(uuidString: tx.token.subject) else { throw APIError(.internal) }
            let inserted = try await Mapping.insertStretchSession(
                tx, id: id, userID: userID, kind: body.kind, template: body.templateSlug, performedOn: day.date)
            // Вставка не прошла, а строки не видно — `id` занят чужой сессией:
            // RLS её не показывает, и отвечать «уже есть» значило бы выдать её.
            guard let session = try await Mapping.readStretchSession(tx, id: id) else {
                throw APIError(.forbidden, details: ["id": .string(id.uuidString)])
            }
            return try WeekPlanRoutes.json(session, status: inserted ? .created : .ok)
        }
    }

    static func finish(_ request: Request, database: Database) async throws -> Response {
        let input = RawInput(request)
        let rawID = request.parameters.get("id")
        return try await database.withUserTransaction(authorization: input.authorization) { tx in
            let id = try WeekPlanRoutes.uuid(rawID, "id")
            let body = try input.decode(FinishStretchSessionRequest.self)
            _ = try RequestDay.validated(date: body.date, tz: body.tz)
            guard try await Mapping.readStretchSession(tx, id: id) != nil else {
                throw APIError(.notFound, details: ["id": .string(id.uuidString)])
            }
            try await Mapping.finishStretchSession(tx, id: id)
            guard let session = try await Mapping.readStretchSession(tx, id: id) else {
                throw APIError(.internal)
            }
            return try WeekPlanRoutes.json(session)
        }
    }

    /// История и предложенный шаблон дня (§12.2, §20.3).
    static func history(_ request: Request, database: Database) async throws -> Response {
        let input = RawInput(request)
        return try await database.withUserTransaction(authorization: input.authorization) { tx in
            let day = try input.day()
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
            let suggested = Stretching.suggestedTemplate(
                phase: state.phase, cycleConfidence: state.cycleConfidence,
                lastStrengthKind: try await Mapping.readLastStrengthKind(tx))
            return try WeekPlanRoutes.json(StretchHistoryDTO(
                sessions: try await Mapping.readStretchHistory(tx), suggestedTemplate: suggested.rawValue))
        }
    }
}
