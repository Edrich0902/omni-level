import AppKit

/// Floating, non-activating panel that sits over the menu-bar / notch region.
/// Never becomes key — key windows steal focus and freeze the menu-bar popover.
final class NotchPanel: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing bufferingType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: style,
            backing: bufferingType,
            defer: flag
        )
        isFloatingPanel = true
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isMovable = false
        hasShadow = false
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle
        ]
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
