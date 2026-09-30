//  Обвяз живых тестов недельного блока (SPEC §20.15).
//
//  Всё, что 20a, 20d и 20j требуют и чего не даёт `swift test` сам по себе:
//  поднятый сервер, настоящие JWT двух пользователей, живой Postgres с
//  применёнными миграциями и включённой RLS.
//
//  ── Запуск ─────────────────────────────────────────────────────────────────
//
//    supabase start && supabase migration up --local
//    psql ... -c "alter role fitserver with password 'fitserver'"
//
//    FITTRACK_LIVE_ISSUER=http://127.0.0.1:54321/auth/v1 \
//    FITTRACK_ANON_KEY=<publishable key из `supabase status`> \
//    FITTRACK_DB_PASSWORD=fitserver \
//    swift test
//
//  Без переменных набор пропускается: `swift test` обязан оставаться зелёным
//  без Docker (§20.4, server-domain §4). Пароль роли — конфигурация среды, а не
//  схема (§20.4), и после `supabase db reset` его нужно задать заново: CLI
//  пересоздаёт кастомные роли без пароля.
//
//  ── Почему профиль сеется SQL-ом в обход границы ──────────────────────────
//
//  Потому что пути записи `profiles` пока нет: решение A1 его завело в §20.3,
//  но `PATCH /v1/profile` не реализован. Посев идёт от `postgres`, то есть мимо
//  RLS и мимо сервера, и это осознанная временная мера — она НЕ ослабляет 20a:
//  тот проверяет, что эндпоинты не отдают чужих строк, и посев чужими руками
//  делает утверждение только строже. Когда `PATCH /v1/profile` появится, посев
//  обязан переехать на него: сегодняшний обход — единственное место во всём
//  наборе, где тест знает про схему больше, чем клиент.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import FitContent
import Logging
import PostgresNIO
import Testing
import Vapor
import VaporTesting
@testable import FitServer

enum Live {
    static let issuer = ProcessInfo.processInfo.environment["FITTRACK_LIVE_ISSUER"]
    static let anonKey = ProcessInfo.processInfo.environment["FITTRACK_ANON_KEY"]
    static let dbPassword = ProcessInfo.processInfo.environment["FITTRACK_DB_PASSWORD"]
    static let dbHost = ProcessInfo.processInfo.environment["FITTRACK_DB_HOST"] ?? "127.0.0.1"
    static let dbPort = Int(ProcessInfo.processInfo.environment["FITTRACK_DB_PORT"] ?? "54322") ?? 54322

    static var enabled: Bool { issuer != nil && anonKey != nil && dbPassword != nil }

    enum Failure: Error, CustomStringConvertible {
        case signUp(Int, String)
        case seed(String)

        var description: String {
            switch self {
            case .signUp(let status, let body): return "signup \(status): \(body)"
            case .seed(let message): return "посев: \(message)"
            }
        }
    }

    /// Настоящий анонимный пользователь: настоящий `auth.uid()` и токен,
    /// подписанный ключом из живого JWKS.
    struct User: Sendable {
        let id: UUID
        let token: String

        var headers: HTTPHeaders { HTTPHeaders([("Authorization", "Bearer \(token)")]) }
    }

    static func signUpAnonymous() async throws -> User {
        var request = URLRequest(url: URL(string: issuer! + "/signup")!)
        request.httpMethod = "POST"
        request.setValue(anonKey!, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure.signUp(status, String(decoding: data, as: UTF8.self))
        }
        struct Body: Decodable {
            struct User: Decodable { let id: UUID }
            let access_token: String
            let user: User
        }
        let body = try JSONDecoder().decode(Body.self, from: data)
        return User(id: body.user.id, token: body.access_token)
    }

    // MARK: - Посев

    /// Прямое соединение владельцем — только для посева и только пока нет
    /// `PATCH /v1/profile` (см. шапку файла).
    private static func ownerClient(_ logger: Logger) -> PostgresClient {
        var configuration = PostgresClient.Configuration(
            host: dbHost, port: dbPort, username: "postgres", password: "postgres",
            database: "postgres", tls: .disable)
        configuration.options.minimumConnections = 0
        return PostgresClient(configuration: configuration, backgroundLogger: logger)
    }

    /// Минимальный профиль: четыре обязательных значения и инвентарь.
    ///
    /// Три дня (пн/ср/пт) и уровень выше новичка — чтобы сетка §7.2 дала три
    /// РАЗНЫХ типа дня (верх / низ / full body), а не три одинаковых: на
    /// одинаковых часть утверждений о плане выродилась бы.
    static func seedProfile(_ user: User, logger: Logger) async throws {
        let client = ownerClient(logger)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            group.addTask {
                _ = try await client.query("""
                    insert into profiles (id, experience_level, goal, days_per_week,
                                          training_weekdays, session_minutes)
                    values (\(user.id), 'intermediate', 'hypertrophy', 3, '{1,3,5}', 60)
                    on conflict (id) do nothing
                    """, logger: logger)
                _ = try await client.query("""
                    insert into equipment_profiles (id, user_id, name, is_default, dumbbells_kg,
                                                    plates_kg, barbell_kg, bands, pullup_bar, bench)
                    values (\(UUID()), \(user.id), 'Зал', true,
                            '{4,6,8,10,12,14,16,18,20,24,28,32}', '{1.25,2.5,5,10,20}', 20,
                            true, true, 'adjustable')
                    on conflict do nothing
                    """, logger: logger)
                _ = try await client.query("""
                    insert into parq_responses (user_id, answers, has_red_flag, acknowledged,
                                                completed_at)
                    values (\(user.id), '{}'::jsonb, false, true, now())
                    on conflict (user_id) do nothing
                    """, logger: logger)
            }
            try await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Сервер

    static func quietLogger(_ label: String) -> Logger {
        var logger = Logger(label: label)
        logger.logLevel = .critical
        return logger
    }

    static func makeDatabase(_ logger: Logger) async throws -> Database {
        let auth = try AuthConfiguration(issuer: issuer!)
        let cache = JWKSCache(source: HTTPJWKSSource(configuration: auth), configuration: auth)
        // Без набора ключей любой токен получил бы 503, и тест упал бы в месте,
        // не имеющем отношения к утверждению.
        try await cache.start()
        return Database(
            configuration: try DatabaseConfiguration(
                host: dbHost, port: dbPort, password: dbPassword!, tls: .disable,
                minimumConnections: 0),
            verifier: TokenVerifier(configuration: auth, cache: cache),
            logger: logger)
    }

    /// Поднимает сервер со всеми смонтированными путями и отдаёт его телу теста.
    ///
    /// `run()` пула крутится в той же группе и отменяется по выходу: без него
    /// `withUserTransaction` соединения не получит.
    static func withServer(_ label: String,
                           _ body: @escaping @Sendable (Application) async throws -> Void) async throws {
        let logger = quietLogger(label)
        let database = try await makeDatabase(logger)
        let library = try Content.loadBundled()
        let store = try ContentStore(library: library)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await database.run() }
            group.addTask {
                try await withApp { app in
                    app.logger = logger
                    Routes.register(on: app, content: store, library: library, database: database)
                    try await body(app)
                }
            }
            try await group.next()
            group.cancelAll()
        }
    }
}
