// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Espelho",
    platforms: [.macOS("26.0")],
    dependencies: [
        // MIT. In-app updates (feed at witchmymac.com/appcast/espelho.xml).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(
            name: "EspelhoEngine",
            path: "Sources/Espelho/Engine",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Espelho",
            dependencies: ["EspelhoEngine", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Espelho",
            exclude: ["Engine"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "EspelhoTests",
            dependencies: ["EspelhoEngine"],
            path: "Tests/EspelhoTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
