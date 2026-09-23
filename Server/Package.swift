// swift-tools-version: 6.0
import PackageDescription

// Server — Vapor-обёртка над FitCore (SPEC §20). Первый пакет репозитория с
// внешними зависимостями и первый, собираемый под Linux; архитектура модуля —
// в doc-комментарии Sources/FitServer/FitServer.swift.
//
// Внешних зависимостей здесь пока нет, и это не упущение: vapor, postgres-nio и
// клиент JWKS приезжают вместе с первым кодом, который их зовёт (Auth/, DB/).
// Закреплённая версия без вызывающего кода ничего не проверяет, а резолв всё
// равно случится на том же коммите, что и первый импорт.
//
// Цель сборки — библиотека, а не исполняемый файл: точки входа ещё нет.
// Исполняемый таргет появится вместе с первым роутом (§20.3), тестовый — вместе
// с первым кодом, который есть что проверять (Auth/, тест 20b).
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
        .package(path: "../Packages/FitAPI")
    ],
    targets: [
        .target(
            name: "FitServer",
            dependencies: ["FitCore", "FitAPI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
