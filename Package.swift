// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Keydance",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Keydance", targets: ["Keydance"])
    ],
    targets: [
        .executableTarget(
            name: "Keydance",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KeydanceTests",
            dependencies: ["Keydance"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
