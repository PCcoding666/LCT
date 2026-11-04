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
        .binaryTarget(
            name: "LlamaFramework",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11960/llama-b11960-xcframework.zip",
            checksum: "feba05e0b7cb5e682ae3354abb455bf9723ae2cc95c69e24d073264e6a34d759"
        ),
        .executableTarget(
            name: "LCTMac",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift"),
                "LlamaFramework"
            ],
            path: "LCTMac",
            exclude: ["LCTMac.entitlements", "Info.plist", "Resources"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "LCTMac/Info.plist",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
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
