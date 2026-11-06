import AppKit
import AVFoundation
import EspelhoEngine
import SwiftUI

/// The mirrored screen, edge to edge, with controls that appear on hover.
struct MirrorView: View {
    @EnvironmentObject private var service: MirrorService
    @ObservedObject var windowController: WindowController
    @AppStorage(Prefs.keepOnTop) private var keepOnTop = false

    @State private var controlsVisible = true
    @State private var hideTask: DispatchWorkItem?
    @State private var hoveringControls = false

    var body: some View {
        ZStack {
            Color.black
            VideoSurface(layer: service.renderer.displayLayer,
                         input: service.source == .android ? AndroidInput(service: service) : nil)
        }
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            if controlsVisible { infoBar.transition(.move(edge: .top).combined(with: .opacity)) }
        }
        .overlay(alignment: .bottom) {
            if controlsVisible { controls.transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active: revealControls()
            case .ended: scheduleHide(after: 0.6)
            }
        }
        .onAppear { revealControls(for: 3) }
        .onDisappear { hideTask?.cancel() }
    }

    // MARK: Bars

    private var infoBar: some View {
        HStack(spacing: 10) {
            Image(systemName: service.deviceSymbol)
                .font(.system(size: 13, weight: .semibold))
            Text(service.deviceName ?? service.fallbackDeviceName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            if service.videoSize != .zero {
                Text(verbatim: "\(Int(service.videoSize.width))×\(Int(service.videoSize.height))" + (service.fps > 0 ? " · \(service.fps) qps" : ""))
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.smooth, value: service.fps)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .padding(.top, windowController.isFullScreen ? 14 : 34)
        .allowsHitTesting(false)
    }

    private var controls: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                if service.source == .android {
                    ControlButton(symbol: "arrowshape.backward", help: "Voltar (esc ou clique direito)") {
                        service.sendToAndroid(ScrcpyControl.keyPress(ScrcpyControl.Key.back))
                    }
                    ControlButton(symbol: "circle", help: "Início") {
                        service.sendToAndroid(ScrcpyControl.keyPress(ScrcpyControl.Key.home))
                    }
                    ControlButton(symbol: "square.on.square", help: "Apps recentes") {
                        service.sendToAndroid(ScrcpyControl.keyPress(ScrcpyControl.Key.appSwitch))
                    }
                    Divider().frame(height: 26).padding(.horizontal, 2)
                }
                DeviceSwitchButton()
                ControlButton(symbol: "camera", help: "Capturar tela (⌘S)") {
                    service.captureScreenshot()
                }
                ControlButton(symbol: "doc.on.doc", help: "Copiar tela (⇧⌘C)") {
                    service.captureScreenshot(copyOnly: true)
                }
                ControlButton(symbol: keepOnTop ? "pin.fill" : "pin",
                              help: keepOnTop ? "Deixar de manter no topo" : "Manter acima das outras janelas",
                              highlighted: keepOnTop) {
                    keepOnTop.toggle()
                }
                ControlButton(symbol: windowController.isFullScreen
                              ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                              help: "Tela cheia (⌃⌘F)") {
                    windowController.toggleFullScreen()
                }
                ControlButton(symbol: "xmark", help: "Desconectar aparelho (⌘D)", destructive: true) {
                    service.disconnect()
                }
            }
        }
        .padding(.bottom, 18)
        .onHover { hoveringControls = $0 }
    }

    // MARK: Auto-hide

    private func revealControls(for seconds: Double = 2.2) {
        if !controlsVisible {
            withAnimation(.spring(duration: 0.35, bounce: 0.2)) { controlsVisible = true }
            windowController.setTitlebarButtonsVisible(true)
        }
        scheduleHide(after: seconds)
    }

    private func scheduleHide(after seconds: Double) {
        hideTask?.cancel()
        let task = DispatchWorkItem {
            guard !hoveringControls else { return }
            withAnimation(.smooth(duration: 0.4)) { controlsVisible = false }
            windowController.setTitlebarButtonsVisible(false)
            if windowController.isFullScreen { NSCursor.setHiddenUntilMouseMoves(true) }
        }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: task)
    }
}

struct ControlButton: View {
    var symbol: String
    var help: String
    var highlighted = false
    var destructive = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 40, height: 40)
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(destructive ? AnyShapeStyle(.red) : highlighted ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help(help)
    }
}

/// Hosts the hardware-decoded video layer.
struct VideoSurface: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    var input: AndroidInput?

    func makeNSView(context: Context) -> VideoHostView {
        let view = VideoHostView()
        view.attach(layer)
        view.input = input
        return view
    }

    func updateNSView(_ nsView: VideoHostView, context: Context) {
        nsView.input = input
    }

    static func dismantleNSView(_ nsView: VideoHostView, coordinator: ()) {
        nsView.detach()
    }
}

final class VideoHostView: NSView {
    private weak var videoLayer: AVSampleBufferDisplayLayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func attach(_ video: AVSampleBufferDisplayLayer) {
        video.removeFromSuperlayer()
        layer?.addSublayer(video)
        videoLayer = video
        needsLayout = true
    }

    func detach() {
        if videoLayer?.superlayer === layer { videoLayer?.removeFromSuperlayer() }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true) // follow live resizing without lag
        videoLayer?.frame = bounds
        CATransaction.commit()
    }

    /// Set while an Android is on screen: mouse and keyboard control it.
    var input: AndroidInput? {
        didSet {
            if input != nil, window?.firstResponder !== self { window?.makeFirstResponder(self) }
        }
    }
    private var touching = false

    override var acceptsFirstResponder: Bool { input != nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { input != nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if input != nil { window?.makeFirstResponder(self) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let input else {
            if event.clickCount == 2 {
                window?.toggleFullScreen(nil)
            } else {
                window?.performDrag(with: event)
            }
            return
        }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        // The strip under the traffic lights still moves the window.
        if window?.styleMask.contains(.fullScreen) == false, point.y > bounds.height - 28 {
            window?.performDrag(with: event)
            return
        }
        touching = input.touch(.down, at: point, in: bounds)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let input, touching else { return }
        input.touch(.move, at: convert(event.locationInWindow, from: nil), in: bounds, clamp: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard let input, touching else { return }
        touching = false
        input.touch(.up, at: convert(event.locationInWindow, from: nil), in: bounds, clamp: true)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let input else { return super.rightMouseDown(with: event) }
        input.send(ScrcpyControl.backOrScreenOn())
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let input else { return super.otherMouseDown(with: event) }
        input.send(ScrcpyControl.keyPress(ScrcpyControl.Key.home))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let input else { return super.scrollWheel(with: event) }
        input.scroll(event, at: convert(event.locationInWindow, from: nil), in: bounds)
    }

    override func keyDown(with event: NSEvent) {
        guard let input, input.key(event) else { return super.keyDown(with: event) }
    }

    /// ⌘V: pastes the Mac's clipboard into the Android.
    @objc func paste(_ sender: Any?) {
        guard let input, let text = NSPasteboard.general.string(forType: .string) else { return }
        input.send(ScrcpyControl.setClipboard(text, paste: true))
    }
}

/// Translates the Mac's mouse and keyboard into Android touches and keys.
@MainActor
struct AndroidInput {
    let service: MirrorService

    func send(_ message: Data) { service.sendToAndroid(message) }

    /// Returns false when the click is outside the picture.
    @discardableResult
    func touch(_ action: ScrcpyControl.TouchAction, at point: CGPoint, in bounds: CGRect, clamp: Bool = false) -> Bool {
        guard let (x, y, size) = map(point, in: bounds, clamp: clamp) else { return false }
        send(ScrcpyControl.touch(action, x: x, y: y, width: Int(size.width), height: Int(size.height)))
        return true
    }

    func scroll(_ event: NSEvent, at point: CGPoint, in bounds: CGRect) {
        guard let (x, y, size) = map(point, in: bounds, clamp: true) else { return }
        // Trackpads send many small, precise deltas; mouse wheels send whole lines.
        let scale = event.hasPreciseScrollingDeltas ? 0.08 : 1.0
        let h = -event.scrollingDeltaX * scale, v = event.scrollingDeltaY * scale
        guard abs(h) > 0.01 || abs(v) > 0.01 else { return }
        send(ScrcpyControl.scroll(x: x, y: y, width: Int(size.width), height: Int(size.height), h: h, v: v))
    }

    /// Returns true when the key was sent to the Android.
    func key(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if mods.contains(.command) { return false } // menu shortcuts stay on the Mac
        let keys: [UInt16: UInt32] = [
            36: ScrcpyControl.Key.enter, 76: ScrcpyControl.Key.enter, 51: ScrcpyControl.Key.delete,
            117: ScrcpyControl.Key.forwardDelete, 48: ScrcpyControl.Key.tab, 53: ScrcpyControl.Key.back,
            123: ScrcpyControl.Key.left, 124: ScrcpyControl.Key.right, 125: ScrcpyControl.Key.down,
            126: ScrcpyControl.Key.up, 115: ScrcpyControl.Key.moveHome, 119: ScrcpyControl.Key.moveEnd,
            116: ScrcpyControl.Key.pageUp, 121: ScrcpyControl.Key.pageDown,
        ]
        if let code = keys[event.keyCode] {
            send(ScrcpyControl.keyPress(code))
            return true
        }
        guard !mods.contains(.control), let text = event.characters, !text.isEmpty,
              !text.unicodeScalars.contains(where: { $0.value < 0x20 || (0xF700...0xF8FF).contains($0.value) }) else {
            return false
        }
        send(ScrcpyControl.text(text))
        return true
    }

    /// View point -> Android pixel, through the aspect-fit picture.
    private func map(_ point: CGPoint, in bounds: CGRect, clamp: Bool) -> (Int, Int, CGSize)? {
        let size = service.androidScreenSize
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        let rect = CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
        var nx = (point.x - rect.minX) / rect.width
        var ny = (rect.maxY - point.y) / rect.height // AppKit's y goes up
        if clamp {
            nx = min(max(nx, 0), 1)
            ny = min(max(ny, 0), 1)
        } else if !(0...1).contains(nx) || !(0...1).contains(ny) {
            return nil
        }
        let x = min(Int(nx * size.width), Int(size.width) - 1)
        let y = min(Int(ny * size.height), Int(size.height) - 1)
        return (x, y, size)
    }
}
