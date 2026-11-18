// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LocalCaptions",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: ".runtime/FluidAudio", traits: [])],
    targets: [
        .executableTarget(name: "LocalCaptions", dependencies: [
            .product(name: "FluidAudio", package: "FluidAudio")
        ], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "LocalCaptionsTests", dependencies: ["LocalCaptions"], path: "Tests")
    ]
)
