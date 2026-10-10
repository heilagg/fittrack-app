//  Точка входа процесса (SPEC §20.4, §20.5, §20.11, §20.13).
//
//  Таргет тонкий намеренно: он читает конфигурацию среды, поднимает то, из чего
//  состоит процесс, и монтирует `/v1`. Своей логики у него нет ни строки —
//  поэтому его нечем тестировать, и §20.15 к нему не обращается.
//
//  ── Почему пул и JWKS поднимаются, хотя их не зовёт ни один смонтированный путь
//
//  Оба пути `/v1/content/*` обходятся без токена и без базы (§20.5, §20.11), и
//  соблазн отложить Auth и DB до первого доменного роута есть. Он отвергнут:
//  и то и другое — свойства ПРОЦЕССА, а не отдельного пути. §20.5 требует,
//  чтобы деплой с неработающей аутентификацией не прожил ни минуты (пустой
//  набор ключей останавливает старт), а §20.4 держит `minimumConnections = 2`
//  ровно затем, чтобы пул не простывал, — оба утверждения проверяемы только
//  там, где процесс поднимается.
//
//  Обратная сторона названа честно: без `FITTRACK_ISSUER` и
//  `FITTRACK_DB_PASSWORD` сервер не стартует, даже если ему предстоит отдавать
//  один лишь контент. Это то же правило, что у issuer'а в §20.5, — незаданное
//  значение относится к классу молчаливой ошибки, и отказ при старте дешевле.
//
//  ── Что читается из среды ──────────────────────────────────────────────────
//
//    FITTRACK_ISSUER        обязательна; адрес JWKS выводится из неё (§20.5)
//    FITTRACK_DB_PASSWORD   обязательна; пароль роли `fitserver` (§20.4)
//    FITTRACK_DB_HOST/PORT/NAME/USER   умолчания локальной среды
//    FITTRACK_DB_TLS        `require` (умолчание) либо `disable`
//    FITTRACK_HOST/PORT     что слушать
//
//  TLS обязателен в проде и отсутствует локально — это разница конфигурации, а
//  не кода (§20.4). Поэтому умолчание — `require`: забытая переменная обязана
//  давать более строгое поведение, а не менее.

import FitContent
import FitServer
import Logging
import NIOSSL
import PostgresNIO
import Vapor

func env(_ name: String, default fallback: String? = nil) throws -> String {
    guard let value = Environment.get(name) ?? fallback, !value.isEmpty else {
        throw StartupError.missingEnvironment(name)
    }
    return value
}

enum StartupError: Error, CustomStringConvertible {
    case missingEnvironment(String)
    case unknownTLSMode(String)

    var description: String {
        switch self {
        case .missingEnvironment(let name): return "не задана переменная среды \(name)"
        case .unknownTLSMode(let value): return "FITTRACK_DB_TLS: ожидается require либо disable, получено \(value)"
        }
    }
}

var environment = try Environment.detect()
try LoggingSystem.bootstrap(from: &environment)

let application = try await Application.make(environment)
let logger = application.logger

do {
    // 1. Контент: байты обоих ответов и их `ETag` считаются один раз, здесь
    //    (§20.11). Разметки в пакете пока ноль, и это валидный ответ — пустой
    //    массив со своим `ETag`, а не ошибка.
    let library = try Content.loadBundled()
    let store = try ContentStore(library: library)

    // 2. Ключи. `start()` различает два вида неудачи: недоступность старту не
    //    мешает (процесс поднимется и будет отвечать `jwks_unavailable`), а
    //    пустой набор, приехавший успехом, его останавливает (§20.5).
    let auth = try AuthConfiguration(issuer: try env("FITTRACK_ISSUER"))
    let keys = JWKSCache(source: HTTPJWKSSource(configuration: auth), configuration: auth)
    try await keys.start()
    let verifier = TokenVerifier(configuration: auth, cache: keys)

    // 3. Пул. Токен проверяет он сам, а не вызывающий слой (§20.4), поэтому
    //    `verifier` уходит внутрь и наружу больше не отдаётся.
    let tlsMode = try env("FITTRACK_DB_TLS", default: "require")
    let tls: PostgresClient.Configuration.TLS
    switch tlsMode {
    case "require": tls = .require(.makeClientConfiguration())
    case "disable": tls = .disable
    default: throw StartupError.unknownTLSMode(tlsMode)
    }
    let database = Database(
        configuration: try DatabaseConfiguration(
            host: try env("FITTRACK_DB_HOST", default: "127.0.0.1"),
            port: Int(try env("FITTRACK_DB_PORT", default: "5432")) ?? 5432,
            username: try env("FITTRACK_DB_USER", default: "fitserver"),
            password: try env("FITTRACK_DB_PASSWORD"),
            database: try env("FITTRACK_DB_NAME", default: "postgres"),
            tls: tls
        ),
        verifier: verifier,
        logger: logger
    )

    application.http.server.configuration.hostname = try env("FITTRACK_HOST", default: "127.0.0.1")
    application.http.server.configuration.port = Int(try env("FITTRACK_PORT", default: "8080")) ?? 8080

    Routes.register(on: application, content: store, library: library, database: database)

    // `run()` обязан крутиться всё время жизни пула — до него
    // `withUserTransaction` не получит соединения. Владельца у этой задачи нет
    // нигде, кроме точки входа: пакет её не запускает намеренно.
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await database.run() }
        group.addTask { try await application.execute() }
        // Первой возвращается `execute()`; `run()` не вернётся никогда, поэтому
        // группа отменяется явно, а не дожидается второй задачи.
        try await group.next()
        group.cancelAll()
    }
} catch {
    logger.report(error: error)
    try? await application.asyncShutdown()
    exit(1)
}

try await application.asyncShutdown()
