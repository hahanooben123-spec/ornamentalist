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
            bundleIdentifier: "studio.mandala.prototype.starttest",
            displayVersion: "0.3.0",
            bundleVersion: "5",
            appIcon: .placeholder(icon: .pencil),
            accentColor: .presetColor(.teal),
            supportedDeviceFamilies: [.pad],
            supportedInterfaceOrientations: [.portrait, .portraitUpsideDown(.when(deviceFamilies: [.pad])), .landscapeLeft, .landscapeRight]
        )
    ],
    targets: [.executableTarget(name: "Ornamentalist", path: ".")]
)
