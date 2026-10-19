// Digitizer dispatch adapted from subdiox/SimKit (Apache 2.0).
// See Resources/Simulator-NOTICE and Resources/Simulator-LICENSE.
import AppKit
import BobCore

/// Input goes to one exact CoreSimulator device, without moving the Mac pointer
/// or activating a separate Simulator window. This is for direct user input only.
@MainActor final class SimulatorInput {
    enum Phase { case down, move, up }
    private typealias CreateDigitizer = @convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt32, UInt32, UInt32, Double, Double, Double, Double, Double, Bool, Bool, UInt32) -> Unmanaged<CFTypeRef>?
    private typealias CreateFinger = @convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt32, Double, Double, Double, Double, Double, Bool, Bool, UInt32) -> Unmanaged<CFTypeRef>?
    private typealias Append = @convention(c) (CFTypeRef, CFTypeRef, UInt32) -> Void
    private typealias Wrap = @convention(c) (UnsafeRawPointer) -> UnsafeMutableRawPointer?
    private typealias Arbitrary = @convention(c) (UInt32, UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?
    private typealias Button = @convention(c) (UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?
    private let client: NSObject
    private let createDigitizer: CreateDigitizer
    private let createFinger: CreateFinger
    private let append: Append
    private let wrap: Wrap
    private let arbitrary: Arbitrary
    private let button: Button
    private var identifier: UInt32 = 0
    private var touch: CGPoint?
    private var edge: UInt8 = 0
    private var pressedKeys: Set<UInt32> = []

    init(device: NSObject) throws {
        client = try SimulatorRuntime.makeClient(device)
        createDigitizer = try SimulatorRuntime.symbol("IOHIDEventCreateDigitizerEvent", as: CreateDigitizer.self)
        createFinger = try SimulatorRuntime.symbol("IOHIDEventCreateDigitizerFingerEvent", as: CreateFinger.self)
        append = try SimulatorRuntime.symbol("IOHIDEventAppendEvent", as: Append.self)
        wrap = try SimulatorRuntime.symbol("IndigoHIDMessageForTrackpadEventFromHIDEventRef", as: Wrap.self)
        arbitrary = try SimulatorRuntime.symbol("IndigoHIDMessageForHIDArbitrary", as: Arbitrary.self)
        button = try SimulatorRuntime.symbol("IndigoHIDMessageForButton", as: Button.self)
    }

    func sendTouch(_ point: CGPoint, phase: Phase) throws {
        guard point.x.isFinite, point.y.isFinite else { return }
        let point = CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
        if phase == .down {
            if let touch { try sendTouch(touch, phase: .up) }
            identifier &+= 1; if identifier == 0 { identifier = 1 }
            edge = point.y > 0.98 ? 0x01 : point.y < 0.02 ? 0x08 : point.x < 0.02 ? 0x02 : point.x > 0.98 ? 0x04 : 0
        } else if touch == nil { return }
        let active = phase != .up
        let mask: UInt32 = active ? 0x07 : 0x06
        let now = mach_absolute_time()
        guard let parent = createDigitizer(nil, now, 2, 0, identifier, mask, 0, point.x, point.y, 0, 0, 0, active, active, 0)?.takeRetainedValue(),
              let finger = createFinger(nil, now, 0, identifier, mask, point.x, point.y, 0, 0, 0, active, active, 0)?.takeRetainedValue() else { throw SimulatorRuntime.unavailable() }
        append(parent, finger, 0)
        let message = withExtendedLifetime(parent) { wrap(Unmanaged.passUnretained(parent as AnyObject).toOpaque()) }
        guard let message else { throw SimulatorRuntime.unavailable() }
        // Xcode 26's wrapper leaves the digitizer target and edge slots unset.
        // Validate the wire size before touching the two event records.
        guard malloc_size(message) == 0x180 else {
            let allocated = malloc_size(message)
            free(message); throw BobError.message("Unsupported simulator touch packet (\(allocated) bytes).")
        }
        for offset in [0x6c, 0x10c] { message.storeBytes(of: UInt32(0x32), toByteOffset: offset, as: UInt32.self) }
        for offset in [0x3a, 0xda] {
            message.storeBytes(of: UInt8(edge == 0 ? 0 : 0x04), toByteOffset: offset, as: UInt8.self)
            message.storeBytes(of: edge, toByteOffset: offset + 1, as: UInt8.self)
        }
        send(message)
        touch = active ? point : nil
    }

    func home() async {
        releaseAll()
        // Indigo's home button is target 0x33, button source 0.
        if let down = button(0, 1, 0x33) { send(down) }
        try? await Task.sleep(for: .milliseconds(60))
        if let up = button(0, 2, 0x33) { send(up) }
    }

    func key(_ usage: UInt32, down: Bool) {
        if down { pressedKeys.insert(usage) } else { pressedKeys.remove(usage) }
        if let message = arbitrary(0x32, 0x07, usage, down ? 1 : 2) { send(message) }
    }

    func modifiers(_ flags: NSEvent.ModifierFlags) {
        for (flag, usage): (NSEvent.ModifierFlags, UInt32) in [(.shift, 0xe1), (.control, 0xe0), (.option, 0xe2)] {
            let down = flags.contains(flag)
            if down != pressedKeys.contains(usage) { key(usage, down: down) }
        }
    }

    func releaseAll() {
        if let touch { try? sendTouch(touch, phase: .up) }
        for key in Array(pressedKeys) { self.key(key, down: false) }
    }

    private func send(_ message: UnsafeMutableRawPointer) {
        let selector = NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")
        typealias Send = @convention(c) (NSObject, Selector, UnsafeMutableRawPointer, ObjCBool, AnyObject?, AnyObject?) -> Void
        unsafeBitCast(client.method(for: selector), to: Send.self)(client, selector, message, true, nil, nil)
    }

    // macOS virtual keys → USB HID keyboard usages. Command shortcuts stay in Bob.
    static let keyUsages: [UInt16: UInt32] = [
        0:4, 1:22, 2:7, 3:9, 4:11, 5:10, 6:29, 7:27, 8:6, 9:25, 11:5,
        12:20, 13:26, 14:8, 15:21, 16:28, 17:23, 18:30, 19:31, 20:32, 21:33,
        22:35, 23:34, 24:46, 25:38, 26:36, 27:45, 28:37, 29:39, 30:48, 31:18,
        32:24, 33:47, 34:12, 35:19, 36:40, 37:15, 38:13, 39:52, 40:14, 41:51,
        42:49, 43:54, 44:56, 45:17, 46:16, 47:55, 48:43, 49:44, 50:53, 51:42,
        53:41, 76:88, 117:76, 123:80, 124:79, 125:81, 126:82
    ]
}
