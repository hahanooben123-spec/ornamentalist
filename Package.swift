// swift-tools-version: 5.9
import PackageDescription

// Portable model tests. The actual iPad application is Ornamentalist.swiftpm.
let package = Package(
    name: "OrnamentalistCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "OrnamentalistCore", targets: ["OrnamentalistCore"])],
    targets: [
        .target(name: "OrnamentalistCore", path: "Ornamentalist.swiftpm",
                exclude: ["Package.swift", "App", "CanvasRenderer", "DrawingEngine", "ExportEngine",
                          "UIComponents", "DocumentStore/StudioModel.swift"],
                sources: ["Core", "DocumentStore/DocumentRepository.swift"]),
        .testTarget(name: "OrnamentalistCoreTests", dependencies: ["OrnamentalistCore"], path: "Tests",
                    exclude: ["iOS"])
    ]
)
