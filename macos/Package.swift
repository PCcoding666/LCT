// swift-tools-version: 5.9
// LCT for macOS - Swift Package Configuration

import PackageDescription

let package = Package(
    name: "LCTMac",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "LCTMac", targets: ["LCTMac"])
    ],
    dependencies: [
        // SQLite for data persistence
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.0"),
    ],
    targets: [
        .executableTarget(
            name: "LCTMac",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift")
            ],
            path: "LCTMac",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "LCTMacTests",
            dependencies: ["LCTMac"],
            path: "Tests"
        )
    ]
)
