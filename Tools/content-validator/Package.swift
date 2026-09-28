// swift-tools-version: 6.0
import PackageDescription

// Валидатор контента. Запускается в CI и падает до того, как кривая разметка
// доедет до алгоритма (SPEC §17 этап 2, §20.11).
//
// Два таргета, а не один: проверки живут в библиотеке `ContentValidator`, и
// только она тестируется. Исполняемый таргет содержит разбор аргументов, вывод
// и код возврата — то есть ровно то, что тестом не покрывается. Пока проверки
// лежали в `.executableTarget`, тестов у них не было в принципе: тестовый
// таргет не может зависеть от исполняемого, а требование
// content-domain §3 — «у загрузчика, валидатора и Content/ тесты обычные».
let package = Package(
    name: "content-validator",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "content-validator", targets: ["content-validator"])
    ],
    dependencies: [
        .package(path: "../../Packages/FitCore"),
        // Правило покрытия §20.11 вызывает реальную сборку §7.3 на реальной
        // библиотеке, поэтому валидатору нужны оба: загрузчик из FitContent и
        // планировщик из FitCore. Счётным правилом обойтись нельзя —
        // content-domain §2 п.2.
        .package(path: "../../Packages/FitContent"),
    ],
    targets: [
        .target(
            name: "ContentValidator",
            dependencies: ["FitCore", "FitContent"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "content-validator",
            dependencies: ["ContentValidator", "FitContent"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ContentValidatorTests",
            dependencies: ["ContentValidator", "FitContent"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
