import AppKit
import SwiftUI

/// Gives SwiftUI access to the hosting NSWindow.
struct WindowReader: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

/// Window behaviour: snaps to the device's shape, floats on top, hides its buttons over video.
@MainActor
final class WindowController: ObservableObject {
    weak var window: NSWindow?
    private var lastVideoSize: CGSize = .zero

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.isMovableByWindowBackground = true
        window.titlebarAppearsTransparent = true
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.minSize = NSSize(width: 360, height: 360)
        window.setFrameAutosaveName("EspelhoMain")
    }

    func setFloating(_ floating: Bool) {
        window?.level = floating ? .floating : .normal
    }

    func setTitlebarButtonsVisible(_ visible: Bool) {
        guard let window else { return }
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            for type in buttons {
                window.standardWindowButton(type)?.animator().alphaValue = visible ? 1 : 0
            }
        }
    }

    var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) == true }

    func toggleFullScreen() { window?.toggleFullScreen(nil) }

    /// Resizes the window to the video's aspect ratio, keeping its centre and,
    /// on rotation, the length of its longest side.
    func fit(to video: CGSize, force: Bool = false) {
        guard let window, video.width > 0, video.height > 0, !isFullScreen else { return }
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxSize = CGSize(width: screen.width * 0.9, height: screen.height * 0.9)
        let current = window.contentLayoutRect.size
        let previous = lastVideoSize
        lastVideoSize = video

        var target: CGSize
        if previous != .zero, !force {
            // Same device rotating or changing resolution: keep the window's scale.
            let previousLong = max(previous.width, previous.height)
            let currentLong = max(current.width, current.height)
            let scale = currentLong / previousLong
            target = CGSize(width: video.width * scale, height: video.height * scale)
        } else {
            // New session: as large as comfortable.
            let scale = min(maxSize.width / video.width, maxSize.height / video.height,
                            (video.height > video.width ? 0.86 : 0.8) * screen.height / video.height)
            target = CGSize(width: video.width * scale, height: video.height * scale)
        }
        let clamp = min(1, maxSize.width / target.width, maxSize.height / target.height)
        target = CGSize(width: (target.width * clamp).rounded(), height: (target.height * clamp).rounded())

        window.contentAspectRatio = video
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: target))
        let centre = CGPoint(x: window.frame.midX, y: window.frame.midY)
        frame.origin = CGPoint(x: centre.x - frame.width / 2, y: centre.y - frame.height / 2)
        frame.origin.x = min(max(frame.origin.x, screen.minX), screen.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, screen.minY), screen.maxY - frame.height)
        window.setFrame(frame, display: true, animate: true)
    }

    /// Back to the welcome layout.
    func restoreWelcomeSize() {
        lastVideoSize = .zero
        guard let window, !isFullScreen else { return }
        window.contentResizeIncrements = NSSize(width: 1, height: 1)
        let size = WindowMetrics.welcome
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = CGPoint(x: window.frame.midX - frame.width / 2, y: window.frame.midY - frame.height / 2)
        if let screen = (window.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, screen.minX), screen.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, screen.minY), screen.maxY - frame.height)
        }
        window.setFrame(frame, display: true, animate: true)
    }
}
