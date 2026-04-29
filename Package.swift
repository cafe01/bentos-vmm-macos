// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "bentos-vmm-macos",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "bentos-vmm-macos", targets: ["BentosVmmMacos"]),
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "1.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "BentosVmmMacos",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
            ],
            path: "Sources/BentosVmmMacos",
            linkerSettings: [
                .linkedFramework("Virtualization"),
            ],
            plugins: [
                .plugin(name: "GRPCProtobufGenerator", package: "grpc-swift-protobuf"),
            ]
        ),
    ]
)
