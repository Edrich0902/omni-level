import AppKit
import CoreGraphics

/// Geometry of the built-in display’s camera housing / menu-bar notch.
struct NotchGeometry: Equatable, Sendable {
    /// Width of the physical notch (screen gap between menubar left/right areas).
    var width: CGFloat
    /// Height down from the top of the screen (typically `safeAreaInsets.top`).
    var height: CGFloat
    /// True when the primary screen reports a real cutout.
    var hasPhysicalNotch: Bool
    /// Screen frame used for anchoring (global coordinates).
    var screenFrame: CGRect

    static func detect(screen: NSScreen? = nil) -> NotchGeometry {
        let screen = screen
            ?? NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.main
        guard let screen else {
            return NotchGeometry(
                width: 180,
                height: 28,
                hasPhysicalNotch: false,
                screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
            )
        }

        let frame = screen.frame
        var width: CGFloat = 176
        var hasNotch = false

        // Prefer the system menu-bar band height so we never paint thicker than the bar.
        var height: CGFloat = 28
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            height = max(left.height, 24)
            let gap = frame.width - left.width - right.width
            if gap > 80 {
                // Slight under-estimate so black fill fully covers the cutout edge.
                width = max(gap - 2, 140)
                hasNotch = true
            }
        } else if screen.safeAreaInsets.top > 0 {
            // Cap hard — raw safeAreaInsets can overshoot the visible menubar chrome.
            height = min(max(screen.safeAreaInsets.top, 24), 32)
            hasNotch = screen.safeAreaInsets.top >= 24
        }

        return NotchGeometry(
            width: width,
            height: height,
            hasPhysicalNotch: hasNotch,
            screenFrame: frame
        )
    }

    /// Visual frame for the collapsed island — flush to the hardware notch, not taller.
    func collapsedFrame(wingExtension: CGFloat) -> CGRect {
        let w = max(width + wingExtension, width + 64)
        let h = height
        return CGRect(
            x: screenFrame.midX - w / 2,
            y: screenFrame.maxY - h,
            width: w,
            height: h
        )
    }

    /// Invisible hover pad: slightly wider/taller than the visual, does not change the panel.
    func collapsedHoverFrame(wingExtension: CGFloat) -> CGRect {
        collapsedFrame(wingExtension: wingExtension)
            .insetBy(dx: -16, dy: -8)
            .offsetBy(dx: 0, dy: -2)
    }

    func expandedFrame(size: CGSize) -> CGRect {
        CGRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }
}
