// swift-tools-version: 6.0
import PackageDescription

// FitTestSupport — фикстуры для тестов: профили инвентаря, пользователи,
// готовые истории тренировок и циклов. Отдельным пакетом, чтобы фикстуры
// переиспользовались между FitCoreTests, FitDataTests и golden-тестами.
let package = Package(
    name: "FitTestSupport",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FitTestSupport", targets: ["FitTestSupport"])
    ],
    dependencies: [
        .package(path: "../FitCore"),
        .package(path: "../FitContent")
    ],
    targets: [
        .target(
            name: "FitTestSupport",
            dependencies: ["FitCore", "FitContent"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
