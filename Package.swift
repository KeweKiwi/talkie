// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "talkie",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "talkie", targets: ["Talkie"]), .library(name: "TalkieCore", targets: ["TalkieCore"])],
    dependencies: [.package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1")],
    targets: [
        .target(name: "TalkieCore"),
        .executableTarget(name: "Talkie", dependencies: ["TalkieCore", .product(name: "WhisperKit", package: "argmax-oss-swift")]),
        .testTarget(name: "TalkieCoreTests", dependencies: ["TalkieCore"]),
        .testTarget(name: "TalkieTests", dependencies: ["Talkie"])
    ],
    swiftLanguageModes: [.v5]
)
