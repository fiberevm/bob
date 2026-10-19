import AppKit
import QuartzCore
import SwiftUI
import BobCore

struct MessageFlightOverlay: NSViewRepresentable {
    let message: Message
    let source: CGRect
    let destination: CGRect?
    var started: ((UUID) -> Void)? = nil
    let completion: (UUID) -> Void

    func makeNSView(context: Context) -> MessageFlightView { MessageFlightView() }
    func updateNSView(_ view: MessageFlightView, context: Context) {
        view.prepare(message: message, source: source, destination: destination, started: started, completion: completion)
    }
    static func dismantleNSView(_ view: MessageFlightView, coordinator: ()) { view.cancel() }
}

/// An explicit compositor animation cannot be coalesced with the transcript's
/// first layout. The real bubble stays hidden until this spring finishes.
@MainActor final class MessageFlightView: NSView, CAAnimationDelegate {
    private var message: Message?
    private var source = CGRect.zero
    private var destination: CGRect?
    private var animatedDestination: CGRect?
    private var animationID: String?
    private var deadline: CFTimeInterval = 0
    private var completion: ((UUID) -> Void)?
    private var started: ((UUID) -> Void)?
    private(set) var bubbleLayer: CALayer?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(false)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func prepare(message: Message, source: CGRect, destination: CGRect?, started: ((UUID) -> Void)? = nil, completion: @escaping (UUID) -> Void) {
        if self.message?.id != message.id { cancel() }
        self.message = message
        self.source = source
        self.destination = destination
        self.completion = completion
        self.started = started
        needsLayout = true
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsLayout = true }
    override func layout() {
        super.layout()
        guard window != nil, !bounds.isEmpty, let message, !source.isEmpty,
              let destination, !destination.isEmpty, animatedDestination != destination else { return }

        let from: CGPoint
        let bubble: CALayer
        if let bubbleLayer {
            bubble = bubbleLayer
            from = bubble.presentation()?.position ?? bubble.position
            if animatedDestination?.size != destination.size {
                bubble.contents = image(for: message, size: destination.size)
            }
        } else {
            // SwiftUI manages its hosting layers during layout. Animate a native
            // snapshot on our own layer so that layout cannot remove the spring.
            bubble = CALayer()
            bubble.contents = image(for: message, size: destination.size)
            bubble.contentsScale = window?.backingScaleFactor ?? 2
            layer?.addSublayer(bubble)
            bubbleLayer = bubble
            from = CGPoint(x: source.minX + destination.width / 2, y: source.midY)
            deadline = CACurrentMediaTime() + 0.55
            Task { @MainActor [weak self] in
                guard let self, self.message?.id == message.id else { return }
                self.started?(message.id)
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bubble.bounds = CGRect(origin: .zero, size: destination.size)
        bubble.position = CGPoint(x: destination.midX, y: destination.midY)
        CATransaction.commit()
        animatedDestination = destination
        let spring = CASpringAnimation(keyPath: "position")
        spring.fromValue = NSValue(point: from)
        spring.toValue = NSValue(point: bubble.position)
        spring.mass = 1
        spring.stiffness = 260
        spring.damping = 30
        spring.duration = max(0.08, deadline - CACurrentMediaTime())
        let animationID = UUID().uuidString
        self.animationID = animationID
        spring.setValue(animationID, forKey: "flightAnimationID")
        spring.delegate = self
        bubble.add(spring, forKey: "send")
    }
    nonisolated func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        guard flag, let id = anim.value(forKey: "flightAnimationID") as? String else { return }
        Task { @MainActor [weak self] in
            guard let self, self.animationID == id else { return }
            self.finish()
        }
    }
    func cancel() {
        message = nil
        completion = nil
        started = nil
        animatedDestination = nil
        animationID = nil
        bubbleLayer?.removeAllAnimations()
        bubbleLayer?.removeFromSuperlayer()
        bubbleLayer = nil
    }
    private func image(for message: Message, size: CGSize) -> CGImage? {
        let host = NSHostingView(rootView: UserBubble(text: message.text))
        host.frame = CGRect(origin: .zero, size: size)
        addSubview(host)
        defer { host.removeFromSuperview() }
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap.cgImage
    }
    private func finish() {
        guard let id = message?.id else { return }
        let callback = completion
        cancel()
        callback?(id)
    }
}
