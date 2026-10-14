// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Nogrammerly",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Nogrammerly", targets: ["Nogrammerly"])],
    targets: [
        .executableTarget(
            name: "Nogrammerly",
            // FoundationModels only exists on macOS 26+; weak-link it so the app still launches on 14/15 with AI checks off.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"])]
        ),
        .testTarget(name: "NogrammerlyTests", dependencies: ["Nogrammerly"])
    ]
)
