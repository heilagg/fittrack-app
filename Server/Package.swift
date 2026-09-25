// swift-tools-version: 6.0
import PackageDescription

// Server — Vapor-обёртка над FitCore (SPEC §20). Первый пакет репозитория с
// внешними зависимостями и первый, собираемый под Linux; архитектура модуля —
// в doc-комментарии Sources/FitServer/FitServer.swift.
//
// Зависимости приезжают ровно тогда, когда появляется код, который их зовёт:
// JWTKit вместе с `Auth/`, postgres-nio вместе с `DB/`. Vapor по-прежнему
// отсутствует, и по той же причине — его не зовёт ещё никто: и `Auth/`, и `DB/`
// написаны без него. Для `Auth/` это было решением (политика §20.5 — свой кеш и
// два счётчика троттла — не ложится в одну глобальную `app.jwt`), для `DB/` это
// просто отсутствие надобности: пул и транзакция к HTTP-слою не относятся.
// Побочная выгода та же, что и раньше: 20b и 20k остаются тестами пакета, без
// HTTP-обвязки.
//
// Версия postgres-nio — от 1.33.0, и нижняя граница не декоративна:
// `PostgresClient.withTransaction` нужен как единственная точка, где берётся
// соединение и открывается транзакция (§20.4).
//
// Почему JWTKit, а не разбор токена руками: правило zero-dependency ядра сюда
// не распространяется, и не из снисхождения. Его причина (§20.2) — привязка
// контракта: синтезированная форма `Codable` держится за имена случаев в Swift,
// и переименование внутри ядра молча сменило бы контракт у двух клиентов.
// JWTKit не касается ни одного типа FitCore и не появляется ни в одном теле
// ответа. С пятой версии он на swift-crypto вместо вендоренного BoringSSL —
// для пакета, который существует ради Linux, это прямая выгода.
//
// Цель сборки — библиотека, а не исполняемый файл: точки входа ещё нет.
// Исполняемый таргет появится вместе с первым роутом (§20.3).
//
// platforms задаёт только нижнюю границу платформ Apple; Linux, ради которого
// пакет и существует, ограничением не описывается. Значение унаследовано от
// FitCore и FitAPI — ниже их подняться нельзя.
let package = Package(
    name: "FitServer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FitServer", targets: ["FitServer"])
    ],
    dependencies: [
        .package(path: "../Packages/FitCore"),
        .package(path: "../Packages/FitAPI"),
        .package(url: "https://github.com/vapor/jwt-kit.git", from: "5.0.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.33.0")
    ],
    targets: [
        .target(
            name: "FitServer",
            dependencies: [
                "FitCore",
                "FitAPI",
                .product(name: "JWTKit", package: "jwt-kit"),
                .product(name: "PostgresNIO", package: "postgres-nio")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FitServerTests",
            dependencies: [
                "FitServer",
                .product(name: "JWTKit", package: "jwt-kit"),
                .product(name: "PostgresNIO", package: "postgres-nio")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
