// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AndroidTransfer",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AndroidTransfer", targets: ["AndroidTransfer"])
    ],
    targets: [
        .systemLibrary(
            name: "CLibMTP",
            pkgConfig: "libmtp",
            providers: [.brew(["libmtp"])]
        ),
        .target(name: "TransferCore"),
        .executableTarget(
            name: "AndroidTransfer",
            dependencies: ["CLibMTP", "TransferCore"]
        ),
        .testTarget(name: "TransferCoreTests", dependencies: ["TransferCore"])
    ]
)
