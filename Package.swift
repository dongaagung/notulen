// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Notulen",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "Notulen", path: "App", exclude: ["Support"]),
        .testTarget(name: "NotulenTests", dependencies: ["Notulen"], path: "Tests/NotulenTests", resources: [.copy("Fixtures")]),
    ]
)
