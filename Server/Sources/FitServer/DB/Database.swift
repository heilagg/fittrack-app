//  Пул, единственный вход в транзакцию и подстановка claims (§20.4).

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import FitAPI
import Logging
import PostgresNIO

/// Отказ на пути к данным, отдельно от `AuthFailure` (§20.5).
public enum DatabaseFailure: Error, Equatable, Sendable {

    /// Конфликт сериализации `repeatable read` воспроизвёлся и после повтора
    /// (§20.4). Это уже не гонка двух вкладок, и клиент должен об этом узнать.
    case serializationFailure

    /// Роль `fitserver` не пустили. Почти всегда это незаданный пароль после
    /// `supabase db reset`, и случай назван отдельно затем, чтобы 20k не
    /// выглядел сломанной изоляцией, когда сломана среда.
    case authenticationFailed(String)

    public var code: APIErrorCode {
        switch self {
        case .serializationFailure, .authenticationFailed: return .internal
        }
    }
}

/// Транзакция одного запроса: соединение с уже подставленными ролью и claims.
///
/// Тип существует затем, чтобы соединение нельзя было получить в обход
/// подстановки: `PostgresConnection` наружу не отдаётся, а `query` работает уже
/// внутри контекста §20.4.
public struct UserTransaction: Sendable {

    private let connection: PostgresConnection
    private let logger: Logger

    /// Проверенный токен запроса. `subject` — он же `auth.uid()`, но в SQL он
    /// не подставляется: политики §3.2 берут его из claims сами.
    public let token: VerifiedToken

    init(connection: PostgresConnection, token: VerifiedToken, logger: Logger) {
        self.connection = connection
        self.token = token
        self.logger = logger
    }

    @discardableResult
    public func query(
        _ query: PostgresQuery,
        file: String = #fileID,
        line: Int = #line
    ) async throws -> PostgresRowSequence {
        try await connection.query(query, logger: logger, file: file, line: line)
    }
}

/// Пул соединений и единственная точка входа в транзакцию (§20.4).
///
/// `run()` обязан крутиться в отдельной задаче всё время жизни пула — до него
/// `withUserTransaction` не получит соединения. Владельца этой задачи здесь
/// нет: исполняемого таргета ещё не существует, и запускает её тот, кто
/// поднимает процесс (в тестах — своя таск-группа).
public final class Database: Sendable {

    private let client: PostgresClient
    private let verifier: TokenVerifier
    private let logger: Logger
    private let leases = LeaseCounter()

    /// Сколько раз бралось соединение из пула.
    ///
    /// Не диагностика: это наблюдатель для второй половины 20b (§20.15). Он
    /// стоит на боевом пути, а не в заглушке рядом — заглушка, которой
    /// продакшен не пользуется, не доказывает ничего. Его подвижность
    /// утверждает 20k.
    public var leaseCount: Int {
        get async { await leases.value }
    }

    public init(configuration: DatabaseConfiguration, verifier: TokenVerifier, logger: Logger) {
        self.client = PostgresClient(
            configuration: configuration.makeClientConfiguration(),
            backgroundLogger: logger
        )
        self.verifier = verifier
        self.logger = logger
    }

    /// Ведёт пул. Не возвращается, пока задачу не отменят.
    public func run() async {
        await client.run()
    }

    /// Единственный способ попасть в базу (§20.4).
    ///
    /// Токен проверяется ЗДЕСЬ, а не приходит проверенным снаружи: иначе
    /// порядок «сначала проверка, потом БД» был бы свойством вызывающего слоя.
    /// Отказ `Auth/` происходит до аренды соединения, и это ровно то, что
    /// утверждает вторая половина 20b.
    ///
    /// Тело может быть выполнено ДВАЖДЫ: конфликт сериализации `repeatable
    /// read` даёт один прозрачный повтор всей транзакции (§20.4).
    public func withUserTransaction<Result: Sendable>(
        authorization: String?,
        _ body: @Sendable @escaping (UserTransaction) async throws -> Result
    ) async throws -> Result {
        let token = try await verify(authorization)

        // Повтор ровно один, и только на `40001`. Он безопасен потому, что
        // откат при `repeatable read` полон: второй проход начинается с
        // чистого листа и перечитывает вход заново (§20.4).
        do {
            return try await runTransaction(token: token, body: body)
        } catch let failure as DatabaseFailure where failure == .serializationFailure {
            // Повтор ровно один: если конфликт воспроизвёлся, эта же ошибка
            // уходит наружу — второго `catch` здесь нет намеренно.
            return try await runTransaction(token: token, body: body)
        }
    }

    private func verify(_ authorization: String?) async throws -> VerifiedToken {
        guard let authorization else { throw AuthFailure.unauthorized(.malformedToken) }
        // Схема сравнивается без учёта регистра: RFC 7235 объявляет её
        // case-insensitive, и «bearer» от честного клиента — не повод для 401.
        let parts = authorization.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else {
            throw AuthFailure.unauthorized(.malformedToken)
        }
        return try await verifier.verify(bearer: String(parts[1]))
    }

    private func runTransaction<Result: Sendable>(
        token: VerifiedToken,
        body: @Sendable @escaping (UserTransaction) async throws -> Result
    ) async throws -> Result {
        await leases.increment()
        let logger = self.logger
        do {
            return try await client.withTransaction(logger: logger) { connection in
                // Уровень — первым утверждением: `set transaction` действует,
                // пока в транзакции не выполнено ни одного запроса, а
                // `withTransaction` шлёт голый `BEGIN;` (§20.4).
                try await connection.query(
                    "set transaction isolation level repeatable read", logger: logger
                )
                // Одним утверждением, до первого чтения (§20.4). Claims едут
                // привязанным параметром и ДОСЛОВНО: пересобранный JSON
                // отбросил бы незнакомые claims, и политика, читающая
                // `auth.jwt() ->> 'email'`, получила бы null молча (§20.5).
                // Роль остаётся литералом — она константа, привязывать в ней
                // нечего, и `set local role` её всё равно не принял бы
                // параметром.
                try await connection.query(
                    """
                    select set_config('role', 'authenticated', true),
                           set_config('request.jwt.claims', \(token.claimsJSON), true)
                    """,
                    logger: logger
                )
                return try await body(
                    UserTransaction(connection: connection, token: token, logger: logger)
                )
            }
        } catch {
            if Self.isSerializationFailure(error) {
                throw DatabaseFailure.serializationFailure
            }
            if let message = Self.authenticationFailure(error) {
                throw DatabaseFailure.authenticationFailed(message)
            }
            throw error
        }
    }

    /// `40001` приезжает завёрнутым: `withTransaction` кладёт исходную ошибку в
    /// `closureError` или `commitError`, поэтому разворачивать нужно оба.
    private static func isSerializationFailure(_ error: any Error) -> Bool {
        sqlState(error) == "40001"
    }

    /// Незаданный пароль роли — самая частая поломка среды после
    /// `supabase db reset`, и путать её с отказом изоляции нельзя (§20.4).
    private static func authenticationFailure(_ error: any Error) -> String? {
        guard let state = sqlState(error), state.hasPrefix("28") else { return nil }
        return state
    }

    private static func sqlState(_ error: any Error) -> String? {
        if let transaction = error as? PostgresTransactionError {
            for nested in [transaction.closureError, transaction.commitError, transaction.beginError] {
                if let nested, let state = sqlState(nested) { return state }
            }
            return nil
        }
        if let psql = error as? PSQLError {
            return psql.serverInfo?[.sqlState]
        }
        return nil
    }
}

/// Счётчик аренд. Актор, а не атомик, потому что читается только тестами и
/// только между запросами — цена согласованности здесь нулевая.
private actor LeaseCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
