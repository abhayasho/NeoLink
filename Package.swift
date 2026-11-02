// swift-tools-version: 5.10
// Note: we intentionally target Swift 5.10 here to avoid
// Swift 6's very strict concurrency runtime checks, which
// conflict with the current version of swift-ssh-client.

import PackageDescription

let package = Package(
    name: "NeoLink",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "NeoLink", targets: ["NeoLink"])
    ],
    dependencies: [
        // 1.20 provides native Metal text rendering. Keep the 1.x API pinned;
        // 1.99 and later introduce the separate SwiftTerm 2.0 API migration.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"),
        .package(url: "https://github.com/gaetanzanella/swift-ssh-client.git", from: "0.1.0")
    ],
    targets: [
        .executableTarget(
            name: "NeoLink",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "SSHClient", package: "swift-ssh-client")
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "NeoLinkTests",
            dependencies: ["NeoLink"],
            path: "Tests/NeoLinkTests"
        )
    ]
)
