// swift-tools-version: 5.9
import PackageDescription
import AppleProductTypes

let package = Package(
    name: "Ornamentalist",
    platforms: [.iOS("17.0")],
    products: [
        .iOSApplication(
            name: "Ornamentalist",
            targets: ["Ornamentalist"],
            bundleIdentifier: "studio.mandala.prototype",
            displayVersion: "0.11.0",
            bundleVersion: "33",
            appIcon: .asset("AppIcon"),
            accentColor: .presetColor(.teal),
            supportedDeviceFamilies: [.pad],
            supportedInterfaceOrientations: [.portrait, .portraitUpsideDown(.when(deviceFamilies: [.pad])), .landscapeLeft, .landscapeRight]
        )
    ],
    targets: [
        .executableTarget(
            name: "Ornamentalist",
            path: ".",
            sources: [
                "App/OrnamentalistApp.swift",
                "CanvasRenderer/MetalCanvasRenderer.swift",
                "Core/BrushEngine/InkBrush.swift",
                "Core/BrushEngine/BrushGeometry.swift",
                "Core/DrawingLimits.swift",
                "Core/Geometry.swift",
                "Core/InkColor.swift",
                "Core/LayerManager.swift",
                "Core/LayerRaster.swift",
                "Core/StrokeGeometry.swift",
                "Core/StrokeModel/StrokeHistory.swift",
                "Core/StrokeModel/StrokeModel.swift",
                "Core/StrokeModel/StrokeSession.swift",
                "Core/SymmetryEngine/SymmetryEngine.swift",
                "DocumentStore/DocumentRepository.swift",
                "DocumentStore/StudioModel.swift",
                "DrawingEngine/PencilCanvasView.swift",
                "ExportEngine/PNGExporter.swift",
                "UIComponents/StudioGallery.swift",
                "UIComponents/StudioLayers.swift",
                "UIComponents/LayerPreview.swift",
                "UIComponents/StudioEraser.swift",
                "UIComponents/StudioPanels.swift",
                "UIComponents/StudioBrushes.swift",
                "UIComponents/StudioColors.swift",
                "UIComponents/StudioColorWheel.swift",
                "UIComponents/StudioShowcase.swift",
                "UIComponents/StudioTheme.swift",
                "UIComponents/StudioView.swift"
            ],
            resources: [.process("Resources")]
        )
    ]
)
