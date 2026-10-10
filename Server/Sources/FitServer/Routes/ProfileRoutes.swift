//  `GET` и `PATCH /v1/profile` (SPEC §4.1, §5, §20.3, §20.6).
//
//  Два пути, которых §20.3 не имела до решения A1, и без которых онбординг §5
//  пройти было нечем: `profiles` и `cycle_profiles` пишет только сервер (§20.6),
//  а писал их до сих пор никто.
//
//  ── Токен анонимный, и это не послабление ─────────────────────────────────
//
//  §4.1 требует, чтобы онбординг и PAR-Q проходились анонимно, и §20.5 держит
//  гейт линковки ровно на одном пути — `POST /v1/workouts`. Профиль анонимному
//  пользователю доступен: защищается потерянная история тренировок, а не план.
//
//  ── Одна транзакция на правку, и в ней две таблицы ────────────────────────
//
//  `cycle_profiles` едет вложенным объектом (§20.3), потому что шаг 9 онбординга
//  заполняет обе таблицы одним экраном. Разнесённые по двум запросам они дают
//  состояние «цикл записан, а `cycle_tracking` ещё нет» — различимое только по
//  рассогласованию.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import FitAPI
import FitCore
import Vapor

enum ProfileRoutes {

    static func register(on routes: any RoutesBuilder, database: Database) {
        routes.get("profile") { request async throws -> Response in
            try await show(request, database: database)
        }
        routes.patch("profile") { request async throws -> Response in
            try await patch(request, database: database)
        }
    }

    private static func json(_ body: some Encodable) throws -> Response {
        var headers = HTTPHeaders()
        headers.contentType = .json
        return Response(status: .ok, headers: headers,
                        body: .init(data: try JSONEncoder().encode(body)))
    }

    // MARK: - GET /v1/profile

    /// Профиль как есть, с `is_complete` (§20.3).
    ///
    /// `date`/`tz` этот путь не принимает: профиль не содержит ни одной
    /// величины, привязанной ко дню, а `updated_at` ему ставят серверные часы
    /// (§20.6). Требовать пару там, где день не участвует, значило бы завести
    /// поле, ошибку в котором ничем не обнаружить.
    ///
    /// Строки нет вовсе — `not_found`: онбординг не начинали, и отдавать пустой
    /// профиль значило бы утверждать, что он есть.
    static func show(_ request: Request, database: Database) async throws -> Response {
        let input = RawInput(request)
        return try await database.withUserTransaction(authorization: input.authorization) { tx in
            try json(try await Mapping.readProfileBody(tx))
        }
    }

    // MARK: - PATCH /v1/profile

    /// Пишет обе таблицы и отдаёт профиль целиком (§20.3).
    ///
    /// Проверки до транзакции — только те, что не требуют базы: согласованность
    /// `days_per_week` с набором дней и состав самого набора. Их цена
    /// невелика, а без них рассогласование доехало бы до `check` схемы и
    /// вернулось бы клиенту как `internal` (§20.3: словарь кодов закрыт, и
    /// `internal` означает нашу поломку, а не неверное тело).
    static func patch(_ request: Request, database: Database) async throws -> Response {
        let input = RawInput(request)
        return try await database.withUserTransaction(authorization: input.authorization) { tx in
            // Разбор — уже после проверки токена (§20.5): иначе клиент без
            // токена с негодным телом получал бы 422 вместо 401.
            let body = try input.decode(PatchProfileRequest.self)
            try validate(body)
            guard let userID = UUID(uuidString: tx.token.subject) else { throw APIError(.internal) }
            try await Mapping.upsertProfile(tx, userID: userID, body)
            if let cycle = body.cycle {
                try await Mapping.upsertCycleProfile(tx, userID: userID, cycle)
            }
            return try json(try await Mapping.readProfileBody(tx))
        }
    }

    /// Что проверяется до записи.
    ///
    /// Набор дней — единственное поле, у которого форма сложнее значения: схема
    /// требует ISO-номера 1..7, без повторов и отсортированными
    /// (`weekdays_canonical`, §3.1), и пустым он быть не может, потому что
    /// `days_per_week` имеет `check (between 1 and 7)`. Сортировку сервер
    /// делает сам (она канонизация, а не требование к клиенту), а вот повторы и
    /// диапазон — отказ: `Planner.weekGrid` схлопывает дубликаты МОЛЧА, и набор
    /// `{2,2,4}` дал бы два дня вместо трёх (§7.2).
    static func validate(_ body: PatchProfileRequest) throws {
        guard let outer = body.trainingWeekdays else {
            // Набор не трогают. Тогда и число дней прислать нельзя: пара
            // пишется целиком (§3.1, `profiles_weekdays_paired`).
            if body.daysPerWeek != nil {
                throw APIError(.validationFailed, details: ["field": .string("days_per_week")])
            }
            return
        }
        guard let weekdays = outer else {
            // Явный null — снять пару целиком. Число дней при этом бессмысленно.
            if body.daysPerWeek != nil {
                throw APIError(.validationFailed, details: ["field": .string("days_per_week")])
            }
            return
        }
        guard !weekdays.isEmpty, weekdays.count <= 7,
              weekdays.allSatisfy({ (1...7).contains($0) }),
              Set(weekdays).count == weekdays.count
        else {
            throw APIError(.validationFailed, details: ["field": .string("training_weekdays")])
        }
        if let declared = body.daysPerWeek, declared != weekdays.count {
            // Контрольная сумма не сошлась (§20.3): число выводится из набора, и
            // расхождение означает, что клиент считает иначе, чем прислал.
            throw APIError(.validationFailed, details: [
                "field": .string("days_per_week"),
                "training_weekdays": .int(weekdays.count)
            ])
        }
    }
}
