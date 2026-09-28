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
            // `.copy`, а не `.process`: загрузчик обходит `Resources/exercises`
            // и `Resources/vectors` как каталоги, а `.process` не обязана
            // сохранять их структуру в бандле. Обрабатывать в JSON нечего.
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FitContentTests",
            dependencies: ["FitContent"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
