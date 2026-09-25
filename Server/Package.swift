// swift-tools-version: 6.0
import PackageDescription

// Server — Vapor-обёртка над FitCore (SPEC §20). Первый пакет репозитория с
// внешними зависимостями и первый, собираемый под Linux; архитектура модуля —
// в doc-комментарии Sources/FitServer/FitServer.swift.
//
// Первая внешняя зависимость — JWTKit, и приехала она ровно тогда, когда
// обещано: вместе с первым кодом, который её зовёт (Auth/). Vapor и
// postgres-nio по-прежнему отсутствуют, и по той же причине — их не зовёт ещё
// никто. Auth/ намеренно написан без Vapor: политика §20.5 (кеш, два счётчика
// троттла, 401 против 503) своя, а `app.jwt` предлагает одну глобальную
// коллекцию ключей без места под неё. Заодно тест 20b получается юнитовым, без
// HTTP-обвязки.
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
        .package(url: "https://github.com/vapor/jwt-kit.git", from: "5.0.0")
    ],
    targets: [
        .target(
            name: "FitServer",
            dependencies: [
                "FitCore",
                "FitAPI",
                .product(name: "JWTKit", package: "jwt-kit")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FitServerTests",
            dependencies: [
                "FitServer",
                .product(name: "JWTKit", package: "jwt-kit")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
