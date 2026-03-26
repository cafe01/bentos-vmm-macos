// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "bentos-vmm-macos",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "bentos-vmm-macos", targets: ["BentosVmmMacos"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.20.0"),
    ],
    targets: [
        .executableTarget(
            name: "BentosVmmMacos",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOExtras", package: "swift-nio-extras"),
            ],
            path: "Sources/BentosVmmMacos",
            linkerSettings: [
                .linkedFramework("Virtualization"),
            ]
        ),
        .testTarget(
            name: "BentosVmmMacosTests",
            dependencies: [
                "BentosVmmMacos",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Tests/BentosVmmMacosTests"
        ),
    ]
)
