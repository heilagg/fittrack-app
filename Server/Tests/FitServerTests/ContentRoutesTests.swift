//  `GET /v1/content/*` через HTTP (SPEC §20.3, §20.5, §20.11).
//
//  Номера §20.15 за этими путями не закреплено: §20.11 — утверждение про байты
//  и их хеш, и оно уже закрыто `ContentStoreTests` без HTTP-обвязки. Здесь
//  проверяется ровно то, что добавляет роут и чего в store нет: версия в пути,
//  коды ответов, заголовки, публичность и конверт ошибки §20.3.
//
//  Заодно это первый прогон эндпоинта через настоящий HTTP в этом пакете — то,
//  без чего 20a и вторая половина 20d невозможны в принципе.

import Testing
import Foundation
import FitAPI
import FitContent
import Logging
import Vapor
import VaporTesting
@testable import FitServer

/// Источник ключей, который никогда не отвечает: контентные пути токена не
/// читают (§20.5), и настоящий JWKS им не нужен.
private struct UnreachableJWKS: JWKSSource {
    struct Never: Error {}
    func fetch() async throws -> String { throw Never() }
}

@Suite("Роуты контента /v1/content/* (§20.3, §20.11)")
struct ContentRoutesTests {

    /// Библиотека из одного упражнения и одной растяжки: пустой срез не
    /// отличил бы «отдали тело» от «отдали ничего», а разметки в пакете пока
    /// ноль (§20.11).
    static func library() -> ContentLibrary {
        ContentLibrary(
            exercises: [
                ExerciseSchema(
                    slug: "push-up", name: "Отжимание", pattern: .pushH,
                    muscleContributions: [.pecs: 0.6, .triceps: 0.4],
                    equipment: [], equipmentOptional: [], loadType: .bodyweight,
                    unilateral: false, jointStress: [:], impact: .none,
                    skillLevel: .novice, defaultRestSeconds: 90, fatigueCost: 1.0,
                    alternatives: [], progressionFamily: "push-up",
                    familyLoadRatio: nil, setupSeconds: 10,
                    cues: ["Корпус прямой"], commonErrors: ["Провал таза"],
                    illustration: "push-up"
                )
            ],
            vectors: DayVectorTable([]),
            stretches: [
                StretchSchema(slug: "evening", name: "Вечерняя", durationMinutes: 10,
                              purpose: "Расслабление")
            ]
        )
    }

    /// Пул, который никуда не ходит.
    ///
    /// `Routes.register` монтирует ВСЁ, что есть, одним вызовом (иначе путь
    /// однажды окажется смонтирован без конверта ошибок), поэтому база ему
    /// нужна. Здесь она нужна только как значение: `Database.init` соединений
    /// не открывает — их берёт `run()`, который тут не запускается, — а
    /// контентные пути к ней не обращаются вовсе (§20.5).
    static func idleDatabase() throws -> Database {
        let auth = try AuthConfiguration(issuer: "https://example.test/auth/v1")
        var logger = Logger(label: "test.content-routes")
        logger.logLevel = .critical
        return Database(
            configuration: try DatabaseConfiguration(host: "127.0.0.1", port: 1,
                                                     password: "irrelevant", tls: .disable,
                                                     minimumConnections: 0),
            verifier: TokenVerifier(configuration: auth,
                                    cache: JWKSCache(source: UnreachableJWKS(), configuration: auth)),
            logger: logger
        )
    }

    static func withServer(_ body: (Application, ContentStore) async throws -> Void) async throws {
        let store = try ContentStore(library: library())
        let database = try idleDatabase()
        try await withApp { app in
            Routes.register(on: app, content: store, library: library(), database: database)
            try await body(app, store)
        }
    }

    // MARK: - Тело и заголовки

    @Test("оба пути отдают 200, байты store и его ETag",
          arguments: ContentPath.allCases)
    func servesBytesAndETag(path: ContentPath) async throws {
        try await Self.withServer { app, store in
            try await app.testing().test(.GET, path.route) { response in
                #expect(response.status == .ok)
                #expect(Data(buffer: response.body) == store[path].bytes)
                #expect(response.headers.first(name: .eTag) == store[path].etag)
                #expect(response.headers.first(name: .cacheControl) == ContentStore.cacheControl)
                #expect(response.headers.contentType == .json)
            }
        }
    }

    @Test("у двух путей разные ETag — правка растяжки не сбрасывает кеш библиотеки")
    func pathsHaveDistinctETags() async throws {
        try await Self.withServer { _, store in
            #expect(store[.exercises].etag != store[.stretches].etag)
        }
    }

    // MARK: - Условный запрос

    @Test("If-None-Match со своим ETag даёт 304 без тела",
          arguments: ContentPath.allCases)
    func returnsNotModified(path: ContentPath) async throws {
        try await Self.withServer { app, store in
            let headers = HTTPHeaders([("If-None-Match", store[path].etag)])
            try await app.testing().test(.GET, path.route, headers: headers) { response in
                #expect(response.status == .notModified)
                #expect(response.body.readableBytes == 0)
                // RFC 9110: 304 несёт те же валидирующие и кеширующие
                // заголовки, что и 200, — иначе клиент теряет основание считать
                // копию свежей, и долгий кеш §20.11 перестаёт работать ровно
                // там, где должен был сработать.
                #expect(response.headers.first(name: .eTag) == store[path].etag)
                #expect(response.headers.first(name: .cacheControl) == ContentStore.cacheControl)
            }
        }
    }

    @Test("чужой ETag даёт 200 с телом")
    func staleETagGetsBody() async throws {
        try await Self.withServer { app, store in
            let headers = HTTPHeaders([("If-None-Match", "\"не-наш\"")])
            try await app.testing().test(.GET, ContentPath.exercises.route, headers: headers) { response in
                #expect(response.status == .ok)
                #expect(Data(buffer: response.body) == store[.exercises].bytes)
            }
        }
    }

    @Test("ETag одного пути не годится для другого")
    func eTagIsPerPath() async throws {
        try await Self.withServer { app, store in
            let headers = HTTPHeaders([("If-None-Match", store[.stretches].etag)])
            try await app.testing().test(.GET, ContentPath.exercises.route, headers: headers) { response in
                #expect(response.status == .ok)
            }
        }
    }

    // MARK: - Публичность (§20.5)

    @Test("токен не требуется")
    func worksWithoutToken() async throws {
        try await Self.withServer { app, _ in
            try await app.testing().test(.GET, ContentPath.exercises.route) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test("негодный токен НЕ даёт 401: заголовок на этих путях не читается (§20.5)")
    func ignoresBadToken() async throws {
        try await Self.withServer { app, _ in
            let headers = HTTPHeaders([("Authorization", "Bearer совершенно-негодный-токен")])
            try await app.testing().test(.GET, ContentPath.exercises.route, headers: headers) { response in
                #expect(response.status == .ok)
            }
        }
    }

    // MARK: - Версия в пути и отказы

    @Test("без /v1 пути не существует")
    func versionIsRequired() async throws {
        try await Self.withServer { app, _ in
            try await app.testing().test(.GET, "/content/exercises") { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test("неизвестный путь отдаёт конверт §20.3, а не умолчание Vapor")
    func unknownPathUsesEnvelope() async throws {
        try await Self.withServer { app, _ in
            try await app.testing().test(.GET, "/v1/content/третьего-пути-нет") { response in
                #expect(response.status == .notFound)
                let envelope = try JSONDecoder().decode(APIErrorEnvelope.self, from: Data(buffer: response.body))
                #expect(envelope.error.code == .notFound)
                #expect(!envelope.error.message.isEmpty)
            }
        }
    }
}
