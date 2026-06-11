// swift-tools-version: 6.0
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
            exclude: ["LCTMac.entitlements", "Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "LCTMac/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "LCTMacTests",
            dependencies: ["LCTMac"],
            path: "Tests/LCTMacTests"
        )
    ]
)
