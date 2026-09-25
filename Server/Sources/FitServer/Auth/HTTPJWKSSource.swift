//  Настоящий источник JWKS — поход по HTTP (§20.5).

// Здесь, в отличие от остального `Auth/`, нужна полная Foundation:
// `URLSession` в `FoundationEssentials` не входит, а на Linux живёт в отдельном
// модуле.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Загрузка `<issuer>/.well-known/jwks.json`.
///
/// Единственное место `Auth/`, которое ходит в сеть, — и потому единственное,
/// которое подменяется в тестах. Адрес берётся из `AuthConfiguration`, а не
/// настраивается отдельно: раздельная настройка допускает проверку подписей
/// ключами одного проекта против `iss` другого (§20.5).
public struct HTTPJWKSSource: JWKSSource {

    /// Всё, что здесь бросается, кеш трактует как недоступность: набор остаётся
    /// прежним, а при пустом кеше запрос получает `jwks_unavailable` и 503.
    /// Пустой ответ ошибкой НЕ является — он приезжает успехом, и решение по
    /// нему принимает `JWKSCache` (§20.5).
    public enum Failure: Error, Equatable, Sendable {
        case notHTTP
        case badStatus(Int)
        case notUTF8
    }

    private let url: URL
    private let timeout: TimeInterval

    public init(url: URL, timeout: TimeInterval = 5) {
        self.url = url
        self.timeout = timeout
    }

    public init(configuration: AuthConfiguration, timeout: TimeInterval = 5) {
        self.init(url: configuration.jwksURL, timeout: timeout)
    }

    public func fetch() async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
        guard (200..<300).contains(http.statusCode) else { throw Failure.badStatus(http.statusCode) }
        guard let text = String(data: data, encoding: .utf8) else { throw Failure.notUTF8 }
        return text
    }
}
