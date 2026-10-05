import SwiftUI

/// Whether the menu-bar popover is on screen. NSPopover keeps its SwiftUI tree alive
/// while closed, so animated meters must pause themselves or they render invisibly.
@MainActor
final class PopoverVisibility: ObservableObject {
    @Published var isShown = false
}

private struct LiveUpdatesEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False while the hosting popover is closed — pause TimelineViews / meter pumps.
    var liveUpdatesEnabled: Bool {
        get { self[LiveUpdatesEnabledKey.self] }
        set { self[LiveUpdatesEnabledKey.self] = newValue }
    }
}

/// Root wrapper that publishes popover visibility into the environment.
struct PopoverRootView<Content: View>: View {
    @ObservedObject var visibility: PopoverVisibility
    let content: Content

    var body: some View {
        content.environment(\.liveUpdatesEnabled, visibility.isShown)
    }
}
