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

/// Re-evaluates `content` at display rate while the popover is open. Use for small leaf
/// views that read live data from a reference type: inside NSPopover, ObservableObject
/// changes alone only reach the screen on the next unrelated redraw, TimelineView ticks do.
struct LiveTimeline<Content: View>: View {
    var minimumInterval: Double = 1.0 / 30.0
    @ViewBuilder var content: () -> Content
    @Environment(\.liveUpdatesEnabled) private var liveUpdatesEnabled

    var body: some View {
        TimelineView(.animation(minimumInterval: minimumInterval, paused: !liveUpdatesEnabled)) { _ in
            content()
        }
    }
}
