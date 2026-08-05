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
                height: 32,
                hasPhysicalNotch: false,
                screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
            )
        }

        let frame = screen.frame
        var width: CGFloat = 176
        var hasNotch = false

        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let gap = frame.width - left.width - right.width
            if gap > 80 {
                // Slight under-estimate so black fill fully covers the cutout edge.
                width = max(gap - 2, 140)
                hasNotch = true
            }
        }

        let topInset = screen.safeAreaInsets.top
        let height: CGFloat
        if topInset > 0 {
            // Use the true inset — no crushing / padding hacks.
            height = topInset
            hasNotch = hasNotch || topInset >= 24
        } else {
            height = 34
        }

        return NotchGeometry(
            width: width,
            height: height,
            hasPhysicalNotch: hasNotch,
            screenFrame: frame
        )
    }

    func collapsedFrame(wingExtension: CGFloat) -> CGRect {
        let w = max(width + wingExtension, width + 80)
        let h = height
        return CGRect(
            x: screenFrame.midX - w / 2,
            y: screenFrame.maxY - h,
            width: w,
            height: h
        )
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
