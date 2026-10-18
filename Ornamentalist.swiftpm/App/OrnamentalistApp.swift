import SwiftUI

@main
@MainActor
struct OrnamentalistApp: App {
    init() {
        print("Ornamentalist 0.5.0: app entry reached")
    }
    var body: some Scene {
        WindowGroup { StudioView() }
    }
}
