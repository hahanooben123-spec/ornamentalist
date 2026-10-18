import SwiftUI

@main
@MainActor
struct OrnamentalistApp: App {
    init() {
        print("Ornamentalist 0.6.0: app entry reached")
    }
    var body: some Scene {
        WindowGroup { StudioView() }
    }
}
