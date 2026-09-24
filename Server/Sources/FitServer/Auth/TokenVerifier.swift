//  Проверка предъявленного токена: §20.5 целиком, по шагам.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import FitAPI
import JWTKit

/// Закрытый список допустимых алгоритмов (§20.5).
///
/// Оба нужны: ES256 Supabase создаёт по умолчанию, RS256 заводится в дашборде
/// одним действием, и список из одного превратил бы это действие в событие,
/// требующее деплоя. Новый алгоритм добавляется правкой §20.5, а не
/// обновлением зависимости — потому и `enum`, а не множество строк из
/// конфигурации.
public enum SupportedAlgorithm: String, CaseIterable, Sendable, Equatable {
    case es256 = "ES256"
    case rs256 = "RS256"

    init?(jwk algorithm: JWK.Algorithm) {
        self.init(rawValue: algorithm.rawValue)
    }
}

/// Проверенный токен: всё, что нужно остальному серверу, и ничего сверх.
public struct VerifiedToken: Sendable, Equatable {

    /// `sub`, он же `auth.uid()` (§20.4).
    public let subject: String

    /// Аккаунт не привязан. Валидности токена это не отменяет: §4.1 требует,
    /// чтобы онбординг и PAR-Q проходились анонимно (§20.5).
    public let isAnonymous: Bool

    /// Полезная нагрузка ДОСЛОВНО, как она пришла, — для
    /// `set local request.jwt.claims` (§20.4, §20.5). Пересобирать её из
    /// `SupabaseClaims` нельзя: тип знает шесть полей, а политика однажды
    /// прочитает седьмое и получит `null` молча.
    public let claimsJSON: String

    /// Гейт линковки (§20.5). Сегодня его зовёт один путь — `POST /v1/workouts`.
    public func requireLinkedAccount() throws {
        if isAnonymous { throw AuthFailure.unlinkedAccount }
    }
}

/// Отказ проверки. Ровно три исхода наружу, и они разные по смыслу: 401 —
/// «токен плохой», 503 — «наша беда, повторите», 403 — «аккаунт не привязан».
public enum AuthFailure: Error, Equatable, Sendable {

    /// Почему именно не пустили. Наружу не едет: пользовательнице показывается
    /// `ReasonStrings.message(for:)`, а различать эти случаи — дело логов и
    /// теста 20b.
    public enum Reason: String, Sendable, Equatable, CaseIterable {
        case malformedToken
        case unsupportedAlgorithm
        case algorithmMismatch
        case unknownKey
        case badSignature
        case expired
        case notYetValid
        case wrongIssuer
        case wrongAudience
        case missingSubject
    }

    case unauthorized(Reason)
    case jwksUnavailable
    case unlinkedAccount

    /// Пара (код, статус) живёт в `FitAPI` (§20.3), поэтому здесь только
    /// отображение в код — своего статуса этот тип не знает.
    public var code: APIErrorCode {
        switch self {
        case .unauthorized: return .unauthorized
        case .jwksUnavailable: return .jwksUnavailable
        case .unlinkedAccount: return .unlinkedAccount
        }
    }
}

/// Проверка `Authorization: Bearer` по §20.5.
public struct TokenVerifier: Sendable {

    private let configuration: AuthConfiguration
    private let cache: JWKSCache
    private let now: @Sendable () -> Date

    public init(
        configuration: AuthConfiguration,
        cache: JWKSCache,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.cache = cache
        self.now = now
    }

    public func verify(bearer token: String) async throws -> VerifiedToken {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            throw AuthFailure.unauthorized(.malformedToken)
        }
        guard
            let headerData = Self.base64URLDecode(String(parts[0])),
            let header = try? JSONDecoder().decode(TokenHeader.self, from: headerData)
        else {
            throw AuthFailure.unauthorized(.malformedToken)
        }

        // Алгоритм проверяется ДО похода за ключом. Порядок несущий: иначе
        // `alg: none` и HS256 получали бы право дёргать JWKS наравне с
        // настоящими токенами.
        guard let alg = header.alg, let algorithm = SupportedAlgorithm(rawValue: alg) else {
            throw AuthFailure.unauthorized(.unsupportedAlgorithm)
        }

        // Токен без `kid` — промах, но БЕЗ похода за ключами: искать нечего, а
        // §20.5 троттлит перезапрос именно по `kid`. Подставлять ключ по
        // умолчанию, как это делает `JWTKeyCollection`, здесь нельзя — см.
        // Auth.swift.
        guard let kid = header.kid.map({ JWKIdentifier(string: $0) }) else {
            throw AuthFailure.unauthorized(.unknownKey)
        }

        let keys: JWTKeyCollection
        switch await cache.lookup(kid: kid) {
        case .found(let collection, let jwk):
            // Алгоритм берётся из ключа, а не из заголовка (§20.5). Заголовок
            // не подписан, и расхождение — попытка подмены, а не опечатка.
            guard let keyAlgorithm = jwk.algorithm.flatMap(SupportedAlgorithm.init(jwk:)),
                  keyAlgorithm == algorithm
            else {
                throw AuthFailure.unauthorized(.algorithmMismatch)
            }
            keys = collection
        case .unknownKey:
            throw AuthFailure.unauthorized(.unknownKey)
        case .unavailable:
            throw AuthFailure.jwksUnavailable
        }

        let claims: SupabaseClaims
        do {
            claims = try await keys.verify(token, as: SupabaseClaims.self)
        } catch let error as JWTError where error.errorType == .signatureVerificationFailed {
            throw AuthFailure.unauthorized(.badSignature)
        } catch {
            // Сюда приходит и отсутствие обязательного claim: `exp`, `sub`,
            // `iss` и `aud` объявлены не-опциональными, и токен без любого из
            // них не декодируется.
            throw AuthFailure.unauthorized(.malformedToken)
        }

        let moment = now()
        // Перекос 60 с — двумя РАЗНЫМИ моментами, а не одним сдвинутым: `exp`
        // прощается в прошлое, `nbf` в будущее, и одно значение обоим не
        // служит (§20.5).
        guard (try? claims.expiration.verifyNotExpired(
            currentDate: moment.addingTimeInterval(-configuration.clockSkew))) != nil
        else {
            throw AuthFailure.unauthorized(.expired)
        }
        if let notBefore = claims.notBefore {
            guard (try? notBefore.verifyNotBefore(
                currentDate: moment.addingTimeInterval(configuration.clockSkew))) != nil
            else {
                throw AuthFailure.unauthorized(.notYetValid)
            }
        }
        guard claims.issuer.value == configuration.issuer else {
            throw AuthFailure.unauthorized(.wrongIssuer)
        }
        guard (try? claims.audience.verifyIntendedAudience(includes: configuration.audience)) != nil else {
            throw AuthFailure.unauthorized(.wrongAudience)
        }
        guard !claims.subject.value.isEmpty else {
            throw AuthFailure.unauthorized(.missingSubject)
        }

        guard
            let payloadData = Self.base64URLDecode(String(parts[1])),
            let claimsJSON = String(data: payloadData, encoding: .utf8)
        else {
            throw AuthFailure.unauthorized(.malformedToken)
        }

        return VerifiedToken(
            subject: claims.subject.value,
            // Отсутствие claim трактуется как анонимность намеренно. У
            // Supabase он есть всегда; если однажды пропадёт, гейт закроется
            // видимой ошибкой `unlinked_account`, а не откроется молча.
            isAnonymous: claims.isAnonymous ?? true,
            claimsJSON: claimsJSON
        )
    }

    private struct TokenHeader: Decodable {
        let alg: String?
        let kid: String?
    }

    /// base64url → base64 и обратно в байты.
    ///
    /// Посимвольно, а не `replacingOccurrences`: та живёт в полной Foundation,
    /// которой на Linux в `FoundationEssentials` нет.
    static func base64URLDecode(_ string: String) -> Data? {
        var s = String(string.map { character in
            switch character {
            case "-": return Character("+")
            case "_": return Character("/")
            default: return character
            }
        })
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        return Data(base64Encoded: s)
    }
}
