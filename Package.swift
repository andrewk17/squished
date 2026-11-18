// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [.library(name: "SquishedCore", targets: ["SquishedCore"])]
var targets: [Target] = [
    .target(name: "SquishedCore"),
    .testTarget(name: "SquishedCoreTests", dependencies: ["SquishedCore"], resources: [.copy("Fixtures")])
]
#if os(macOS)
products.append(.executable(name: "Squished", targets: ["Squished"]))
targets.append(.executableTarget(name: "Squished", dependencies: ["SquishedCore"], swiftSettings: [.swiftLanguageMode(.v5)]))
#endif
let package = Package(name: "Squished", platforms: [.macOS(.v14)], products: products, targets: targets)
