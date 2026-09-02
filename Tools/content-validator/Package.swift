// swift-tools-version: 6.0
import PackageDescription

// Валидатор контента. Запускается в CI и падает до того, как кривая разметка
// доедет до алгоритма (SPEC §17, этап 2).
let package = Package(
    name: "content-validator",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../Packages/FitCore")
    ],
    targets: [
        .executableTarget(
            name: "content-validator",
            dependencies: ["FitCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
