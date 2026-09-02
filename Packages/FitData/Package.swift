// swift-tools-version: 6.0
import PackageDescription

// FitData — SwiftData-модели, репозитории, синхронизация с Supabase.
// Единственное место в проекте, знающее про сеть и про постоянное хранилище.
let package = Package(
    name: "FitData",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FitData", targets: ["FitData"])
    ],
    dependencies: [
        .package(path: "../FitCore"),
        .package(path: "../FitContent"),
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.55.1")
    ],
    targets: [
        .target(
            name: "FitData",
            dependencies: [
                "FitCore",
                "FitContent",
                .product(name: "Supabase", package: "supabase-swift")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FitDataTests",
            dependencies: ["FitData"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
