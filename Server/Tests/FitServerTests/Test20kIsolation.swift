//  Тест 20k (§20.15): изоляция на уровне `DB/`, без HTTP.
//
//  Два настоящих JWT двух пользователей проходят через настоящую точку входа в
//  транзакцию: настоящий пул, настоящая роль `fitserver`, настоящий
//  `set_config`, настоящая RLS §3.2. Всё, кроме HTTP и роутов.
//
//  **20k не заменяет 20a и заменять не может.** 20a утверждает, что ни один
//  ЭНДПОИНТ не отдаёт чужие строки; 20k не знает об эндпоинтах ничего, потому
//  что их ещё нет — они ждут `Mapping/`, а тот ждёт непустой `FitContent`.
//  Отдельный номер существует ровно затем, чтобы 20a нельзя было отметить
//  сделанным (§20.4).
//
//  Здесь же — вторая половина утверждения 20b. Там `leaseCount == 0`
//  доказывает, что до БД не дошли, но сам по себе ноль был бы и у сломанного
//  счётчика. Подвижность счётчика на успешном запросе утверждается ЗДЕСЬ, и
//  только вместе эти две половины что-то значат.
//
//  ── Запуск ─────────────────────────────────────────────────────────────────
//
//    FITTRACK_LIVE_ISSUER=http://127.0.0.1:54321/auth/v1 \
//    FITTRACK_ANON_KEY=<publishable key из `supabase status`> \
//    FITTRACK_DB_PASSWORD=fitserver \
//    swift test
//
//  Без переменных набор пропускается: `swift test` обязан оставаться зелёным
//  без Docker (§20.4, server-domain §4).
//
//  Пароль роли исчезает после каждого `supabase db reset` — CLI удаляет
//  кастомные роли вместе с базой, и `0008` создаёт `fitserver` заново уже без
//  пароля. Поэтому отказ аутентификации назван отдельным случаем
//  `DatabaseFailure.authenticationFailed` и проверяется явно: ненастроенная
//  среда не должна выглядеть сломанной изоляцией.

import Testing
import Foundation
import PostgresNIO
import Logging
@testable import FitServer

private let issuer = ProcessInfo.processInfo.environment["FITTRACK_LIVE_ISSUER"]
private let anonKey = ProcessInfo.processInfo.environment["FITTRACK_ANON_KEY"]
private let dbPassword = ProcessInfo.processInfo.environment["FITTRACK_DB_PASSWORD"]
private let dbHost = ProcessInfo.processInfo.environment["FITTRACK_DB_HOST"] ?? "127.0.0.1"
private let dbPort = Int(ProcessInfo.processInfo.environment["FITTRACK_DB_PORT"] ?? "54322") ?? 54322

private let live = issuer != nil && anonKey != nil && dbPassword != nil

/// Анонимный пользователь локального проекта: настоящий `auth.uid()` и
/// настоящий токен, подписанный ключом из живого JWKS.
private struct LiveUser {
    let id: UUID
    let token: String
}

@Suite("20k: изоляция через DB/, без HTTP (§20.15)", .enabled(if: live))
struct Test20kIsolation {

    // MARK: - Обвязка

    private func signUpAnonymous() async throws -> LiveUser {
        var request = URLRequest(url: URL(string: issuer! + "/signup")!)
        request.httpMethod = "POST"
        request.setValue(anonKey!, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LiveSetupError.signUpFailed(status, String(decoding: data, as: UTF8.self))
        }
        struct Body: Decodable {
            struct User: Decodable { let id: UUID }
            let access_token: String
            let user: User
        }
        let body = try JSONDecoder().decode(Body.self, from: data)
        return LiveUser(id: body.user.id, token: body.access_token)
    }

    private enum LiveSetupError: Error {
        case signUpFailed(Int, String)
    }

    private func makeDatabase() async throws -> Database {
        let auth = try AuthConfiguration(issuer: issuer!)
        let cache = JWKSCache(source: HTTPJWKSSource(configuration: auth), configuration: auth)
        // Старт обязателен и здесь: без набора ключей любой токен получил бы
        // 503, и тест упал бы в месте, не имеющем отношения к изоляции.
        try await cache.start()

        let logger: Logger = {
            var logger = Logger(label: "test.20k")
            logger.logLevel = .critical
            return logger
        }()
        return Database(
            configuration: try DatabaseConfiguration(
                host: dbHost, port: dbPort, password: dbPassword!, tls: .disable,
                minimumConnections: 0
            ),
            verifier: TokenVerifier(configuration: auth, cache: cache),
            logger: logger
        )
    }

    /// Поднимает пул на время тела теста и гасит его после.
    private func withDatabase<R: Sendable>(
        _ body: @Sendable @escaping (Database) async throws -> R
    ) async throws -> R {
        let database = try await makeDatabase()
        return try await withThrowingTaskGroup(of: R?.self) { group in
            group.addTask { await database.run(); return nil }
            group.addTask { try await body(database) }

            while let next = try await group.next() {
                if let value = next {
                    group.cancelAll()
                    return value
                }
            }
            fatalError("пул завершился раньше тела теста")
        }
    }

    private func count(_ transaction: UserTransaction, of table: String) async throws -> Int {
        // Имя таблицы — литерал из этого файла, а не вход: интерполяция
        // `PostgresQuery` привязала бы его параметром, чего `from` не примет.
        let rows = try await transaction.query(PostgresQuery(unsafeSQL: "select count(*) from \(table)"))
        for try await row in rows { return try row.decode(Int.self) }
        return -1
    }

    // MARK: - Утверждения

    /// Сердце теста: чужие строки не видны, свои видны, и видно их ровно
    /// столько, сколько записано.
    @Test("Два настоящих JWT: каждый видит своё и ноль чужого")
    func isolationBetweenTwoRealTokens() async throws {
        let a = try await signUpAnonymous()
        let b = try await signUpAnonymous()

        try await withDatabase { database in
            // A пишет свою строку — через тот же путь, а не в обход как
            // `rls_isolation.sh`. Запись под своим `auth.uid()` проходит
            // `with check` §3.2; если бы подстановка не сработала, отказ
            // пришёл бы уже здесь.
            try await database.withUserTransaction(authorization: "Bearer \(a.token)") { tx -> Void in
                try await tx.query("""
                    insert into profiles (id, experience_level, goal, days_per_week, training_weekdays)
                    values (\(a.id), 'novice', 'strength', 3, \([1, 3, 5] as [Int16]))
                    """)
            }

            let seenByB = try await database.withUserTransaction(authorization: "Bearer \(b.token)") { tx in
                try await self.count(tx, of: "profiles")
            }
            #expect(seenByB == 0, "B увидел строки A — изоляция §3.2 на пути сервера сломана")

            let seenByA = try await database.withUserTransaction(authorization: "Bearer \(a.token)") { tx in
                try await self.count(tx, of: "profiles")
            }
            #expect(seenByA == 1, "A не видит собственную строку — политика слишком строгая или запись не легла")

            // Уборка: своей же ролью, своим же путём.
            try await database.withUserTransaction(authorization: "Bearer \(a.token)") { tx -> Void in
                try await tx.query("delete from profiles where id = \(a.id)")
            }
        }
    }

    /// Подстановка действительно произошла, а не «просто ничего не видно».
    ///
    /// Разница существенная: пустой результат дала бы и роль, которой ничего не
    /// разрешено, и сломанный запрос. Здесь утверждается, что внутри транзакции
    /// роль — `authenticated`, `auth.uid()` равен `sub` токена, а уровень
    /// изоляции — тот, что обещает §20.4.
    @Test("Внутри транзакции: роль, auth.uid() и repeatable read")
    func substitutionIsActuallyInEffect() async throws {
        let user = try await signUpAnonymous()

        try await withDatabase { database in
            let (role, uid, isolation) = try await database.withUserTransaction(
                authorization: "Bearer \(user.token)"
            ) { tx -> (String, UUID?, String) in
                let rows = try await tx.query("""
                    select current_user::text, auth.uid(), current_setting('transaction_isolation')
                    """)
                for try await row in rows {
                    return try row.decode((String, UUID?, String).self)
                }
                throw LiveSetupError.signUpFailed(0, "пустой ответ")
            }

            #expect(role == "authenticated")
            #expect(uid == user.id, "auth.uid() не равен sub токена — claims доехали не те")
            #expect(isolation == "repeatable read")
        }
    }

    /// Вторая половина утверждения 20b (§20.4): счётчик аренд ДВИГАЕТСЯ.
    ///
    /// Без неё «ноль аренд» в 20b доказывал бы только то, что счётчик не
    /// работает.
    @Test("leaseCount растёт на успешном запросе — иначе ноль в 20b ничего не значит")
    func leaseCounterMovesOnTheHappyPath() async throws {
        let user = try await signUpAnonymous()

        try await withDatabase { database in
            let before = await database.leaseCount
            #expect(before == 0)

            try await database.withUserTransaction(authorization: "Bearer \(user.token)") { tx -> Void in
                _ = try await self.count(tx, of: "profiles")
            }

            let after = await database.leaseCount
            #expect(after == before + 1, "счётчик аренд не сдвинулся — наблюдатель 20b мёртв")
        }
    }

    /// Вторая половина самого 20k (§20.15): роль без подстановки не читает
    /// НИЧЕГО, а не читает всё.
    ///
    /// Идёт мимо `Database` намеренно — она подставляет роль всегда, и обойти
    /// её изнутри нечем. Проверяется свойство роли из миграции `0008`, а не
    /// поведение кода: именно оно отличает «изоляция держится на базе» от
    /// «изоляция держится на том, что никто не забыл».
    @Test("fitserver без подстановки: permission denied, а не чужие строки")
    func roleWithoutSubstitutionReadsNothing() async throws {
        var configuration = PostgresClient.Configuration(
            host: dbHost, port: dbPort, username: "fitserver",
            password: dbPassword!, database: "postgres", tls: .disable
        )
        configuration.options.minimumConnections = 0
        let logger: Logger = {
            var logger = Logger(label: "test.20k.raw")
            logger.logLevel = .critical
            return logger
        }()
        let client = PostgresClient(configuration: configuration, backgroundLogger: logger)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            group.addTask {
                var sqlState: String?
                do {
                    _ = try await client.query("select count(*) from profiles", logger: logger)
                } catch let error as PSQLError {
                    sqlState = error.serverInfo?[.sqlState]
                } catch {
                    sqlState = "неожиданная ошибка: \(error)"
                }
                // 42501 — insufficient_privilege. Именно отказ, а не пустая
                // выборка: пустая означала бы, что права есть, а строк нет.
                #expect(sqlState == "42501", "роль без подстановки получила доступ к таблице")
            }
            await group.next()
            group.cancelAll()
        }
    }
}
