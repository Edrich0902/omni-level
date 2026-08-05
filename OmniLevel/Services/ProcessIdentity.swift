import AppKit
import Foundation

/// Resolves running application identity (name, icon, bundle ID).
public final class ProcessIdentity: Sendable {
    public init() {}

    public func candidateApplications() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular && !app.isTerminated
        }
    }

    public func icon(for app: NSRunningApplication) -> NSImage {
        if let icon = app.icon {
            return icon
        }
        if let url = app.bundleURL {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app.fill", accessibilityDescription: "App")
            ?? NSImage(size: NSSize(width: 32, height: 32))
    }
}
