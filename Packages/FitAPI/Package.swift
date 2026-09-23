// swift-tools-version: 6.0
import PackageDescription

// FitAPI — форма границы /v1 (SPEC §20.2, §20.3): DTO обоих направлений плюс
// каталог русских формулировок к доменным причинам.
//
// Почему отдельный пакет, а не подкаталог Server/: исходящая форма — та же
// половина соответствия, что и Mapping/, и ей нужна та же гарантия. Положив её
// в сервер, мы получили бы второго клиента, пишущего вторую форму. Отсюда же
// TypeScript-типы фронтенда.
let package = Package(
    name: "FitAPI",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FitAPI", targets: ["FitAPI"])
    ],
    dependencies: [
        .package(path: "../FitCore")
    ],
    targets: [
        .target(
            name: "FitAPI",
            dependencies: ["FitCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FitAPITests",
            dependencies: ["FitAPI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
