// swift-tools-version: 6.0
import PackageDescription

// FitCore — чистая логика. Зависимостей нет и быть не должно:
// ни SwiftUI, ни SwiftData, ни Foundation.Date в бизнес-логике.
// См. план, раздел 2 («Ключевые правила»).
let package = Package(
    name: "FitCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FitCore", targets: ["FitCore"])
    ],
    targets: [
        .target(
            name: "FitCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FitCoreTests",
            dependencies: ["FitCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
