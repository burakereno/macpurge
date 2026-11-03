// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "MacPurge",
    platforms: [.macOS(.v14)],
    products: [.library(name:"MacPurgeCore",targets:["MacPurgeCore"]), .executable(name:"MacPurge",targets:["MacPurge"])],
    targets: [
        .target(name:"MacPurgeCore"),
        .executableTarget(name: "MacPurge",dependencies:["MacPurgeCore"]),
        .testTarget(name: "MacPurgeTests", dependencies: ["MacPurge","MacPurgeCore"])
    ],
    swiftLanguageModes: [.v6]
)
