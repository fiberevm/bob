// Runtime and framebuffer bridge adapted from subdiox/SimKit and tddworks/baguette.
// See Resources/Simulator-NOTICE and Resources/Simulator-LICENSE.
import AppKit
import IOSurface
import ObjectiveC
import BobCore

/// Xcode's private frameworks are loaded only when a device is connected.
/// Keep every private selector behind a check so incompatible installs fail in the tab.
@MainActor enum SimulatorRuntime {
    private static var loadedDirectory: String?

    static func device(_ id: String, developerDirectory: String) throws -> NSObject {
        if let loadedDirectory, loadedDirectory != developerDirectory {
            throw BobError.message("Xcode changed. Restart Bob to reconnect the simulator.")
        }
        if loadedDirectory == nil {
            let infoURL = URL(fileURLWithPath: developerDirectory).deletingLastPathComponent().appendingPathComponent("Info.plist")
            let infoData = try Data(contentsOf: infoURL)
            let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any]
            let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
            guard version.split(separator: ".").first == "26" else {
                throw BobError.message("The embedded simulator currently supports Xcode 26. This installation reports Xcode \(version).")
            }
            for path in ["/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",
                         developerDirectory + "/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"] {
                guard dlopen(path, RTLD_NOW | RTLD_GLOBAL) != nil else {
                    throw BobError.message("Could not load Xcode’s simulator framework. \(dlerror().map { String(cString: $0) } ?? "")")
                }
            }
            loadedDirectory = developerDirectory
        }
        guard let cls = NSClassFromString("SimServiceContext"),
              let method = class_getClassMethod(cls, NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")) else {
            throw unavailable()
        }
        typealias Context = @convention(c) (AnyClass, Selector, NSString, AutoreleasingUnsafeMutablePointer<NSError?>) -> NSObject?
        let selector = method_getName(method)
        var error: NSError?
        guard let context = unsafeBitCast(method_getImplementation(method), to: Context.self)(cls, selector, developerDirectory as NSString, &error) else {
            throw error ?? unavailable()
        }
        let setSelector = NSSelectorFromString("defaultDeviceSetWithError:")
        guard context.responds(to: setSelector), let implementation = context.method(for: setSelector) else { throw unavailable() }
        typealias DeviceSet = @convention(c) (NSObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>) -> NSObject?
        guard let set = unsafeBitCast(implementation, to: DeviceSet.self)(context, setSelector, &error),
              let devices = object(set, "availableDevices") as? [NSObject],
              let device = devices.first(where: { (object($0, "UDID") as? NSUUID)?.uuidString.caseInsensitiveCompare(id) == .orderedSame }) else {
            throw error ?? BobError.message("The simulator is unavailable. Refresh the device list and try again.")
        }
        return device
    }

    static func object(_ target: NSObject, _ name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard target.responds(to: selector) else { return nil }
        return target.perform(selector)?.takeUnretainedValue()
    }

    static func makeClient(_ device: NSObject) throws -> NSObject {
        guard let cls = NSClassFromString("SimulatorKit.SimDeviceLegacyHIDClient"),
              let alloc = class_getClassMethod(cls, NSSelectorFromString("alloc")),
              let initializer = class_getInstanceMethod(cls, NSSelectorFromString("initWithDevice:error:")) else { throw unavailable() }
        typealias Allocate = @convention(c) (AnyClass, Selector) -> Unmanaged<NSObject>?
        typealias Initialize = @convention(c) (NSObject, Selector, NSObject, AutoreleasingUnsafeMutablePointer<NSError?>) -> Unmanaged<NSObject>?
        guard let allocated = unsafeBitCast(method_getImplementation(alloc), to: Allocate.self)(cls, method_getName(alloc)) else { throw unavailable() }
        var error: NSError?
        guard let client = unsafeBitCast(method_getImplementation(initializer), to: Initialize.self)(allocated.takeUnretainedValue(), method_getName(initializer), device, &error)?.takeRetainedValue() else {
            throw error ?? unavailable()
        }
        guard client.responds(to: NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")) else { throw unavailable() }
        return client
    }

    static func symbol<T>(_ name: String, as type: T.Type) throws -> T {
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { throw unavailable() }
        return unsafeBitCast(pointer, to: type)
    }

    static func unavailable() -> BobError {
        .message("This Xcode version’s simulator interface is incompatible with Bob. Use the Simulator app to continue.")
    }
}

@MainActor final class SimulatorFramebuffer {
    private var io: NSObject?
    private var registrations: [(NSObject, NSUUID)] = []
    private var onFrame: ((IOSurface) -> Void)?
    private(set) var input: SimulatorInput?

    func start(id: String, developerDirectory: String, onFrame: @escaping (IOSurface) -> Void) throws {
        stop()
        let device = try SimulatorRuntime.device(id, developerDirectory: developerDirectory)
        guard let io = SimulatorRuntime.object(device, "io") as? NSObject else { throw SimulatorRuntime.unavailable() }
        self.io = io; self.onFrame = onFrame
        do {
            input = try SimulatorInput(device: device)
            let update = NSSelectorFromString("updateIOPorts")
            if io.responds(to: update) { io.perform(update) }
            guard let ports = SimulatorRuntime.object(io, "deviceIOPorts") as? [NSObject] else { throw SimulatorRuntime.unavailable() }
            for port in ports {
                guard SimulatorRuntime.object(port, "portIdentifier") as? String == "com.apple.framebuffer.display",
                      let descriptor = SimulatorRuntime.object(port, "descriptor") as? NSObject,
                      descriptor.responds(to: NSSelectorFromString("framebufferSurface")),
                      descriptor.responds(to: NSSelectorFromString("unregisterScreenCallbacksWithUUID:")) else { continue }
                try register(descriptor)
            }
            guard !registrations.isEmpty else { throw BobError.message("The simulator display is not ready. Reconnect after the device finishes booting.") }
            capture()
        } catch { stop(); throw error }
    }

    private func register(_ descriptor: NSObject) throws {
        let selector = NSSelectorFromString("registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:")
        guard descriptor.responds(to: selector), let implementation = descriptor.method(for: selector) else { throw SimulatorRuntime.unavailable() }
        let uuid = NSUUID()
        let frame: @convention(block) () -> Void = { [weak self] in
            MainActor.assumeIsolated { self?.capture() }
        }
        let properties: @convention(block) () -> Void = {}
        typealias Register = @convention(c) (NSObject, Selector, NSUUID, AnyObject, AnyObject, AnyObject, AnyObject) -> Void
        registrations.append((descriptor, uuid))
        unsafeBitCast(implementation, to: Register.self)(descriptor, selector, uuid, DispatchQueue.main, frame as AnyObject, frame as AnyObject, properties as AnyObject)
    }

    private func capture() {
        // Main display planes share dimensions; use the full framebuffer rather than an overlay.
        var best: IOSurface?
        for (descriptor, _) in registrations {
            guard let object = SimulatorRuntime.object(descriptor, "framebufferSurface"),
                  CFGetTypeID(object) == IOSurfaceGetTypeID() else { continue }
            let surface = unsafeDowncast(object, to: IOSurface.self)
            if best == nil || surface.width * surface.height > best!.width * best!.height { best = surface }
        }
        if let best { onFrame?(best) }
    }

    func stop() {
        onFrame = nil
        input?.releaseAll(); input = nil
        for (descriptor, uuid) in registrations {
            descriptor.perform(NSSelectorFromString("unregisterScreenCallbacksWithUUID:"), with: uuid)
        }
        registrations.removeAll(); io = nil
    }
}
