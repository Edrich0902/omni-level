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
    private var cancellables = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?
    private var lastLayoutSignature = ""
    private var lastFrame: CGRect = .zero
    private let viewModel: NotchNowPlayingViewModel

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
        collapseWorkItem?.cancel()
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

        let tracking = NotchTrackingView(frame: NSRect(origin: .zero, size: frame.size))
        tracking.autoresizingMask = [.width, .height]
        tracking.wantsLayer = true
        tracking.layer?.backgroundColor = NSColor.clear.cgColor
        tracking.onMouseEntered = { [weak self] in self?.expand() }
        tracking.onMouseExited = { [weak self] in self?.scheduleCollapse() }

        let root = NotchNowPlayingRootView(viewModel: viewModel)
        let host = NSHostingView(rootView: root)
        host.frame = tracking.bounds
        host.autoresizingMask = [.width, .height]
        // Transparent outside the pure-black island shape (no gray panel rectangle).
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
            Task { @MainActor in
                self?.geometry = NotchGeometry.detect()
                self?.viewModel.geometry = self?.geometry ?? NotchGeometry.detect()
                self?.lastLayoutSignature = ""
                self?.reposition(animated: false)
            }
        }
    }

    /// Identity that affects panel size / wing width — not track title/position.
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
                return true
            }
        } else {
            if isExpanded {
                isExpanded = false
                viewModel.isExpanded = false
            }
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
        // Notch band + each player (art row + optional seek) + spacing + bottom pad
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
        // Extra room for wing art outside the camera width.
        service.players.count > 1 ? 108 : 96
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
        // Skip no-op frame dances (animation was firing every poll).
        if abs(frame.minX - lastFrame.minX) < 0.5,
           abs(frame.minY - lastFrame.minY) < 0.5,
           abs(frame.width - lastFrame.width) < 0.5,
           abs(frame.height - lastFrame.height) < 0.5 {
            return
        }
        lastFrame = frame
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = isExpanded ? 0.36 : 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    // MARK: - Expand / collapse

    private func expand() {
        collapseWorkItem?.cancel()
        guard !service.players.isEmpty else { return }
        guard !isExpanded else {
            lastLayoutSignature = layoutSignature(for: service.players)
            reposition(animated: true)
            return
        }
        isExpanded = true
        viewModel.isExpanded = true
        lastLayoutSignature = layoutSignature(for: service.players)
        reposition(animated: true)
        panel?.makeKey()
    }

    private func scheduleCollapse() {
        collapseWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.collapseIfMouseOutside()
        }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: work)
    }

    private func collapseIfMouseOutside() {
        guard isExpanded, let panel else { return }
        let padded = panel.frame.insetBy(dx: -22, dy: -22)
        if padded.contains(NSEvent.mouseLocation) {
            return
        }
        isExpanded = false
        viewModel.isExpanded = false
        lastLayoutSignature = layoutSignature(for: service.players)
        lastFrame = .zero // force frame update after collapse
        reposition(animated: true)
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
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            )
        )
    }

    override func mouseEntered(with event: NSEvent) { onMouseEntered?() }
    override func mouseExited(with event: NSEvent) { onMouseExited?() }

    override var isFlipped: Bool { true }
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
