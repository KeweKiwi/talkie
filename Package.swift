// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "talkie",
    platforms: [.macOS(.v15)],
    products: [.library(name: "TalkieCore", targets: ["TalkieCore"])],
    targets: [.target(name: "TalkieCore"), .testTarget(name: "TalkieCoreTests", dependencies: ["TalkieCore"])],
    swiftLanguageModes: [.v5]
)
