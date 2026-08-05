import Foundation
import ServiceManagement

/// Launch-at-login via SMAppService (macOS 13+).
@MainActor
public final class LaunchAtLoginService: ObservableObject {
    @Published public private(set) var isEnabled: Bool = false
    @Published public private(set) var lastError: String?

    public init() {
        refresh()
    }

    public func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    public func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status == .enabled {
                    isEnabled = true
                    return
                }
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
            refresh()
        } catch {
            lastError = error.localizedDescription
            refresh()
        }
    }

    public func toggle() {
        setEnabled(!isEnabled)
    }
}
