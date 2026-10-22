// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "RemoteCoderCore",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [.library(name: "RemoteCoderCore", targets: ["RemoteCoderCore"])],
    targets: [
        // The app's Tuist target compiles these same source files. Keeping them
        // internal avoids exposing app implementation details as a public API.
        .target(name: "RemoteCoderCore", swiftSettings: [
            .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            .enableUpcomingFeature("InferIsolatedConformances"),
            .enableUpcomingFeature("MemberImportVisibility"),
        ]),
        .testTarget(name: "RemoteCoderCoreTests", dependencies: ["RemoteCoderCore"]),
    ],
    swiftLanguageModes: [.v6]
)
