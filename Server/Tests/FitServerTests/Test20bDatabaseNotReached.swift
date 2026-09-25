//  Тест 20b, вторая половина (§20.15): при отказе `Auth/` запрос до БД не
//  доходит.
//
//  Первая половина — что именно отклоняется и с каким кодом — живёт в
//  `Test20bTokenVerification.swift` и обходится без `DB/`. Здесь проверяется
//  ПОРЯДОК, а это утверждение отрицательное: «соединение из пула не арендовано
//  ни разу». Отрицательное утверждение требует наблюдателя, и наблюдатель —
//  `Database.leaseCount`, счётчик на боевом пути, а не заглушка рядом с ним.
//
//  **Сам по себе «ноль» здесь не доказывает ничего**: он был бы нулём и у
//  счётчика, который не работает. Подвижность счётчика утверждает 20k, на живой
//  базе, и без той половины эта — украшение. Это сказано и в SPEC §20.4, и
//  повторено здесь, чтобы никто не «упростил» 20k, оставив 20b зелёным.
//
//  Пул намеренно направлен на закрытый порт, и это вторая половина ловушки.
//  Если порядок однажды перевернётся — сначала аренда, потом проверка, — тест
//  не просто увидит `leaseCount == 1`: он получит ошибку соединения вместо
//  `AuthFailure`, то есть провалится дважды и по разным причинам. `run()`
//  крутится ради того же: без него аренда повисла бы в ожидании соединения
//  навсегда, и регрессия выглядела бы как зависший тест, а не как красный.

import Testing
import Foundation
import PostgresNIO
import Logging
@testable import FitServer

/// Источник JWKS, который никогда не отвечает. Достаточен: все три случая ниже
/// отклоняются до того, как ключ вообще понадобится, — кроме последнего, где
/// пустой кеш и есть проверяемое условие.
private struct SilentJWKS: JWKSSource {
    struct Unreachable: Error {}
    func fetch() async throws -> String { throw Unreachable() }
}

/// Порт, на котором заведомо никто не слушает: аренда соединения обязана
/// провалиться быстро и громко, если она вообще случится.
private let closedPort = 54399

@Suite("20b: до БД запрос не доходит (§20.15)")
struct Test20bDatabaseNotReached {

    private func makeDatabase() throws -> Database {
        let auth = try AuthConfiguration(issuer: "https://example.test/auth/v1")
        let cache = JWKSCache(source: SilentJWKS(), configuration: auth)
        let db = try DatabaseConfiguration(
            host: "127.0.0.1",
            port: closedPort,
            password: "irrelevant",
            tls: .disable,
            // Ноль, а не боевые два: тёплые соединения к закрытому порту
            // засыпали бы вывод теста ошибками, к утверждению не относящимися.
            minimumConnections: 0
        )
        var logger = Logger(label: "test.20b")
        logger.logLevel = .critical
        return Database(
            configuration: db,
            verifier: TokenVerifier(configuration: auth, cache: cache),
            logger: logger
        )
    }

    /// Прогоняет запрос с заведомо негодным заголовком и возвращает, что
    /// случилось: ошибку, число аренд и факт входа в тело запроса.
    private func attempt(
        authorization: String?
    ) async -> (error: (any Error)?, leases: Int, bodyRan: Bool) {
        let database: Database
        do { database = try makeDatabase() } catch {
            return (error, 0, false)
        }
        let bodyRan = Flag()

        return await withTaskGroup(of: Void.self) { group in
            group.addTask { await database.run() }

            var thrown: (any Error)?
            do {
                try await database.withUserTransaction(authorization: authorization) { _ in
                    await bodyRan.raise()
                }
            } catch {
                thrown = error
            }
            let leases = await database.leaseCount
            let ran = await bodyRan.value
            group.cancelAll()
            return (thrown, leases, ran)
        }
    }

    @Test("Мусор вместо токена: 401, ноль аренд, тело не выполнялось")
    func malformedToken() async {
        let outcome = await attempt(authorization: "Bearer not-a-token")

        #expect(outcome.error as? AuthFailure == .unauthorized(.malformedToken))
        #expect(outcome.leases == 0)
        #expect(outcome.bodyRan == false)
    }

    @Test("Заголовка нет вовсе: тоже 401 и тоже ноль аренд")
    func missingHeader() async {
        let outcome = await attempt(authorization: nil)

        #expect(outcome.error as? AuthFailure == .unauthorized(.malformedToken))
        #expect(outcome.leases == 0)
    }

    @Test("Чужая схема авторизации до БД не доходит")
    func wrongScheme() async {
        let outcome = await attempt(authorization: "Basic dXNlcjpwYXNz")

        #expect(outcome.error as? AuthFailure == .unauthorized(.malformedToken))
        #expect(outcome.leases == 0)
    }

    /// Отдельный случай, потому что это НЕ 401: ключей нет, ответ 503, и путь
    /// внутри `Auth/` другой (§20.5). Порядок обязан держаться и на нём —
    /// иначе «до БД не доходит» верно только для части отказов.
    @Test("JWKS недоступен: 503 и всё равно ноль аренд")
    func jwksUnavailable() async {
        // Три сегмента и настоящий заголовок с `kid`: токен обязан дожить до
        // похода за ключом, иначе случай подменился бы на `malformedToken`.
        let header = Data(#"{"alg":"ES256","kid":"unknown"}"#.utf8).base64URLEncodedString()
        let payload = Data(#"{"sub":"x"}"#.utf8).base64URLEncodedString()
        let outcome = await attempt(authorization: "Bearer \(header).\(payload).c2ln")

        #expect(outcome.error as? AuthFailure == .jwksUnavailable)
        #expect(outcome.leases == 0)
        #expect(outcome.bodyRan == false)
    }

    /// Регистр схемы значения не имеет (RFC 7235), и это проверяется здесь же:
    /// иначе правило жило бы только в комментарии. Отказ всё равно приходит от
    /// `Auth/`, потому что сам токен негоден.
    @Test("Схема `bearer` в нижнем регистре принимается как схема")
    func lowercaseScheme() async {
        let outcome = await attempt(authorization: "bearer not-a-token")

        #expect(outcome.error as? AuthFailure == .unauthorized(.malformedToken))
        #expect(outcome.leases == 0)
    }
}

/// Однократный флаг: выполнялось ли тело запроса.
private actor Flag {
    private(set) var value = false
    func raise() { value = true }
}

extension Data {
    fileprivate func base64URLEncodedString() -> String {
        var s = base64EncodedString()
        s = String(s.map { $0 == "+" ? "-" : ($0 == "/" ? "_" : $0) })
        while s.hasSuffix("=") { s.removeLast() }
        return s
    }
}
