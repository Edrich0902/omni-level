import AppKit
import Combine
import SwiftUI

/// Hosts the Dynamic Island–style Now Playing tray at the top of the display.
@MainActor
final class NotchNowPlayingController: NSObject {
    private let service: NowPlayingService
    private var panel: NotchPanel?
    private var hostingView: NSHostingView<NotchNowPlayingRootView>?
    private var trackingView: NotchTrackingView?
    private var geometry = NotchGeometry.detect()
    private var isExpanded = false
    private var collapseWorkItem: DispatchWorkItem?
    private var expandWorkItem: DispatchWorkItem?
    /// Continuous mouse poll while the island is shown — tracking areas alone miss enters.
    private var hoverPollTimer: Timer?
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?
    private var lastLayoutSignature = ""
    private var lastFrame: CGRect = .zero
    private let viewModel: NotchNowPlayingViewModel
    /// Brief suppress after collapse so we don't bounce open.
    private var collapseCooldownUntil: Date = .distantPast
    private var pointerOutsideSince: Date?
    /// How long the pointer has been in the collapsed hit zone (expand debounce).
    private var pointerInCollapsedSince: Date?

    init(service: NowPlayingService) {
        self.service = service
        self.viewModel = NotchNowPlayingViewModel(service: service)
        super.init()
    }

    func start() {
        service.start()
        buildPanelIfNeeded()
        observe()
        applyVisibility(animated: false)
        reposition(animated: false)
    }

    func stop() {
        stopPointerTracking()
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
            screenObserver = nil
        }
        cancellables.removeAll()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel?.close()
        panel = nil
        hostingView = nil
        trackingView = nil
    }

    // MARK: - Setup

    private func buildPanelIfNeeded() {
        guard panel == nil else { return }
        geometry = NotchGeometry.detect()
        let frame = targetFrame(expanded: false)

        let panel = NotchPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.ignoresMouseEvents = false
        // Ensure we receive events above the status strip.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)

        let tracking = NotchTrackingView(frame: NSRect(origin: .zero, size: frame.size))
        tracking.autoresizingMask = [.width, .height]
        tracking.wantsLayer = true
        tracking.layer?.backgroundColor = NSColor.clear.cgColor
        // Backup — primary path is continuous global pointer polling.
        tracking.onMouseEntered = { [weak self] in self?.requestExpand(immediate: true) }
        tracking.onMouseExited = { [weak self] in self?.notePointerMayHaveLeft() }

        let root = NotchNowPlayingRootView(viewModel: viewModel)
        let host = NSHostingView(rootView: root)
        host.frame = tracking.bounds
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.layer?.isOpaque = false

        tracking.addSubview(host)
        panel.contentView = tracking
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.setFrame(frame, display: true)

        self.panel = panel
        self.trackingView = tracking
        self.hostingView = host
        self.viewModel.geometry = geometry
        self.viewModel.isExpanded = false
    }

    private func observe() {
        service.$players
            .receive(on: RunLoop.main)
            .sink { [weak self] players in
                guard let self else { return }
                let signature = self.layoutSignature(for: players)
                let visibilityChanged = self.applyVisibility(animated: true)
                if signature != self.lastLayoutSignature || visibilityChanged {
                    self.lastLayoutSignature = signature
                    self.reposition(animated: !self.isExpanded)
                    if self.isExpanded {
                        self.reposition(animated: true)
                    }
                }
            }
            .store(in: &cancellables)

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.geometry = NotchGeometry.detect()
                self?.viewModel.geometry = self?.geometry ?? NotchGeometry.detect()
                self?.lastLayoutSignature = ""
                self?.reposition(animated: false)
            }
        }
    }

    private func layoutSignature(for players: [NowPlayingItem]) -> String {
        players.map { "\($0.id):\($0.hasProgress ? 1 : 0)" }.joined(separator: "|")
            + (isExpanded ? "#e" : "#c")
    }

    // MARK: - Visibility & layout

    @discardableResult
    private func applyVisibility(animated: Bool) -> Bool {
        guard let panel else { return false }
        let shouldShow = !service.players.isEmpty
        viewModel.hasContent = shouldShow
        let wasVisible = panel.isVisible

        if shouldShow {
            if !panel.isVisible {
                panel.alphaValue = 1
                panel.orderFrontRegardless()
                startPointerTracking()
                return true
            }
            startPointerTracking()
        } else {
            if isExpanded {
                forceCollapse(animated: false)
            }
            stopPointerTracking()
            if panel.isVisible {
                panel.orderOut(nil)
                return true
            }
        }
        return wasVisible != panel.isVisible
    }

    private func expandedContentSize() -> CGSize {
        let count = max(service.players.count, 1)
        let width: CGFloat = count > 1 ? 430 : 390
        var body: CGFloat = 8
        for player in service.players {
            body += player.hasProgress ? 108 : 78
            body += 12
        }
        if service.players.isEmpty {
            body += 90
        }
        let height = geometry.height + body + 8
        return CGSize(width: width, height: height)
    }

    private func collapsedWingExtension() -> CGFloat {
        service.players.count > 1 ? 88 : 76
    }

    private func targetFrame(expanded: Bool) -> CGRect {
        if expanded {
            return geometry.expandedFrame(size: expandedContentSize())
        }
        return geometry.collapsedFrame(wingExtension: collapsedWingExtension())
    }

    private func reposition(animated: Bool) {
        guard let panel, panel.isVisible || !service.players.isEmpty else { return }
        geometry = NotchGeometry.detect()
        viewModel.geometry = geometry
        let frame = targetFrame(expanded: isExpanded)
        if abs(frame.minX - lastFrame.minX) < 0.5,
           abs(frame.minY - lastFrame.minY) < 0.5,
           abs(frame.width - lastFrame.width) < 0.5,
           abs(frame.height - lastFrame.height) < 0.5 {
            return
        }
        lastFrame = frame
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = isExpanded ? 0.26 : 0.2
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
                ctx.allowsImplicitAnimation = true
                panel.animator().setFrame(frame, display: true)
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    self?.trackingView?.refreshTrackingAreas()
                    // After expand animation, re-check pointer still inside.
                    self?.evaluatePointer()
                }
            }
        } else {
            panel.setFrame(frame, display: true)
            trackingView?.refreshTrackingAreas()
        }
    }

    // MARK: - Hit testing

    /// Hover uses a pad around the visual frame — panel itself stays menubar-height.
    private func collapsedHitFrame() -> CGRect {
        geometry.collapsedHoverFrame(wingExtension: collapsedWingExtension())
    }

    private func expandedHitFrame() -> CGRect {
        guard let panel else { return targetFrame(expanded: true) }
        return panel.frame.insetBy(dx: -10, dy: -12)
    }

    // MARK: - Expand / collapse

    private func requestExpand(immediate: Bool) {
        guard Date() >= collapseCooldownUntil else { return }
        guard !service.players.isEmpty else { return }
        guard !isExpanded else { return }

        expandWorkItem?.cancel()
        if immediate {
            expandNow()
            return
        }
        // Slight dwell so a fast menubar pass doesn't flash the tray open.
        let work = DispatchWorkItem { [weak self] in
            self?.expandNow()
        }
        expandWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07, execute: work)
    }

    private func expandNow() {
        guard Date() >= collapseCooldownUntil else { return }
        guard !service.players.isEmpty, !isExpanded else { return }
        collapseWorkItem?.cancel()
        expandWorkItem?.cancel()
        pointerOutsideSince = nil
        pointerInCollapsedSince = nil

        isExpanded = true
        viewModel.isExpanded = true
        lastLayoutSignature = layoutSignature(for: service.players)
        lastFrame = .zero
        reposition(animated: true)
        // Do NOT makeKey — freezes popover / event delivery.
    }

    private func notePointerMayHaveLeft() {
        if isExpanded {
            scheduleCollapse(delay: 0.2)
        } else {
            expandWorkItem?.cancel()
            pointerInCollapsedSince = nil
        }
    }

    private func scheduleCollapse(delay: TimeInterval) {
        collapseWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.collapseIfMouseOutside(force: false)
        }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func collapseIfMouseOutside(force: Bool) {
        guard isExpanded else { return }
        let mouse = NSEvent.mouseLocation
        if force {
            forceCollapse(animated: true)
            return
        }
        if expandedHitFrame().contains(mouse) {
            pointerOutsideSince = nil
            return
        }
        if pointerOutsideSince == nil {
            pointerOutsideSince = Date()
            scheduleCollapse(delay: 0.22)
            return
        }
        if Date().timeIntervalSince(pointerOutsideSince!) >= 0.18 {
            forceCollapse(animated: true)
        }
    }

    private func forceCollapse(animated: Bool) {
        collapseWorkItem?.cancel()
        expandWorkItem?.cancel()
        pointerOutsideSince = nil
        pointerInCollapsedSince = nil
        guard isExpanded else { return }
        isExpanded = false
        viewModel.isExpanded = false
        collapseCooldownUntil = Date().addingTimeInterval(0.18)
        lastLayoutSignature = layoutSignature(for: service.players)
        lastFrame = .zero
        reposition(animated: animated)
    }

    // MARK: - Continuous pointer tracking

    private func startPointerTracking() {
        guard hoverPollTimer == nil else { return }

        // ~60 Hz is enough to feel instant without burning CPU.
        hoverPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.evaluatePointer()
            }
        }
        if let hoverPollTimer {
            RunLoop.main.add(hoverPollTimer, forMode: .common)
        }

        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                DispatchQueue.main.async { self?.evaluatePointer() }
            }
        }
        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown]
            ) { [weak self] event in
                DispatchQueue.main.async { self?.evaluatePointer() }
                return event
            }
        }
    }

    private func stopPointerTracking() {
        expandWorkItem?.cancel()
        expandWorkItem = nil
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        hoverPollTimer?.invalidate()
        hoverPollTimer = nil
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        pointerOutsideSince = nil
        pointerInCollapsedSince = nil
    }

    /// Central hover state machine — works even when the panel never sees Cocoa enter/exit.
    private func evaluatePointer() {
        guard panel?.isVisible == true, !service.players.isEmpty else { return }
        let mouse = NSEvent.mouseLocation

        if isExpanded {
            if expandedHitFrame().contains(mouse) {
                pointerOutsideSince = nil
                collapseWorkItem?.cancel()
            } else {
                collapseIfMouseOutside(force: false)
            }
            return
        }

        // Collapsed: dwell briefly then expand.
        if collapsedHitFrame().contains(mouse) {
            if Date() < collapseCooldownUntil { return }
            if pointerInCollapsedSince == nil {
                pointerInCollapsedSince = Date()
            }
            if Date().timeIntervalSince(pointerInCollapsedSince!) >= 0.05 {
                requestExpand(immediate: true)
            } else {
                requestExpand(immediate: false)
            }
        } else {
            pointerInCollapsedSince = nil
            expandWorkItem?.cancel()
        }
    }
}

// MARK: - Tracking view

final class NotchTrackingView: NSView {
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        // No assumeInside — that suppressed enter events after expand/collapse.
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [
                    .mouseEnteredAndExited,
                    .mouseMoved,
                    .activeAlways,
                    .inVisibleRect
                ],
                owner: self
            )
        )
    }

    func refreshTrackingAreas() {
        updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { onMouseEntered?() }
    override func mouseExited(with event: NSEvent) { onMouseExited?() }
    override func mouseMoved(with event: NSEvent) { onMouseEntered?() }

    override var isFlipped: Bool { true }

    /// Entire panel frame is hoverable even over empty SwiftUI regions.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }
}

// MARK: - View model

@MainActor
final class NotchNowPlayingViewModel: ObservableObject {
    @Published var isExpanded = false
    @Published var geometry = NotchGeometry.detect()
    @Published var hasContent = false

    let service: NowPlayingService

    init(service: NowPlayingService) {
        self.service = service
    }
}
