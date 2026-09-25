//  Тест 20b (§20.15): подделанная подпись, истёкший токен, токен другого
//  проекта → 401, до БД запрос не доходит.
//
//  Сети здесь нет: пара ключей генерируется на месте, JWKS собирается своим же
//  кодом, часы подставляются. До БД дойти физически нечем — `Auth/` не знает ни
//  одной доменной таблицы, и вторая половина 20b («до БД не доходит») станет
//  проверяемой вместе с `DB/` и первым роутом.
//
//  Три утверждения здесь важнее остальных, потому что без них тест был бы
//  зелёным по случайной причине — тому самому, о котором предупреждает §20.5:
//
//    1. чужой issuer предъявляется со СВЕЖЕЙ подписью НАШИМ ключом: иначе его
//       отсекла бы подпись или промах `kid`, а не `iss`;
//    2. `alg` проверяется отдельными случаями (`none`, HS256 на публичном
//       ключе, заголовок против ключа) — поведение библиотеки по умолчанию за
//       это не отвечает;
//    3. неизвестный `kid` обязан стать промахом, а не поводом взять ключ по
//       умолчанию: `JWTKeyCollection.verify` поступает именно так, и токен
//       прошёл бы чужим ключом.

import Testing
import Foundation
import JWTKit
import FitAPI
@testable import FitServer

// MARK: - Обвязка

/// Часы под управлением теста: утверждения про троттл и перекос — это
/// утверждения о времени, и настоящими часами они не проверяются.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { self.current = start }
    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }
    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

private enum StubError: Error { case unreachable }

/// Подменённый источник JWKS: умеет отдавать набор, падать и меняться на ходу
/// (ротация), и считает походы.
private actor StubJWKS: JWKSSource {
    enum Response {
        case json(String)
        case unreachable
    }

    private var response: Response
    private(set) var calls = 0

    init(_ response: Response) { self.response = response }

    func set(_ response: Response) { self.response = response }

    func fetch() async throws -> String {
        calls += 1
        switch response {
        case .json(let json): return json
        case .unreachable: throw StubError.unreachable
        }
    }
}

/// Тело токена, в котором любой claim можно не класть вовсе.
private struct TestClaims: JWTPayload {
    var iss: IssuerClaim?
    var sub: SubjectClaim?
    var aud: AudienceClaim?
    var exp: ExpirationClaim?
    var nbf: NotBeforeClaim?
    var is_anonymous: Bool?
    /// Claim, которого `SupabaseClaims` не знает, — для проверки того, что
    /// дальше уходит исходный JSON, а не пересобранный (§20.4).
    var email: String?

    func verify(using _: some JWTAlgorithm) async throws {}
}

private struct TestKey {
    let kid: String
    let privateKey: ES256PrivateKey

    init(kid: String = UUID().uuidString) {
        self.kid = kid
        self.privateKey = ES256PrivateKey()
    }

    /// JWK публичной половины.
    ///
    /// `parameters` у JWTKit отдаёт координаты СТАНДАРТНЫМ base64, а разбирает
    /// их `init(parameters:)` как base64url — несоответствие внутри самой
    /// библиотеки. Supabase присылает base64url, поэтому переводим.
    var jwk: String {
        let p = privateKey.publicKey.parameters!
        func urlSafe(_ s: String) -> String {
            s.replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return """
        {"kty":"EC","crv":"P-256","alg":"ES256","kid":"\(kid)","x":"\(urlSafe(p.x))","y":"\(urlSafe(p.y))"}
        """
    }
}

private func jwks(_ keys: TestKey...) -> String {
    "{\"keys\":[\(keys.map(\.jwk).joined(separator: ","))]}"
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

@Suite("20b: проверка предъявленного токена (§20.15)")
struct Test20bTokenVerification {

    private let issuer = "https://project.supabase.co/auth/v1"
    private let foreignIssuer = "https://other-project.supabase.co/auth/v1"
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func configuration(
        refreshInterval: TimeInterval? = nil,
        kidThrottle: TimeInterval = 60,
        globalThrottle: TimeInterval = 60
    ) throws -> AuthConfiguration {
        try AuthConfiguration(
            issuer: issuer,
            refreshInterval: refreshInterval,
            kidThrottle: kidThrottle,
            globalThrottle: globalThrottle
        )
    }

    private func claims(
        issuer: String? = nil,
        subject: String? = "8f1b1c8e-0000-4000-8000-000000000001",
        audience: String = "authenticated",
        expiresIn: TimeInterval = 3600,
        notBefore: TimeInterval? = nil,
        isAnonymous: Bool? = false,
        email: String? = nil
    ) -> TestClaims {
        TestClaims(
            iss: IssuerClaim(value: issuer ?? self.issuer),
            sub: subject.map { SubjectClaim(value: $0) },
            aud: AudienceClaim(value: [audience]),
            exp: ExpirationClaim(value: start.addingTimeInterval(expiresIn)),
            nbf: notBefore.map { NotBeforeClaim(value: start.addingTimeInterval($0)) },
            is_anonymous: isAnonymous,
            email: email
        )
    }

    private func sign(_ payload: TestClaims, with key: TestKey, declaringKid kid: String? = nil) async throws -> String {
        let collection = JWTKeyCollection()
        let signingKid = JWKIdentifier(string: kid ?? key.kid)
        await collection.add(ecdsa: key.privateKey, kid: signingKid)
        return try await collection.sign(payload, kid: signingKid)
    }

    /// Собирает верификатор поверх подменённого источника и управляемых часов.
    private func verifier(
        source: StubJWKS,
        clock: TestClock,
        refreshInterval: TimeInterval? = nil,
        kidThrottle: TimeInterval = 60,
        globalThrottle: TimeInterval = 60
    ) throws -> (TokenVerifier, JWKSCache) {
        let configuration = try configuration(
            refreshInterval: refreshInterval,
            kidThrottle: kidThrottle,
            globalThrottle: globalThrottle
        )
        let cache = JWKSCache(source: source, configuration: configuration, now: { clock.now })
        return (TokenVerifier(configuration: configuration, cache: cache, now: { clock.now }), cache)
    }

    private func expectFailure(
        _ expected: AuthFailure,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ body: () async throws -> VerifiedToken
    ) async {
        await #expect(throws: expected, sourceLocation: sourceLocation) {
            _ = try await body()
        }
    }

    // MARK: - Токен другого проекта

    /// Главное утверждение 20b: чужой проект отсекается `iss`, а не подписью и
    /// не промахом `kid`. Поэтому подпись здесь СВЕЖАЯ и сделана ключом, который
    /// лежит в нашем же JWKS: всё остальное сходится, расходится только issuer.
    @Test func test20b_foreignIssuerIsRejectedWhileSignatureAndKidAreValid() async throws {
        let key = TestKey()
        let clock = TestClock(start)
        let (verifier, _) = try verifier(source: StubJWKS(.json(jwks(key))), clock: clock)

        let token = try await sign(claims(issuer: foreignIssuer), with: key)

        // Убеждаемся, что тот же токен с нашим issuer проходит: иначе
        // утверждение выше ничего не стоит.
        let ours = try await sign(claims(), with: key)
        _ = try await verifier.verify(bearer: ours)

        await expectFailure(.unauthorized(.wrongIssuer)) {
            try await verifier.verify(bearer: token)
        }
    }

    /// `aud` чужой токен не отличает — у Supabase он `authenticated` во всех
    /// проектах. Проверяется как самостоятельное правило, а не как замена `iss`.
    @Test func test20b_wrongAudienceIsRejected() async throws {
        let key = TestKey()
        let clock = TestClock(start)
        let (verifier, _) = try verifier(source: StubJWKS(.json(jwks(key))), clock: clock)

        let token = try await sign(claims(audience: "anon"), with: key)
        await expectFailure(.unauthorized(.wrongAudience)) {
            try await verifier.verify(bearer: token)
        }
    }

    // MARK: - Подпись

    @Test func test20b_forgedSignatureIsRejected() async throws {
        let published = TestKey()
        // Тот же `kid`, другая пара ключей: подпись подделана.
        let forged = TestKey(kid: published.kid)
        let clock = TestClock(start)
        let (verifier, _) = try verifier(source: StubJWKS(.json(jwks(published))), clock: clock)

        let token = try await sign(claims(), with: forged)
        await expectFailure(.unauthorized(.badSignature)) {
            try await verifier.verify(bearer: token)
        }
    }

    // MARK: - Алгоритм

    /// `alg: none` — отказ, и отказ по алгоритму, а не по подписи: до ключа
    /// такой токен не доходит вовсе.
    @Test func test20b_algNoneIsRejected() async throws {
        let key = TestKey()
        let clock = TestClock(start)
        let (verifier, cache) = try verifier(source: StubJWKS(.json(jwks(key))), clock: clock)

        let header = base64URL(Data(#"{"alg":"none","kid":"\#(key.kid)"}"#.utf8))
        let payload = base64URL(try JSONEncoder().encode(["sub": "whoever"]))
        let fetchesBefore = await cache.fetchCount

        await expectFailure(.unauthorized(.unsupportedAlgorithm)) {
            try await verifier.verify(bearer: "\(header).\(payload).")
        }
        let fetchesAfter = await cache.fetchCount
        #expect(fetchesBefore == fetchesAfter, "непригодный alg не должен дёргать JWKS")
    }

    /// Классика подмены алгоритма: HS256, подписанный байтами публичного ключа.
    /// Отклоняется по списку алгоритмов, то есть до того, как этот «секрет»
    /// вообще кого-то заинтересует.
    @Test func test20b_hmacSignedWithThePublicKeyIsRejected() async throws {
        let key = TestKey()
        let clock = TestClock(start)
        let (verifier, _) = try verifier(source: StubJWKS(.json(jwks(key))), clock: clock)

        let hmac = JWTKeyCollection()
        await hmac.add(
            hmac: HMACKey(from: key.privateKey.publicKey.pemRepresentation),
            digestAlgorithm: .sha256,
            kid: JWKIdentifier(string: key.kid)
        )
        let token = try await hmac.sign(claims(), kid: JWKIdentifier(string: key.kid))

        await expectFailure(.unauthorized(.unsupportedAlgorithm)) {
            try await verifier.verify(bearer: token)
        }
    }

    /// Заголовок объявляет RS256, ключ по `kid` — ES256. Отказ наступает на
    /// сверке с ключом, а не на подписи: алгоритм берётся из ключа (§20.5).
    @Test func test20b_headerAlgorithmMismatchingTheKeyIsRejected() async throws {
        let key = TestKey()
        let clock = TestClock(start)
        let (verifier, _) = try verifier(source: StubJWKS(.json(jwks(key))), clock: clock)

        let signed = try await sign(claims(), with: key)
        let parts = signed.split(separator: ".", omittingEmptySubsequences: false)
        let header = base64URL(Data(#"{"alg":"RS256","kid":"\#(key.kid)"}"#.utf8))
        let token = "\(header).\(parts[1]).\(parts[2])"

        await expectFailure(.unauthorized(.algorithmMismatch)) {
            try await verifier.verify(bearer: token)
        }
    }

    // MARK: - Выбор ключа

    /// Ключ по умолчанию не подставляется. `JWTKeyCollection.verify` при
    /// неизвестном `kid` берёт первый добавленный ключ — токен прошёл бы чужим
    /// ключом, а механика §20.5 не наступила бы никогда.
    @Test func test20b_unknownKidNeverFallsBackToTheDefaultKey() async throws {
        let key = TestKey()
        let clock = TestClock(start)
        let (verifier, _) = try verifier(source: StubJWKS(.json(jwks(key))), clock: clock)

        // Подпись настоящая и ключ наш — расходится только объявленный `kid`.
        let token = try await sign(claims(), with: key, declaringKid: UUID().uuidString)
        await expectFailure(.unauthorized(.unknownKey)) {
            try await verifier.verify(bearer: token)
        }
    }

    /// Токен без `kid` — промах без похода за ключами: искать нечего, а
    /// троттл §20.5 считается именно по `kid`.
    @Test func test20b_tokenWithoutKidIsRejectedWithoutFetching() async throws {
        let key = TestKey()
        let clock = TestClock(start)
        let (verifier, cache) = try verifier(source: StubJWKS(.json(jwks(key))), clock: clock)

        _ = try await verifier.verify(bearer: try await sign(claims(), with: key))
        let fetchesBefore = await cache.fetchCount

        let header = base64URL(Data(#"{"alg":"ES256"}"#.utf8))
        let payload = base64URL(try JSONEncoder().encode(["sub": "whoever"]))
        await expectFailure(.unauthorized(.unknownKey)) {
            try await verifier.verify(bearer: "\(header).\(payload).signature")
        }
        let fetchesAfter = await cache.fetchCount
        #expect(fetchesBefore == fetchesAfter)
    }

    // MARK: - Время

    @Test func test20b_expiredTokenIsRejected() async throws {
        let key = TestKey()
        let clock = TestClock(start)
        let (verifier, _) = try verifier(source: StubJWKS(.json(jwks(key))), clock: clock)

        let token = try await sign(claims(expiresIn: 60), with: key)
        clock.advance(200)

        await expectFailure(.unauthorized(.expired)) {
            try await verifier.verify(bearer: token)
        }
    }

    /// Перекос 60 с покрывает сетевой разброс и ничего сверх: 30 секунд после
    /// `exp` проходят, 90 — нет.
    @Test func test20b_expiryIsForgivenWithinSixtySecondsAndNotBeyond() async throws {
        let key = TestKey()
        let clock = TestClock(start)
        let (verifier, _) = try verifier(source: StubJWKS(.json(jwks(key))), clock: clock)

        let token = try await sign(claims(expiresIn: 60), with: key)

        clock.advance(90)   // 30 с после `exp`
        _ = try await verifier.verify(bearer: token)

        clock.advance(60)   // 90 с после `exp`
        await expectFailure(.unauthorized(.expired)) {
            try await verifier.verify(bearer: token)
        }
    }

    /// `nbf` прощается в другую сторону — потому и моментов два, а не один
    /// сдвинутый.
    @Test func test20b_notBeforeIsForgivenWithinSixtySecondsAndNotBeyond() async throws {
        let key = TestKey()
        let clock = TestClock(start)
        let (verifier, _) = try verifier(source: StubJWKS(.json(jwks(key))), clock: clock)

        _ = try await verifier.verify(bearer: try await sign(claims(notBefore: 30), with: key))

        await expectFailure(.unauthorized(.notYetValid)) {
            try await verifier.verify(bearer: try await self.sign(self.claims(notBefore: 90), with: key))
        }
    }

    /// `nbf` необязателен у Supabase — токена без него это правило не касается.
    @Test func test20b_absentNotBeforeIsAccepted() async throws {
        let key = TestKey()
        let clock = TestClock(start)
        let (verifier, _) = try verifier(source: StubJWKS(.json(jwks(key))), clock: clock)

        _ = try await verifier.verify(bearer: try await sign(claims(notBefore: nil), with: key))
    }

    // MARK: - Subject

    @Test func test20b_missingSubjectIsRejected() async throws {
        let key = TestKey()
        let clock = TestClock(start)
        let (verifier, _) = try verifier(source: StubJWKS(.json(jwks(key))), clock: clock)

        // Claim отсутствует вовсе — токен не декодируется.
        await expectFailure(.unauthorized(.malformedToken)) {
            try await verifier.verify(bearer: try await self.sign(self.claims(subject: nil), with: key))
        }
        // Claim есть, но пуст — `auth.uid()` из него не получится.
        await expectFailure(.unauthorized(.missingSubject)) {
            try await verifier.verify(bearer: try await self.sign(self.claims(subject: ""), with: key))
        }
    }

    // MARK: - Троттл

    /// Промах по `kid` даёт ровно один перезапрос; второй промах по тому же
    /// ключу — 401 без похода.
    @Test func test20b_kidMissTriggersExactlyOneRefetch() async throws {
        let key = TestKey()
        let clock = TestClock(start)
        let (verifier, cache) = try verifier(source: StubJWKS(.json(jwks(key))), clock: clock)

        _ = try await verifier.verify(bearer: try await sign(claims(), with: key))
        let warm = await cache.fetchCount
        // Поход на холодном старте тоже тратит общий бюджет — иначе «не чаще
        // раза в минуту» ничего не ограничивало бы. Выходим из его окна.
        clock.advance(61)

        let stranger = TestKey()
        let token = try await sign(claims(), with: stranger)

        await expectFailure(.unauthorized(.unknownKey)) { try await verifier.verify(bearer: token) }
        let afterFirst = await cache.fetchCount
        #expect(afterFirst == warm + 1, "первый промах — один перезапрос")

        await expectFailure(.unauthorized(.unknownKey)) { try await verifier.verify(bearer: token) }
        let afterSecond = await cache.fetchCount
        #expect(afterSecond == afterFirst, "второй промах подряд — без похода")
    }

    /// Глобальный счётчик: разные неизвестные `kid` не дают по походу каждый.
    /// Без него учёт по `kid` оставлял бы внешний рычаг на исходящий трафик.
    @Test func test20b_globalThrottleCapsFetchesAcrossDistinctKids() async throws {
        let key = TestKey()
        let clock = TestClock(start)
        let (verifier, cache) = try verifier(source: StubJWKS(.json(jwks(key))), clock: clock)

        _ = try await verifier.verify(bearer: try await sign(claims(), with: key))
        let warm = await cache.fetchCount
        clock.advance(61)

        // Двадцать разных неизвестных ключей в пределах минуты — один поход.
        for _ in 0..<20 {
            let stranger = TestKey()
            await expectFailure(.unauthorized(.unknownKey)) {
                try await verifier.verify(bearer: try await self.sign(self.claims(), with: stranger))
            }
        }
        let afterBurst = await cache.fetchCount
        #expect(afterBurst == warm + 1, "минута — один поход, сколько бы kid ни пришло")

        clock.advance(61)
        let another = TestKey()
        await expectFailure(.unauthorized(.unknownKey)) {
            try await verifier.verify(bearer: try await self.sign(self.claims(), with: another))
        }
        let afterWindow = await cache.fetchCount
        #expect(afterWindow == afterBurst + 1, "после окна поход снова разрешён")
    }

    /// Счётчик по `kid` проверяется отдельно от глобального: окна разведены
    /// (5 минут против минуты), поэтому отказ от второго похода объясним только
    /// им. С равными окнами §20.5 оба истекают разом, и такое утверждение было
    /// бы зелёным по обеим причинам сразу.
    @Test func test20b_theKidCounterAloneBlocksARepeatedMiss() async throws {
        let key = TestKey()
        let clock = TestClock(start)
        let (verifier, cache) = try verifier(
            source: StubJWKS(.json(jwks(key))),
            clock: clock,
            kidThrottle: 300,
            globalThrottle: 60
        )

        _ = try await verifier.verify(bearer: try await sign(claims(), with: key))
        clock.advance(61)

        let stranger = TestKey()
        let token = try await sign(claims(), with: stranger)

        await expectFailure(.unauthorized(.unknownKey)) { try await verifier.verify(bearer: token) }
        let afterFirst = await cache.fetchCount

        // Общий бюджет свободен, а ключ тот же — похода быть не должно.
        clock.advance(61)
        await expectFailure(.unauthorized(.unknownKey)) { try await verifier.verify(bearer: token) }
        let afterSecond = await cache.fetchCount
        #expect(afterSecond == afterFirst, "тот же kid внутри своего окна — без похода")

        // Другой неизвестный ключ в тот же момент поход получает: окно
        // считается по ключу, а не по процессу.
        let another = TestKey()
        await expectFailure(.unauthorized(.unknownKey)) {
            try await verifier.verify(bearer: try await self.sign(self.claims(), with: another))
        }
        let afterOther = await cache.fetchCount
        #expect(afterOther == afterSecond + 1)
    }

    /// Ради чего перезапрос и существует: ротация подхватывается без деплоя.
    @Test func test20b_rotationIsPickedUpOnKidMiss() async throws {
        let old = TestKey()
        let new = TestKey()
        let source = StubJWKS(.json(jwks(old)))
        let clock = TestClock(start)
        let (verifier, _) = try verifier(source: source, clock: clock)

        _ = try await verifier.verify(bearer: try await sign(claims(), with: old))

        await source.set(.json(jwks(new)))
        clock.advance(61)

        let token = try await sign(claims(), with: new)
        let verified = try await verifier.verify(bearer: token)
        #expect(verified.subject == "8f1b1c8e-0000-4000-8000-000000000001")

        // Набор заменён целиком: прежний ключ больше не принимается.
        await expectFailure(.unauthorized(.unknownKey)) {
            try await verifier.verify(bearer: try await self.sign(self.claims(), with: old))
        }
    }

    // MARK: - Плановое обновление

    /// TTL как значение §20.5 не выбран, но сам механизм обязан работать и
    /// быть проверяемым: с заданным сроком набор обновляется без единого
    /// промаха по `kid`, то есть ротация подхватывается до того, как о ней
    /// узнает первый пользователь.
    @Test func test20b_scheduledRefreshPicksUpRotationWithoutAnyKidMiss() async throws {
        let old = TestKey()
        let new = TestKey()
        let source = StubJWKS(.json(jwks(old)))
        let clock = TestClock(start)
        let (verifier, cache) = try verifier(source: source, clock: clock, refreshInterval: 600)

        _ = try await verifier.verify(bearer: try await sign(claims(), with: old))
        let warm = await cache.fetchCount

        await source.set(.json(jwks(new)))
        clock.advance(601)

        // Ключ новый, промаха не было бы и без обновления — проверяем, что
        // набор подтянулся сам.
        let verified = try await verifier.verify(bearer: try await sign(claims(), with: new))
        #expect(!(verified.isAnonymous))
        let after = await cache.fetchCount
        #expect(after == warm + 1)
    }

    /// Плановое обновление тоже под глобальным счётчиком. Иначе при лежащем
    /// Supabase срок обновления оставался бы просроченным, и каждый запрос
    /// уходил бы в сеть.
    @Test func test20b_scheduledRefreshDuringOutageStaysUnderTheGlobalThrottle() async throws {
        let key = TestKey()
        let source = StubJWKS(.json(jwks(key)))
        let clock = TestClock(start)
        let (verifier, cache) = try verifier(source: source, clock: clock, refreshInterval: 60)

        _ = try await verifier.verify(bearer: try await sign(claims(), with: key))
        let warm = await cache.fetchCount

        await source.set(.unreachable)
        clock.advance(61)

        for _ in 0..<5 {
            // Кеш живой — токен по-прежнему проходит (§20.5).
            _ = try await verifier.verify(bearer: try await sign(claims(), with: key))
        }
        let after = await cache.fetchCount
        #expect(after == warm + 1, "просроченный срок не делает поход из каждого запроса")
    }

    // MARK: - Доступность JWKS

    /// Ключ не протух от того, что Supabase недоступен.
    @Test func test20b_warmCacheSurvivesJWKSOutage() async throws {
        let key = TestKey()
        let source = StubJWKS(.json(jwks(key)))
        let clock = TestClock(start)
        let (verifier, _) = try verifier(source: source, clock: clock)

        _ = try await verifier.verify(bearer: try await sign(claims(), with: key))

        await source.set(.unreachable)
        clock.advance(600)

        let verified = try await verifier.verify(bearer: try await sign(claims(), with: key))
        #expect(!(verified.isAnonymous))
    }

    /// Кеша нет вовсе — 503, а НЕ 401: это не «токен плохой», и клиенту
    /// следует повторить, а не разлогинивать пользователя.
    @Test func test20b_coldCacheDuringOutageIsFiveOhThreeNotFourOhOne() async throws {
        let key = TestKey()
        let clock = TestClock(start)
        let (verifier, _) = try verifier(source: StubJWKS(.unreachable), clock: clock)

        let failure = await #expect(throws: AuthFailure.self) {
            _ = try await verifier.verify(bearer: try await self.sign(self.claims(), with: key))
        }
        #expect(failure == .jwksUnavailable)
        #expect(failure?.code == .jwksUnavailable)
        #expect(failure?.code.httpStatus == 503)
    }

    /// Пустой список ключей — то, что отдаёт проект на legacy HS256. Сегодня
    /// трактуется как «ключей нет» (§20.3), и отдельная классификация в §20.5
    /// не решена: тест фиксирует текущее поведение, а не выбирает его.
    @Test func test20b_emptyKeySetIsTreatedAsNoKeysAtAll() async throws {
        let key = TestKey()
        let clock = TestClock(start)
        let (verifier, _) = try verifier(source: StubJWKS(.json(#"{"keys":[]}"#)), clock: clock)

        await expectFailure(.jwksUnavailable) {
            try await verifier.verify(bearer: try await self.sign(self.claims(), with: key))
        }
    }

    // MARK: - Что уходит дальше

    /// В `request.jwt.claims` уходит исходный JSON: claim, которого
    /// `SupabaseClaims` не знает, обязан дожить до транзакции (§20.4, §20.5).
    @Test func test20b_verifiedTokenCarriesTheClaimsVerbatim() async throws {
        let key = TestKey()
        let clock = TestClock(start)
        let (verifier, _) = try verifier(source: StubJWKS(.json(jwks(key))), clock: clock)

        let token = try await sign(claims(email: "she@example.com"), with: key)
        let verified = try await verifier.verify(bearer: token)

        #expect(verified.claimsJSON.contains("\"email\""))
        #expect(verified.claimsJSON.contains("she@example.com"))
        let parsed = try JSONSerialization.jsonObject(with: Data(verified.claimsJSON.utf8)) as? [String: Any]
        #expect(parsed?["sub"] as? String == verified.subject)
    }

    // MARK: - Гейт линковки

    /// Анонимный токен валиден и 401 не даёт — §4.1 требует анонимного
    /// онбординга. Закрыт для него только путь, требующий линковки (§20.5).
    @Test func test20b_anonymousTokenIsValidButFailsTheLinkedAccountGate() async throws {
        let key = TestKey()
        let clock = TestClock(start)
        let (verifier, _) = try verifier(source: StubJWKS(.json(jwks(key))), clock: clock)

        let anonymous = try await verifier.verify(bearer: try await sign(claims(isAnonymous: true), with: key))
        #expect(anonymous.isAnonymous)
        let refusal = #expect(throws: AuthFailure.self) {
            try anonymous.requireLinkedAccount()
        }
        #expect(refusal == .unlinkedAccount)
        #expect(refusal?.code == .unlinkedAccount)
        #expect(refusal?.code.httpStatus == 403)

        let linked = try await verifier.verify(bearer: try await sign(claims(isAnonymous: false), with: key))
        #expect(throws: Never.self) { try linked.requireLinkedAccount() }
    }

    /// Отсутствующий claim закрывает гейт, а не открывает: ошибка видимая, а
    /// не молчаливая.
    @Test func test20b_absentIsAnonymousClaimClosesTheGate() async throws {
        let key = TestKey()
        let clock = TestClock(start)
        let (verifier, _) = try verifier(source: StubJWKS(.json(jwks(key))), clock: clock)

        let verified = try await verifier.verify(bearer: try await sign(claims(isAnonymous: nil), with: key))
        #expect(verified.isAnonymous)
    }

    // MARK: - Конфигурация

    /// Issuer без значения по умолчанию, URL JWKS выводится из него (§20.5).
    @Test func test20b_issuerIsRequiredAndDerivesTheJWKSURL() throws {
        let configuration = try configuration()
        #expect(
            configuration.jwksURL.absoluteString
                == "https://project.supabase.co/auth/v1/.well-known/jwks.json"
        )
        #expect(throws: AuthConfiguration.Failure.self) {
            try AuthConfiguration(issuer: "", refreshInterval: nil)
        }
        #expect(throws: AuthConfiguration.Failure.self) {
            try AuthConfiguration(issuer: "   ", refreshInterval: nil)
        }

        // Локальная среда отличается значением, а не формой.
        let local = try AuthConfiguration(issuer: "http://127.0.0.1:54321/auth/v1/", refreshInterval: nil)
        #expect(
            local.jwksURL.absoluteString
                == "http://127.0.0.1:54321/auth/v1/.well-known/jwks.json"
        )
    }

    /// Список алгоритмов закрыт (§20.5): его расширение — правка SPEC.
    @Test func test20b_supportedAlgorithmsAreExactlyTwo() {
        #expect(Set(SupportedAlgorithm.allCases.map(\.rawValue)) == ["ES256", "RS256"])
    }
}
