// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Notulen",
    platforms: [.macOS(.v26)],
    dependencies: [
        // traits: [] drops the default NemoTextProcessing trait (a prebuilt binary).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []),
    ],
    targets: [
        .executableTarget(
            name: "Notulen",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "App",
            exclude: ["Support"]
        ),
        .testTarget(name: "NotulenTests", dependencies: ["Notulen"], path: "Tests/NotulenTests", resources: [.copy("Fixtures")]),
    ]
)
