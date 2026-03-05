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
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.11.2"),
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
        )
    ]
)
