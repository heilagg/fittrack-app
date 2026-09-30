//  Каждый смонтированный путь без токена отвечает 401 (SPEC §20.5).
//
//  ── Почему список берётся из роутера, а не пишется руками ─────────────────
//
//  Утверждение здесь не про конкретные пути, а про ВСЕ. Список, который ведут
//  руками, проверяет ровно то, что в него внесли, — и новый путь оказывается
//  непокрытым ровно в тот момент, когда его написали и о нём думают меньше
//  всего. Именно так и вышло: разбор тела до проверки токена прожил во всех
//  четырёх недельных путях с их появления, потому что утверждение про 401 было
//  написано для одного из них.
//
//  Поэтому тест спрашивает у самого `Application`, что смонтировано, и обходит
//  это. Новый путь попадает под проверку в тот момент, когда его добавили в
//  `Routes.register`, и забыть его нельзя — забыть можно только смонтировать.
//
//  ── Что ведётся руками, и почему именно оно ───────────────────────────────
//
//  Ровно одно: список ПУБЛИЧНЫХ путей. §20.5 называет их поимённо и объясняет,
//  почему их два и почему третьего не будет: контент у всех один и тот же,
//  пользовательских строк не несёт и к `auth.uid()` не обращается. Список из
//  двух строк здесь — не дубликат роутера, а утверждение о границе: путь,
//  который окажется публичным и не назван тут, уронит тест.
//
//  ── Базы этому тесту не нужно ─────────────────────────────────────────────
//
//  И это не удобство, а то же самое свойство, которое утверждает вторая
//  половина 20b: отказ `Auth/` происходит ДО аренды соединения (§20.4). Пул
//  здесь построен на закрытый порт и ни разу не используется — если однажды
//  окажется, что используется, тест повиснет или упадёт, и это будет верный
//  сигнал.

import Testing
import Foundation
import FitAPI
import FitContent
import Logging
import Vapor
import VaporTesting
@testable import FitServer

private struct NeverJWKS: JWKSSource {
    struct Unreachable: Error {}
    func fetch() async throws -> String { throw Unreachable() }
}

@Suite("Смонтированные пути: без токена — 401 (§20.5)")
struct MountedPathsTests {

    /// Публичные пути §20.5. Ведётся руками намеренно — см. шапку.
    static let publicPaths: Set<String> = ["/v1/content/exercises", "/v1/content/stretches"]

    /// Пул на закрытый порт: он не должен понадобиться (§20.4).
    private static func idleDatabase() throws -> Database {
        let auth = try AuthConfiguration(issuer: "https://example.test/auth/v1")
        var logger = Logger(label: "test.mounted")
        logger.logLevel = .critical
        return Database(
            configuration: try DatabaseConfiguration(host: "127.0.0.1", port: 1,
                                                     password: "irrelevant", tls: .disable,
                                                     minimumConnections: 0),
            verifier: TokenVerifier(configuration: auth,
                                    cache: JWKSCache(source: NeverJWKS(), configuration: auth)),
            logger: logger)
    }

    private static func withMountedApp(_ body: (Application) async throws -> Void) async throws {
        let library = try Content.loadBundled()
        let store = try ContentStore(library: library)
        let database = try idleDatabase()
        try await withApp { app in
            Routes.register(on: app, content: store, library: library, database: database)
            try await body(app)
        }
    }

    /// Конкретный URI из шаблона маршрута.
    ///
    /// Значения подставляются правдоподобные, но разбираются они всё равно
    /// ПОСЛЕ проверки токена (§20.4), так что на результат не влияют. Взяты
    /// настоящие только затем, чтобы падение теста нельзя было списать на
    /// заведомо негодный путь.
    static func uri(for route: Route) -> String {
        "/" + route.path.map { component in
            switch component {
            case .constant(let value): return value
            case .parameter(let name):
                return name == "week_start" ? "2026-09-28" : UUID().uuidString
            case .anything: return "x"
            case .catchall: return "x"
            }
        }.joined(separator: "/")
    }

    @Test("роутер вообще что-то смонтировал")
    func routerIsNotEmpty() async throws {
        try await Self.withMountedApp { app in
            let paths = app.routes.all.map { Self.uri(for: $0) }
            #expect(paths.count >= 8, "восемь путей §20.3 на сегодня; получено: \(paths.count)")
        }
    }

    @Test("публичны ровно два пути контента, и ни одним больше (§20.5)")
    func exactlyTwoPublicPaths() async throws {
        try await Self.withMountedApp { app in
            var public_: Set<String> = []
            for route in app.routes.all {
                let uri = Self.uri(for: route)
                var status: HTTPResponseStatus = .internalServerError
                try await app.testing().test(route.method, uri) { status = $0.status }
                if status != .unauthorized { public_.insert(uri) }
            }
            #expect(public_ == Self.publicPaths,
                    "публичный путь, не названный в §20.5, — это решение, а не деталь")
        }
    }

    @Test("каждый непубличный путь без токена отвечает 401 с конвертом §20.3")
    func everyPrivatePathRefusesWithoutToken() async throws {
        try await Self.withMountedApp { app in
            var checked = 0
            for route in app.routes.all {
                let uri = Self.uri(for: route)
                guard !Self.publicPaths.contains(uri) else { continue }
                checked += 1
                try await app.testing().test(route.method, uri) { response in
                    #expect(response.status == .unauthorized, "\(route.method) \(uri)")
                    let envelope = try JSONDecoder().decode(APIErrorEnvelope.self,
                                                            from: Data(buffer: response.body))
                    #expect(envelope.error.code == .unauthorized, "\(route.method) \(uri)")
                    #expect(!envelope.error.message.isEmpty)
                }
            }
            #expect(checked >= 6, "шесть непубличных путей на сегодня; проверено: \(checked)")
        }
    }

    /// Тело не разбирается раньше токена (§20.4): негодный JSON у клиента без
    /// токена обязан давать 401, а не `validation_failed`.
    @Test("негодное тело без токена — всё равно 401, а не 422")
    func malformedBodyStillYields401() async throws {
        try await Self.withMountedApp { app in
            var checked = 0
            for route in app.routes.all where route.method != .GET {
                let uri = Self.uri(for: route)
                guard !Self.publicPaths.contains(uri) else { continue }
                checked += 1
                try await app.testing().test(route.method, uri, beforeRequest: { request in
                    request.headers.contentType = .json
                    request.body = ByteBuffer(string: "{ это не json ")
                }) { response in
                    #expect(response.status == .unauthorized, "\(route.method) \(uri)")
                }
            }
            #expect(checked >= 4, "проверено путей с телом: \(checked)")
        }
    }

    /// Негодная схема авторизации — тоже 401, и тоже до всего остального.
    @Test("чужая схема авторизации отклоняется так же")
    func foreignAuthorizationSchemeIsRefused() async throws {
        try await Self.withMountedApp { app in
            let headers = HTTPHeaders([("Authorization", "Basic YWxpY2U6c2VjcmV0")])
            for route in app.routes.all {
                let uri = Self.uri(for: route)
                guard !Self.publicPaths.contains(uri) else { continue }
                try await app.testing().test(route.method, uri, headers: headers) { response in
                    #expect(response.status == .unauthorized, "\(route.method) \(uri)")
                }
            }
        }
    }

    /// Публичные пути токена не читают вовсе (§20.5): негодный токен на них не
    /// даёт 401 никогда.
    @Test("негодный токен на публичных путях игнорируется")
    func publicPathsIgnoreBadTokens() async throws {
        try await Self.withMountedApp { app in
            let headers = HTTPHeaders([("Authorization", "Bearer совершенно-негодный")])
            for path in Self.publicPaths {
                try await app.testing().test(.GET, path, headers: headers) { response in
                    #expect(response.status == .ok, "\(path)")
                }
            }
        }
    }
}
