// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Doppio",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DoppioCore", targets: ["DoppioCore"]),
        .executable(name: "DoppioShot", targets: ["DoppioShot"]),
        .executable(name: "DoppioApp", targets: ["DoppioApp"]),
        .executable(name: "doppio", targets: ["DoppioCLI"]),
        .executable(name: "DoppioTests", targets: ["DoppioTests"]),
    ],
    targets: [
        .target(
            name: "DoppioCore",
            resources: [.process("Resources")]
        ),
        // The stub embedded in every Shot. No dependency on DoppioCore:
        // it must stay tiny and self-contained.
        .executableTarget(name: "DoppioShot"),
        .executableTarget(name: "DoppioApp", dependencies: ["DoppioCore"]),
        .executableTarget(name: "DoppioCLI", dependencies: ["DoppioCore"]),
        // A plain executable rather than a testTarget: neither XCTest nor
        // swift-testing is available with the Command Line Tools alone.
        .executableTarget(name: "DoppioTests", dependencies: ["DoppioCore"]),
    ]
)
