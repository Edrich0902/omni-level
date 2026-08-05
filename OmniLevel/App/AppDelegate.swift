import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var notchController: NotchNowPlayingController?
    /// Menu-bar accessory apps break `.transient` after `makeKey`; we close on outside clicks.
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?

    let tapManager = AppAudioTapManager()
    let nowPlaying = NowPlayingService()
    let presetStore = PresetStore()
    lazy var equalizerVM = EqualizerViewModel(
        dsp: tapManager.engine.equalizer,
        limiter: tapManager.engine.limiter,
        presetStore: presetStore,
        onChange: { [weak self] in
            self?.tapManager.engine.syncPreAmpFromEQ()
        }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let icon = NSImage(named: "AppIcon") {
            NSApp.applicationIconImage = icon
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "OmniLevel") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "OL"
            }
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        statusItem = item

        // Restore EQ before UI so the first paint shows the saved curve.
        equalizerVM.restoreLastSessionIfAvailable()

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 480, height: 760)
        if let appearance = NSAppearance(named: .vibrantDark) {
            popover.appearance = appearance
        }
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: ContentView(
                tapManager: tapManager,
                equalizerVM: equalizerVM,
                presetStore: presetStore,
                nowPlaying: nowPlaying
            )
        )
        self.popover = popover

        tapManager.bootstrap()

        let notch = NotchNowPlayingController(service: nowPlaying)
        notch.start()
        notchController = notch
    }

    func applicationWillTerminate(_ notification: Notification) {
        equalizerVM.flushSessionToDisk()
        removeClickMonitors()
        notchController?.stop()
        nowPlaying.stop()
        tapManager.shutdown()
    }

    // MARK: - Popover

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            closePopover()
        } else {
            popover.contentSize = NSSize(width: 480, height: 760)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            installClickMonitors()
        }
    }

    private func closePopover() {
        guard let popover else {
            removeClickMonitors()
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        }
        removeClickMonitors()
    }

    private func installClickMonitors() {
        removeClickMonitors()

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            // Prefer DispatchQueue over Task so close isn't queued behind other MainActor work.
            DispatchQueue.main.async {
                self?.closeIfClickOutside()
            }
        }

        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            DispatchQueue.main.async {
                self?.closeIfClickOutside()
            }
            return event
        }
    }

    private func removeClickMonitors() {
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
    }

    private func closeIfClickOutside() {
        guard let popover, popover.isShown else { return }

        let point = NSEvent.mouseLocation

        // Keep open when clicking the menu bar icon (toggle handles that).
        if let button = statusItem?.button,
           let win = button.window {
            let buttonFrame = win.convertToScreen(button.convert(button.bounds, to: nil))
            if buttonFrame.contains(point) { return }
        }

        // Keep open when interacting with the popover itself.
        if let popWindow = popover.contentViewController?.view.window,
           popWindow.frame.contains(point) {
            return
        }

        closePopover()
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        removeClickMonitors()
    }
}
