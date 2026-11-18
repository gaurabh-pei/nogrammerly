// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Nogrammerly",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "Nogrammerly", targets: ["Nogrammerly"]),
        // Shared writing engine (spelling, style rules, on-device AI); also used by the iOS app and keyboard in iOS/.
        .library(name: "NogrammerlyCore", targets: ["NogrammerlyCore"])
    ],
    targets: [
        .target(name: "NogrammerlyCore"),
        .executableTarget(
            name: "Nogrammerly",
            dependencies: ["NogrammerlyCore"],
            // FoundationModels only exists on macOS 26+; weak-link it so the app still launches on 14/15 with AI checks off.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"])]
        ),
        .testTarget(name: "NogrammerlyTests", dependencies: ["Nogrammerly", "NogrammerlyCore"], resources: [.copy("Fixtures")])
    ]
)
