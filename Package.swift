// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "minus196",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "Minus196Core", targets: ["Minus196Core"]),
        .executable(name: "minus196", targets: ["minus196"]),
        .executable(name: "Minus196App", targets: ["Minus196App"]),
    ],
    targets: [
        .target(name: "Minus196Core"),
        .executableTarget(name: "minus196", dependencies: ["Minus196Core"]),
        .executableTarget(name: "Minus196App", dependencies: ["Minus196Core"]),
        .testTarget(name: "Minus196CoreTests", dependencies: ["Minus196Core"]),
    ]
)
