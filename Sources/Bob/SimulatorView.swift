import AppKit
import SwiftUI
import IOSurface

struct SimulatorView: View {
    @ObservedObject var session: SimulatorSession
    let visible: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Device", selection: Binding(get: { session.selectedID }, set: { session.select($0) })) {
                    if session.devices.isEmpty { Text("No iOS simulators").tag("") }
                    ForEach(session.devices) { device in Text(device.label).tag(device.id) }
                }.labelsHidden().disabled(session.busy).accessibilityLabel("Simulator Device")
                Button { session.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh Devices").accessibilityLabel("Refresh Devices").disabled(session.busy)
                if session.connectedID == nil {
                    Button("Start") { session.connect() }.disabled(session.selected == nil || session.busy)
                } else {
                    Button { session.display?.home() } label: { Image(systemName: "house") }
                        .help("Home").accessibilityLabel("Simulator Home").disabled(session.busy)
                    Menu {
                        Button("Install App…") { session.chooseApp() }
                        Button("Disconnect") { session.disconnect() }
                        Button("Shut Down Device") { session.shutdownDevice() }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("Simulator Actions").accessibilityLabel("Simulator Actions").disabled(session.busy)
                }
            }.font(.system(size: 11)).controlSize(.small).padding(12).background(Theme.panel)
            Theme.line.frame(height: 1)
            if session.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(session.activity).lineLimit(1)
                    Spacer()
                    Button("Cancel") { session.cancel() }
                }.font(.system(size: 11)).padding(12)
            }
            if let error = session.error {
                Text(error).font(.system(size: 11)).foregroundStyle(Theme.warning).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            if session.connectedID != nil {
                SimulatorSurface(session: session, visible: visible).padding(16)
            } else {
                EmptyPanel(title: session.devices.isEmpty ? "Add an iOS simulator in Xcode → Window → Devices and Simulators" : "Choose a device and start the simulator")
            }
        }
        .onAppear { session.refresh() }
    }
}

private struct SimulatorSurface: NSViewRepresentable {
    @ObservedObject var session: SimulatorSession
    let visible: Bool
    func makeNSView(context: Context) -> SimulatorScreenView {
        let view = SimulatorScreenView()
        session.display = view
        return view
    }
    func updateNSView(_ view: SimulatorScreenView, context: Context) {
        guard visible, let id = session.connectedID else { view.detach(); return }
        view.attach(id: id, developerDirectory: session.developerDirectory) { [weak session] error in
            // SwiftUI is updating the representable; publish failures on the next turn.
            DispatchQueue.main.async {
                guard session?.connectedID == id else { return }
                session?.disconnect(); session?.error = error.localizedDescription
            }
        }
    }
    static func dismantleNSView(_ view: SimulatorScreenView, coordinator: ()) { view.detach() }
}

/// Native IOSurface-backed layer; there is no separate Simulator window and no
/// screenshot polling. Only the fitted device rectangle receives pointer input.
@MainActor final class SimulatorScreenView: NSView {
    private let screen = CALayer()
    private let framebuffer = SimulatorFramebuffer()
    private var deviceID: String?
    private var pixelSize = CGSize.zero
    private var onError: ((Error) -> Void)?
    private var gesturePoint: CGPoint?
    private var homeTask: Task<Void, Never>?
    private var focusObservation: NSObjectProtocol?
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        screen.contentsGravity = .resizeAspect
        screen.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(screen)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("iOS Simulator display")
        setAccessibilityHelp("Click to tap, drag to swipe, and type to use the selected simulator. Command shortcuts control Bob.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let focusObservation { NotificationCenter.default.removeObserver(focusObservation) } }

    func attach(id: String, developerDirectory: String, onError: @escaping (Error) -> Void) {
        guard id != deviceID else { return }
        detach(); self.onError = onError
        do {
            try framebuffer.start(id: id, developerDirectory: developerDirectory) { [weak self] surface in
                guard let self else { return }
                CATransaction.begin(); CATransaction.setDisableActions(true)
                self.pixelSize = CGSize(width: surface.width, height: surface.height)
                self.screen.contents = surface
                self.needsLayout = true
                CATransaction.commit()
            }
            deviceID = id
        } catch { onError(error) }
    }

    func detach() {
        homeTask?.cancel(); homeTask = nil
        framebuffer.stop(); deviceID = nil; gesturePoint = nil
        screen.contents = nil; onError = nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        screen.frame = Self.displayRect(in: bounds, pixels: pixelSize)
        CATransaction.commit()
    }

    static func displayRect(in bounds: CGRect, pixels: CGSize) -> CGRect {
        guard pixels.width > 0, pixels.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / pixels.width, bounds.height / pixels.height)
        let size = CGSize(width: pixels.width * scale, height: pixels.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    static func normalizedPoint(_ point: CGPoint, in rect: CGRect, clamp: Bool = false) -> CGPoint? {
        guard rect.width > 0, rect.height > 0, clamp || rect.contains(point) else { return nil }
        return CGPoint(x: min(1, max(0, (point.x - rect.minX) / rect.width)), y: min(1, max(0, (point.y - rect.minY) / rect.height)))
    }

    private func send(_ event: NSEvent, phase: SimulatorInput.Phase) {
        let point = convert(event.locationInWindow, from: nil)
        guard let normalized = Self.normalizedPoint(point, in: screen.frame, clamp: phase != .down) else { return }
        do {
            try framebuffer.input?.sendTouch(normalized, phase: phase)
            gesturePoint = phase == .up ? nil : normalized
        } catch { framebuffer.input?.releaseAll(); gesturePoint = nil; onError?(error) }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); send(event, phase: .down) }
    override func mouseDragged(with event: NSEvent) { if gesturePoint != nil { send(event, phase: .move) } }
    override func mouseUp(with event: NSEvent) { if gesturePoint != nil { send(event, phase: .up) } }
    override func keyDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.command), let usage = SimulatorInput.keyUsages[event.keyCode] else { super.keyDown(with: event); return }
        framebuffer.input?.modifiers(event.modifierFlags)
        framebuffer.input?.key(usage, down: true)
    }
    override func keyUp(with event: NSEvent) {
        if let usage = SimulatorInput.keyUsages[event.keyCode] { framebuffer.input?.key(usage, down: false) }
    }
    override func flagsChanged(with event: NSEvent) { framebuffer.input?.modifiers(event.modifierFlags) }
    override func resignFirstResponder() -> Bool { framebuffer.input?.releaseAll(); gesturePoint = nil; return true }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let focusObservation { NotificationCenter.default.removeObserver(focusObservation); self.focusObservation = nil }
        if newWindow == nil { framebuffer.input?.releaseAll(); gesturePoint = nil }
        super.viewWillMove(toWindow: newWindow)
        if let newWindow {
            focusObservation = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: newWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.framebuffer.input?.releaseAll(); self?.gesturePoint = nil }
            }
        }
    }
    func home() {
        homeTask?.cancel()
        homeTask = Task { [weak self] in await self?.framebuffer.input?.home() }
    }
}
