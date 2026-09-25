//  Полезная нагрузка токена Supabase — только то, что §20.5 проверяет.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import JWTKit

/// Пять проверяемых claims плюс `is_anonymous`, который проверкой подлинности
/// не является (§20.5).
///
/// Всё остальное, что Supabase кладёт в токен — `role`, `aal`, `amr`,
/// `session_id`, `email`, `phone`, `jti`, `app_metadata`, `user_metadata`, — не
/// объявлено здесь намеренно и НЕ теряется: дальше в `request.jwt.claims`
/// уходит исходный JSON, а не то, что декодировалось в этот тип (§20.4).
///
/// `role` в списке отсутствует именно потому, что игнорируется безусловно:
/// роль ставит `set local role authenticated`, что бы ни лежало в claim.
/// Объявленное поле означало бы, что кто-то однажды на него посмотрит.
public struct SupabaseClaims: JWTPayload, Equatable, Sendable {

    /// Issuer проекта. На нём стоит тест 20b: `aud` у Supabase равен
    /// `authenticated` во всех проектах сразу и чужой токен не отличает.
    public let issuer: IssuerClaim

    /// Он и есть `auth.uid()` (§20.4).
    public let subject: SubjectClaim

    /// Обязан быть `authenticated`. В JWT `aud` бывает строкой и массивом —
    /// `AudienceClaim` принимает оба.
    public let audience: AudienceClaim

    /// Обязателен; истёкший токен — 401.
    public let expiration: ExpirationClaim

    /// У Supabase необязателен и зависит от контекста аутентификации, поэтому
    /// опционален и здесь: правило §20.5 — «если есть, не в будущем».
    public let notBefore: NotBeforeClaim?

    /// Присутствует у Supabase всегда. Опционален на случай, если однажды
    /// перестанет: см. `TokenVerifier` о том, почему отсутствие трактуется как
    /// анонимность, а не наоборот.
    public let isAnonymous: Bool?

    enum CodingKeys: String, CodingKey {
        case issuer = "iss"
        case subject = "sub"
        case audience = "aud"
        case expiration = "exp"
        case notBefore = "nbf"
        case isAnonymous = "is_anonymous"
    }

    /// Намеренно пусто.
    ///
    /// JWTKit зовёт этот метод сразу после проверки подписи, и соблазн держать
    /// правила §20.5 здесь велик. Нельзя: перекос часов, issuer и audience —
    /// значения конфигурации, а этот метод их не видит и видеть не может. Плюс
    /// `verifyNotExpired` без аргумента взял бы текущий момент без допуска, то
    /// есть правило «60 секунд» отменилось бы молча. Все проверки — явные, в
    /// `TokenVerifier`.
    public func verify(using _: some JWTAlgorithm) async throws {}
}
