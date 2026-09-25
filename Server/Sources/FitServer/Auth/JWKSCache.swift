//  Кеш публичных ключей проекта и три политики §20.5.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import JWTKit

/// Откуда берутся байты JWKS. Протокол существует затем, чтобы тест 20b шёл
/// без сети: сеть — единственное, что отделяет проверку токена от чистой
/// функции.
public protocol JWKSSource: Sendable {
    /// Тело ответа `<issuer>/.well-known/jwks.json`.
    func fetch() async throws -> String
}

/// Набор ключей проекта с тремя политиками §20.5: перезапрос по промаху `kid`
/// под двумя счётчиками, работа по кешу при недоступности, 503 при пустом.
public actor JWKSCache {

    /// Результат поиска ключа. Различает «ключ не тот» и «ключей нет вовсе»:
    /// первое — 401, второе — 503, и путать их §20.5 прямо запрещает.
    public enum Lookup: Sendable {
        /// Коллекция содержит ровно один ключ — найденный по `kid`.
        case found(JWTKeyCollection, JWK)
        /// Набор есть, ключа в нём нет.
        case unknownKey
        /// Набора нет вовсе: холодный старт во время сбоя — либо, сегодня, и
        /// пустой список ключей у проекта на legacy HS256 (см. `Auth.swift`).
        case unavailable
    }

    private struct Entry {
        let jwk: JWK
        let keys: JWTKeyCollection
    }

    /// Потолок на число запомненных промахов. Карта промахов растёт от
    /// неаутентифицированных запросов, а `kid` выбирает присылающий токен:
    /// без потолка это был бы тот же внешний рычаг, что и без троттла, только
    /// на память вместо трафика.
    private static let missedKidsLimit = 1024

    private let source: any JWKSSource
    private let configuration: AuthConfiguration
    private let now: @Sendable () -> Date

    private var entries: [JWKIdentifier: Entry] = [:]
    private var installedSet = false
    private var lastSuccess: Date?
    private var lastAttempt: Date?
    private var missedKids: [JWKIdentifier: Date] = [:]

    public init(
        source: any JWKSSource,
        configuration: AuthConfiguration,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.source = source
        self.configuration = configuration
        self.now = now
    }

    /// Сколько раз ходили за ключами. Нужно тесту 20b: утверждение про троттл
    /// — это утверждение о числе походов, и проверить его больше нечем.
    public private(set) var fetchCount = 0

    public func lookup(kid: JWKIdentifier) async -> Lookup {
        await refreshIfNeeded()

        if let entry = entries[kid] {
            return .found(entry.keys, entry.jwk)
        }

        // Промах. Один перезапрос — под двумя счётчиками сразу: по `kid`
        // решается, стоит ли этот ключ похода, глобальным — можно ли идти
        // сейчас (§20.5).
        let moment = now()
        let checkedRecently = missedKids[kid].map { moment.timeIntervalSince($0) < configuration.kidThrottle } ?? false
        let budgetSpent = lastAttempt.map { moment.timeIntervalSince($0) < configuration.globalThrottle } ?? false

        guard !checkedRecently, !budgetSpent else {
            return outcomeWithoutKey()
        }

        await attemptFetch()
        if let entry = entries[kid] {
            return .found(entry.keys, entry.jwk)
        }
        // Отметка ставится ПОСЛЕ похода и означает ровно одно: этого ключа не
        // было в живом наборе в такой-то момент. Поставить её до похода нельзя
        // — установка свежего набора её же и снимает, и «второй промах подряд
        // — без похода» держалось бы тогда на одном глобальном счётчике,
        // который для этого не предназначен.
        rememberMiss(kid, at: now())
        return outcomeWithoutKey()
    }

    private func outcomeWithoutKey() -> Lookup {
        // Пустой набор — это «ключей нет», а не «ключ не тот»: по букве
        // таблицы §20.3 у `jwks_unavailable` условие «ключей нет и кеша нет».
        // Классификация ответа `200 {"keys": []}` в §20.5 не решена.
        (installedSet && !entries.isEmpty) ? .unknownKey : .unavailable
    }

    private func refreshIfNeeded() async {
        let moment = now()
        if !installedSet {
            // Холодный старт: первый запрос обязан попробовать, но тот же
            // глобальный счётчик не даёт превратить поток запросов в поток
            // походов, пока Supabase лежит.
            if lastAttempt.map({ moment.timeIntervalSince($0) >= configuration.globalThrottle }) ?? true {
                await attemptFetch()
            }
            return
        }
        guard
            let interval = configuration.refreshInterval,
            let lastSuccess,
            moment.timeIntervalSince(lastSuccess) >= interval
        else { return }
        // Плановое обновление тоже считается походом. Иначе при лежащем
        // Supabase `lastSuccess` не двигался бы, срок обновления оставался бы
        // просроченным, и КАЖДЫЙ запрос уходил бы в сеть — ровно тот
        // неограниченный исходящий трафик, от которого троттл и защищает.
        guard lastAttempt.map({ moment.timeIntervalSince($0) >= configuration.globalThrottle }) ?? true else {
            return
        }
        await attemptFetch()
    }

    private func attemptFetch() async {
        lastAttempt = now()
        fetchCount += 1
        guard let json = try? await source.fetch() else { return }
        guard let jwks = try? JSONDecoder().decode(JWKS.self, from: Data(json.utf8)) else { return }
        await install(jwks)
    }

    /// Набор заменяется целиком (§20.5). Объединение со старым не даёт
    /// отозванному ключу покинуть кеш никогда.
    private func install(_ jwks: JWKS) async {
        var fresh: [JWKIdentifier: Entry] = [:]
        for jwk in jwks.keys {
            guard let kid = jwk.keyIdentifier else { continue }
            // Ключ без явного `alg` не берём: `JWK.getKey(for:)` вычисляет
            // `alg ?? self.algorithm`, где первое — из НЕПОДПИСАННОГО
            // заголовка токена. Ключ без `alg` отдал бы выбор алгоритма
            // предъявителю токена.
            guard let algorithm = jwk.algorithm, SupportedAlgorithm(jwk: algorithm) != nil else { continue }
            let collection = JWTKeyCollection()
            guard (try? await collection.add(jwk: jwk)) != nil else { continue }
            fresh[kid] = Entry(jwk: jwk, keys: collection)
        }
        entries = fresh
        installedSet = true
        lastSuccess = now()
        // Промах снимается только с тех ключей, которые в новом наборе
        // появились. Снимать все — значит стирать и тот промах, который этот
        // же поход только что подтвердил.
        missedKids = missedKids.filter { entries[$0.key] == nil }
    }

    private func rememberMiss(_ kid: JWKIdentifier, at moment: Date) {
        missedKids[kid] = moment
        guard missedKids.count > Self.missedKidsLimit else { return }
        let cutoff = moment.addingTimeInterval(-configuration.kidThrottle)
        missedKids = missedKids.filter { $0.value > cutoff }
        while missedKids.count > Self.missedKidsLimit,
              let oldest = missedKids.min(by: { $0.value < $1.value })?.key {
            missedKids.removeValue(forKey: oldest)
        }
    }
}
