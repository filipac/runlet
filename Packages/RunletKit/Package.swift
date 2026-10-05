// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RunletKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RunletCore", targets: ["RunletCore"]),
        .library(name: "RunletExecution", targets: ["RunletExecution"]),
        .library(name: "RunletLanguage", targets: ["RunletLanguage"]),
    ],
    targets: [
        .target(name: "RunletCore"),
        .target(name: "RunletExecution", dependencies: ["RunletCore"]),
        .target(name: "RunletLanguage", dependencies: ["RunletCore"]),
        .testTarget(name: "RunletCoreTests", dependencies: ["RunletCore"]),
        .testTarget(name: "RunletExecutionTests", dependencies: ["RunletExecution", "RunletCore"]),
        .testTarget(name: "RunletLanguageTests", dependencies: ["RunletLanguage", "RunletCore"]),
    ]
)
