//  Проверки против НАСТОЯЩЕГО эндпоинта JWKS (§20.5).
//
//  Вынесены отдельно от 20b и включаются переменными окружения: 20b обязан
//  проходить без сети и без Supabase, а здесь проверяется ровно то, чего
//  заглушка проверить не может, — что `HTTPJWKSSource` разбирает живой ответ,
//  что живой токен проходит все пять claims, и что старт процесса
//  останавливается на пустом наборе.
//
//  Запуск:
//    FITTRACK_LIVE_ISSUER=http://127.0.0.1:54321/auth/v1 \
//    FITTRACK_LIVE_TOKEN=<access_token> swift test
//    FITTRACK_EMPTY_JWKS_ISSUER=http://127.0.0.1:8099 swift test
//
//  Откуда взять значения (локальный Supabase, `supabase start`):
//
//  FITTRACK_LIVE_TOKEN — access-токен анонимного пользователя, тем же путём,
//  что `Live.signUpAnonymous`. Ключ — publishable из `supabase status`:
//
//    curl -s -X POST http://127.0.0.1:54321/auth/v1/signup \
//      -H "apikey: <publishable key>" -H "Content-Type: application/json" \
//      -d '{}'
//
//  В ответе — поле `access_token`; его и кладут в переменную, не печатая.
//  Каждый вызов заводит в локальной базе нового анонимного пользователя. Токен
//  живёт час (`exp`), после этого тест честно упадёт на проверке срока.
//
//  FITTRACK_EMPTY_JWKS_ISSUER — любой локальный HTTP-сервер, который по пути
//  `<issuer>/.well-known/jwks.json` (так `AuthConfiguration` выводит адрес)
//  отдаёт пустой набор `{"keys":[]}`. Например:
//
//    mkdir -p /tmp/emptyjwks/.well-known
//    printf '{"keys":[]}' > /tmp/emptyjwks/.well-known/jwks.json
//    python3 -m http.server 8099 --bind 127.0.0.1 --directory /tmp/emptyjwks
//
//  и issuer `http://127.0.0.1:8099`. Сервер нужен только на время прогона.

import Testing
import Foundation
@testable import FitServer

private let liveIssuer = ProcessInfo.processInfo.environment["FITTRACK_LIVE_ISSUER"]
private let liveToken = ProcessInfo.processInfo.environment["FITTRACK_LIVE_TOKEN"]
private let emptyIssuer = ProcessInfo.processInfo.environment["FITTRACK_EMPTY_JWKS_ISSUER"]

@Suite("Живой JWKS (§20.5)")
struct LiveJWKSChecks {

    /// Старт против настоящего Supabase: ключи приезжают, набор непуст,
    /// процесс поднимается.
    @Test(.enabled(if: liveIssuer != nil))
    func live_startSucceedsAgainstARealProject() async throws {
        let configuration = try AuthConfiguration(issuer: liveIssuer!)
        let cache = JWKSCache(source: HTTPJWKSSource(configuration: configuration), configuration: configuration)
        try await cache.start()
    }

    /// Настоящий токен, выписанный Supabase, проходит проверку целиком:
    /// подпись по ключу из живого JWKS плюс все пять claims §20.5.
    @Test(.enabled(if: liveIssuer != nil && liveToken != nil))
    func live_realTokenVerifiesEndToEnd() async throws {
        let configuration = try AuthConfiguration(issuer: liveIssuer!)
        let cache = JWKSCache(source: HTTPJWKSSource(configuration: configuration), configuration: configuration)
        try await cache.start()
        let verifier = TokenVerifier(configuration: configuration, cache: cache)

        let verified = try await verifier.verify(bearer: liveToken!)
        #expect(!verified.subject.isEmpty)
        // Полезная нагрузка доехала дословно: `role` и `session_id` тип
        // `SupabaseClaims` не объявляет, а в `request.jwt.claims` они обязаны
        // попасть (§20.4).
        #expect(verified.claimsJSON.contains("\"session_id\""))
        #expect(verified.claimsJSON.contains("\"role\""))
    }

    /// Пустой набор с настоящего HTTP-эндпоинта останавливает старт процесса.
    @Test(.enabled(if: emptyIssuer != nil))
    func live_emptyKeySetRefusesToStart() async throws {
        let configuration = try AuthConfiguration(issuer: emptyIssuer!)
        let cache = JWKSCache(source: HTTPJWKSSource(configuration: configuration), configuration: configuration)

        await #expect(throws: JWKSCache.StartupFailure.jwksHasNoUsableKeys(configuration.jwksURL)) {
            try await cache.start()
        }
    }
}
