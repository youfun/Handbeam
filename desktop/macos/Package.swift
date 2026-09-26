// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Handbeam",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "Handbeam", targets: ["Handbeam"])
    ],
    targets: [
        .target(name: "HandbeamCore"),
        .executableTarget(
            name: "Handbeam",
            dependencies: ["HandbeamCore"]
        ),
        .testTarget(
            name: "HandbeamCoreTests",
            dependencies: ["HandbeamCore"]
        ),
    ]
)
