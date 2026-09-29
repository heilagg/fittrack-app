// swift-tools-version: 6.0
import PackageDescription

// Server — Vapor-обёртка над FitCore (SPEC §20). Первый пакет репозитория с
// внешними зависимостями и первый, собираемый под Linux; архитектура модуля —
// в doc-комментарии Sources/FitServer/FitServer.swift.
//
// Зависимости приезжают ровно тогда, когда появляется код, который их зовёт:
// JWTKit вместе с `Auth/`, postgres-nio вместе с `DB/`, Vapor вместе с
// `Routes/` — раньше его не звал никто. Для `Auth/` отсутствие Vapor было
// решением (политика §20.5 — свой кеш и два счётчика троттла — не ложится в
// одну глобальную `app.jwt`), для `DB/` — просто отсутствием надобности: пул и
// транзакция к HTTP-слою не относятся. Оба остаются написанными без него, и
// побочная выгода сохраняется: 20b и 20k по-прежнему тесты пакета, без
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
// Целей сборки две. Библиотека `FitServer` держит всё, включая `Routes/`:
// роут, положенный в исполняемый таргет, нельзя ни импортировать в тест, ни
// вызвать из него, а §20.15 требует прогонять эндпоинты через HTTP (20a, 20d).
// Исполняемый `fitserver` остаётся тонким — конфигурация из среды, старт JWKS,
// пул, `Routes.register`, — и своей логики не несёт вовсе; именно поэтому его
// нечем тестировать и незачем.
//
// Таргет исполняемого — `FitServerRun`, а не `fitserver`, хотя бинарь
// называется вторым. Причина файловая и стоила одной пересборки: macOS
// нечувствителен к регистру, поэтому `Sources/fitserver` и `Sources/FitServer`
// — один и тот же каталог, и `main.swift` молча уезжает в библиотеку, делая её
// исполняемой. Пара `content-validator`/`ContentValidator` в `Tools/` этого не
// показывает: там имена различаются дефисом, а не только регистром.
//
// platforms задаёт только нижнюю границу платформ Apple; Linux, ради которого
// пакет и существует, ограничением не описывается. Значение унаследовано от
// FitCore и FitAPI — ниже их подняться нельзя.
let package = Package(
    name: "FitServer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FitServer", targets: ["FitServer"]),
        .executable(name: "fitserver", targets: ["FitServerRun"])
    ],
    dependencies: [
        .package(path: "../Packages/FitCore"),
        .package(path: "../Packages/FitAPI"),
        // FitContent линкуется в сервер и раздаётся им (§20.11): `Content/`
        // превращает разметку в байты ответа.
        .package(path: "../Packages/FitContent"),
        .package(url: "https://github.com/vapor/jwt-kit.git", from: "5.0.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.33.0"),
        // swift-crypto объявлен явно, хотя JWTKit 5 и так на нём: `ETag` §20.11
        // — это SHA-256, и зависеть на неё транзитивно значило бы, что смена
        // реализации JWT ломает хеш контента.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        // Vapor приезжает вместе с `Routes/` (§20.3). Нижняя граница не
        // декоративна: `VaporTesting` (swift-testing вместо XCTest) появился в
        // 4.110.0, а весь остальной репозиторий уже на swift-testing, и второй
        // тестовый фреймворк ради одного пакета заводить незачем.
        .package(url: "https://github.com/vapor/vapor.git", from: "4.110.0")
    ],
    targets: [
        .target(
            name: "FitServer",
            dependencies: [
                "FitCore",
                "FitAPI",
                "FitContent",
                .product(name: "JWTKit", package: "jwt-kit"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Vapor", package: "vapor")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "FitServerRun",
            dependencies: [
                "FitServer",
                "FitContent",
                .product(name: "Vapor", package: "vapor"),
                // Ради `PostgresClient.Configuration.TLS`: выбор TLS — это
                // конфигурация среды (§20.4), и делается он здесь.
                .product(name: "PostgresNIO", package: "postgres-nio")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FitServerTests",
            dependencies: [
                "FitServer",
                "FitContent",
                .product(name: "JWTKit", package: "jwt-kit"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "VaporTesting", package: "vapor")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
