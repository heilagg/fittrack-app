// swift-tools-version: 6.0
import PackageDescription

// FitContent — библиотека упражнений и шаблонов растяжки: JSON + загрузчик
// + предвычисленные индексы (по мышце, по паттерну, по инвентарю).
let package = Package(
    name: "FitContent",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FitContent", targets: ["FitContent"])
    ],
    dependencies: [
        .package(path: "../FitCore")
    ],
    targets: [
        .target(
            name: "FitContent",
            dependencies: ["FitCore"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FitContentTests",
            dependencies: ["FitContent"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
