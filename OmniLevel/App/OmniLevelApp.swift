import SwiftUI

@main
struct OmniLevelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu bar extra is owned by AppDelegate (NSStatusItem).
        // Settings scene kept for SwiftUI lifecycle; window suppressed via LSUIElement.
        Settings {
            EmptyView()
        }
    }
}
