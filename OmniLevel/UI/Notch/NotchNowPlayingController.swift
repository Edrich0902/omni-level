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
    private var hoverPollTimer: Timer?
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?
    private var lastLayoutSignature = ""
    private var lastFrame: CGRect = .zero
    private let viewModel: NotchNowPlayingViewModel
    private var collapseCooldownUntil: Date = .distantPast
    private var pointerOutsideSince: Date?
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
        // Collapsed: clicks pass through to menu bar; expand via pointer poll.
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)

        let tracking = NotchTrackingView(frame: NSRect(origin: .zero, size: frame.size))
        tracking.autoresizingMask = [.width, .height]
        tracking.wantsLayer = true
        tracking.layer?.backgroundColor = NSColor.clear.cgColor
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
                    self.reposition(animated: true)
                }
            }
            .store(in: &cancellables)

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
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
        let collapsedW = geometry.collapsedFrame(wingExtension: collapsedWingExtension()).width
        // Keep width close to collapsed so AppKit doesn't expand left/right from center.
        let width = max(collapsedW, count > 1 ? 340 : 300)
        let row: CGFloat = 56
        let body = CGFloat(count) * row + CGFloat(max(count - 1, 0)) * 6 + 12
        let height = min(geometry.height + body, geometry.height + 110)
        return CGSize(width: width, height: height)
    }

    private func collapsedWingExtension() -> CGFloat {
        service.players.count > 1 ? 72 : 64
    }

    private func targetFrame(expanded: Bool) -> CGRect {
        if expanded {
            return geometry.expandedFrame(size: expandedContentSize())
        }
        return geometry.collapsedFrame(wingExtension: collapsedWingExtension())
    }

    private func updateMousePassthrough() {
        panel?.ignoresMouseEvents = !isExpanded
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
            updateMousePassthrough()
            return
        }

        updateMousePassthrough()

        // Slide down/up from the notch: snap horizontal size, then animate only height/y.
        if animated, panel.isVisible, lastFrame.width > 1 {
            var widthLocked = lastFrame
            widthLocked.size.width = frame.width
            widthLocked.origin.x = frame.origin.x
            // Keep top edge glued to the screen top.
            widthLocked.origin.y = geometry.screenFrame.maxY - widthLocked.height
            panel.setFrame(widthLocked, display: false)

            lastFrame = frame
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = isExpanded ? 0.22 : 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                panel.animator().setFrame(frame, display: true)
            } completionHandler: { [weak self] in
                self?.trackingView?.refreshTrackingAreas()
                self?.evaluatePointer()
            }
        } else {
            lastFrame = frame
            panel.setFrame(frame, display: true)
            trackingView?.refreshTrackingAreas()
        }
    }

    private func collapsedHitFrame() -> CGRect {
        geometry.collapsedHoverFrame(wingExtension: collapsedWingExtension())
    }

    private func expandedHitFrame() -> CGRect {
        guard let panel else { return targetFrame(expanded: true) }
        return panel.frame.insetBy(dx: -6, dy: -8)
    }

    private func requestExpand(immediate: Bool) {
        guard Date() >= collapseCooldownUntil else { return }
        guard !service.players.isEmpty else { return }
        guard !isExpanded else { return }

        expandWorkItem?.cancel()
        if immediate {
            expandNow()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.expandNow()
        }
        expandWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
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
        // Enable clicks before frame settles so transport is interactive ASAP.
        updateMousePassthrough()
        reposition(animated: true)
    }

    private func notePointerMayHaveLeft() {
        if isExpanded {
            scheduleCollapse(delay: 0.12)
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
            scheduleCollapse(delay: 0.12)
            return
        }
        if Date().timeIntervalSince(pointerOutsideSince!) >= 0.1 {
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
        collapseCooldownUntil = Date().addingTimeInterval(0.14)
        lastLayoutSignature = layoutSignature(for: service.players)
        reposition(animated: animated)
    }

    private func startPointerTracking() {
        guard hoverPollTimer == nil else { return }

        hoverPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 25.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.evaluatePointer() }
        }
        if let hoverPollTimer {
            RunLoop.main.add(hoverPollTimer, forMode: .common)
        }

        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged]
            ) { [weak self] _ in
                DispatchQueue.main.async { self?.evaluatePointer() }
            }
        }
        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged]
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

        if collapsedHitFrame().contains(mouse) {
            if Date() < collapseCooldownUntil { return }
            if pointerInCollapsedSince == nil {
                pointerInCollapsedSince = Date()
            }
            if Date().timeIntervalSince(pointerInCollapsedSince!) >= 0.04 {
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

    /// Forward to SwiftUI hosting view so transport buttons receive clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point)
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
