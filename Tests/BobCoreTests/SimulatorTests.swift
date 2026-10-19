import AppKit
import CoreImage
import IOSurface
import XCTest
@testable import Bob
@testable import BobCore

private let simulatorID = "00000000-0000-0000-0000-000000000001"
private let simulatorListing = #"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-5":[{"udid":"00000000-0000-0000-0000-000000000001","name":"iPhone 17","state":"Shutdown","isAvailable":true}]}}"#

private actor SimulatorCommands {
    private(set) var calls: [[String]] = []
    var booted = false
    var pauseBoot = false
    var bootStarted = false
    func setPauseBoot() { pauseBoot = true }
    func run(_ executable: String, _ arguments: [String], _ timeout: TimeInterval) async throws -> String {
        calls.append([executable] + arguments)
        if executable == "/usr/bin/xcode-select" { return "/Applications/Xcode.app/Contents/Developer" }
        if arguments == ["simctl", "list", "devices", "available", "--json"] {
            return booted ? simulatorListing.replacingOccurrences(of: "Shutdown", with: "Booted") : simulatorListing
        }
        if arguments.starts(with: ["simctl", "boot"]) { booted = true }
        if arguments.starts(with: ["simctl", "bootstatus"]) {
            bootStarted = true
            if pauseBoot { try await Task.sleep(for: .seconds(30)) }
        }
        if arguments.starts(with: ["simctl", "shutdown"]) { booted = false }
        return ""
    }
}

@MainActor final class SimulatorTests: XCTestCase {
    private func waitUntilIdle(_ session: SimulatorSession) async throws {
        for _ in 0..<200 where session.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(session.busy)
    }

    func testDeviceListFiltersUnavailableAndOtherPlatformsAndSortsVersionsNumerically() throws {
        let json = #"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-9":[{"udid":"00000000-0000-0000-0000-000000000001","name":"iPhone A","state":"Shutdown","isAvailable":true}],"com.apple.CoreSimulator.SimRuntime.iOS-26-10":[{"udid":"00000000-0000-0000-0000-000000000002","name":"iPhone B","state":"Shutdown","isAvailable":true},{"udid":"00000000-0000-0000-0000-000000000003","name":"iPad","state":"Booted","isAvailable":true},{"udid":"00000000-0000-0000-0000-000000000004","name":"Unavailable","state":"Shutdown","isAvailable":false},{"udid":"invalid","name":"Invalid","state":"Shutdown","isAvailable":true}],"com.apple.CoreSimulator.SimRuntime.tvOS-26-5":[{"udid":"00000000-0000-0000-0000-000000000005","name":"Apple TV","state":"Booted","isAvailable":true}]}}"#
        let devices = try SimulatorDevice.decode(Data(json.utf8))
        XCTAssertEqual(devices.map(\.name), ["iPad", "iPhone B", "iPhone A"])
        XCTAssertEqual(devices[0].runtime, "iOS 26.10")
    }

    func testRefreshDoesNotBootAndConnectTargetsOnlyTheChosenDevice() async throws {
        let commands = SimulatorCommands()
        let session = SimulatorSession(command: { try await commands.run($0, $1, $2) })
        session.refresh(); try await waitUntilIdle(session)
        XCTAssertNil(session.error)
        XCTAssertEqual(session.selectedID, simulatorID)
        var calls = await commands.calls
        XCTAssertFalse(calls.contains { $0.contains("boot") })
        session.connect(); try await waitUntilIdle(session)
        XCTAssertEqual(session.connectedID, simulatorID)
        XCTAssertTrue(session.selected?.isBooted == true)
        calls = await commands.calls
        XCTAssertTrue(calls.contains(["/usr/bin/xcrun", "simctl", "boot", simulatorID]))
        XCTAssertTrue(calls.contains(["/usr/bin/xcrun", "simctl", "bootstatus", simulatorID, "-b"]))
        session.close()
        XCTAssertNil(session.connectedID)
        let closedCalls = await commands.calls
        XCTAssertFalse(closedCalls.contains { $0.contains("shutdown") }, "Closing a tab must leave shared simulators running")
    }

    func testClosingDuringBootCannotReconnectAfterCancellation() async throws {
        let commands = SimulatorCommands()
        let session = SimulatorSession(command: { try await commands.run($0, $1, $2) })
        session.refresh(); try await waitUntilIdle(session)
        await commands.setPauseBoot()
        session.connect()
        for _ in 0..<200 {
            if await commands.bootStarted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        session.close()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(session.busy)
        XCTAssertNil(session.connectedID)
        XCTAssertNil(session.error)
    }

    func testDeviceBuildIsRejectedBeforeInstall() async throws {
        let commands = SimulatorCommands()
        let session = SimulatorSession(command: { try await commands.run($0, $1, $2) })
        session.refresh(); try await waitUntilIdle(session)
        session.connect(); try await waitUntilIdle(session)
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("bob-device-\(UUID()).app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { session.close(); try? FileManager.default.removeItem(at: app) }
        let info: [String: Any] = ["CFBundleIdentifier": "test.bob.fixture", "CFBundleSupportedPlatforms": ["iPhoneOS"]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        session.installApp(app); try await waitUntilIdle(session)
        XCTAssertTrue(session.error?.contains("Simulator .app") == true)
        let calls = await commands.calls
        XCTAssertFalse(calls.contains { $0.contains("install") || $0.contains("launch") })
    }

    func testInputCoordinatesRespectLetterboxingAndClampAnActiveDrag() {
        let rect = SimulatorScreenView.displayRect(in: CGRect(x: 0, y: 0, width: 600, height: 600), pixels: CGSize(width: 300, height: 600))
        XCTAssertEqual(rect, CGRect(x: 150, y: 0, width: 300, height: 600))
        XCTAssertNil(SimulatorScreenView.normalizedPoint(CGPoint(x: 40, y: 200), in: rect))
        XCTAssertEqual(SimulatorScreenView.normalizedPoint(CGPoint(x: 300, y: 150), in: rect), CGPoint(x: 0.5, y: 0.25))
        XCTAssertEqual(SimulatorScreenView.normalizedPoint(CGPoint(x: 700, y: -10), in: rect, clamp: true), CGPoint(x: 1, y: 0))
    }

    func testSimulatorTabOpensOnceWithoutStartingADevice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-simulator-tabs-\(UUID())")
        let store = AppStore(projectPath: root.path, storageDirectory: root.appendingPathComponent("state"))
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        _ = try await store.openWorkspaceTab(kind: .simulator, path: nil, url: nil)
        let id = store.selectedTabID
        store.openPanel(.editor); store.openPanel(.simulator)
        XCTAssertEqual(store.selectedTabID, id)
        XCTAssertEqual(store.openTabs.filter { $0.kind == .simulator }.count, 1)
        XCTAssertNil(store.simulator.connectedID)
        XCTAssertFalse(store.simulator.busy)
        XCTAssertTrue(store.simulator.devices.isEmpty)
        _ = try store.closeWorkspaceTab(XCTUnwrap(id))
        XCTAssertEqual(store.selectedPanel, .editor)
    }

    func testLiveDeviceRendersAndAcceptsTouchDragKeyboardAndHome() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let id = environment["BOB_SIMULATOR_TEST_UDID"], let app = environment["BOB_SIMULATOR_FIXTURE_APP"] else {
            throw XCTSkip("Set BOB_SIMULATOR_TEST_UDID to a disposable device and BOB_SIMULATOR_FIXTURE_APP to the built SimulatorFixture.app")
        }
        let developer = try await SimulatorSession.run("/usr/bin/xcode-select", ["-p"], 10)
        let listing = try await SimulatorSession.run("/usr/bin/xcrun", ["simctl", "list", "devices", "available", "--json"], 15)
        if try !SimulatorDevice.decode(Data(listing.utf8)).contains(where: { $0.id == id && $0.isBooted }) {
            _ = try await SimulatorSession.run("/usr/bin/xcrun", ["simctl", "boot", id], 30)
        }
        _ = try await SimulatorSession.run("/usr/bin/xcrun", ["simctl", "bootstatus", id, "-b"], 180)
        _ = try await SimulatorSession.run("/usr/bin/xcrun", ["simctl", "install", id, app], 60)
        _ = try? await SimulatorSession.run("/usr/bin/xcrun", ["simctl", "terminate", id, "test.bob.simulator-fixture"], 15)
        _ = try await SimulatorSession.run("/usr/bin/xcrun", ["simctl", "launch", id, "test.bob.simulator-fixture"], 30)
        _ = NSApplication.shared
        let framebuffer = SimulatorFramebuffer()
        var latest: IOSurface?
        var frames = 0
        try framebuffer.start(id: id, developerDirectory: developer) { latest = $0; frames += 1 }
        defer { framebuffer.stop() }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        func color() -> [UInt8] {
            guard let latest else { return [] }
            let image = CIImage(ioSurface: latest)
            var pixel: [UInt8] = [0, 0, 0, 0]
            context.render(image, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 20, y: latest.height / 2, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return pixel
        }
        func waitForColor(_ expected: [UInt8]) async throws {
            for _ in 0..<160 {
                let pixel = color()
                if pixel.count == 4, zip(pixel.prefix(3), expected).allSatisfy({ abs(Int($0) - Int($1)) < 20 }) { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTFail("Expected \(expected), received \(color()); \(frames) framebuffer callbacks")
        }
        try await waitForColor([255, 0, 0])
        let input = try XCTUnwrap(framebuffer.input)
        try input.sendTouch(CGPoint(x: 0.5, y: 0.7), phase: .down)
        try await Task.sleep(for: .milliseconds(60))
        try input.sendTouch(CGPoint(x: 0.5, y: 0.7), phase: .up)
        try await waitForColor([0, 255, 0])
        try input.sendTouch(CGPoint(x: 0.5, y: 0.75), phase: .down)
        for step in 1...12 {
            try await Task.sleep(for: .milliseconds(16))
            try input.sendTouch(CGPoint(x: 0.5, y: 0.75 - Double(step) * 0.03), phase: .move)
        }
        try input.sendTouch(CGPoint(x: 0.5, y: 0.39), phase: .up)
        try await waitForColor([255, 255, 0])
        try input.sendTouch(CGPoint(x: 0.3, y: 0.27), phase: .down)
        try await Task.sleep(for: .milliseconds(60))
        try input.sendTouch(CGPoint(x: 0.3, y: 0.27), phase: .up)
        try await Task.sleep(for: .milliseconds(500))
        input.key(4, down: true)
        try await Task.sleep(for: .milliseconds(60))
        input.key(4, down: false)
        try await waitForColor([0, 0, 255])
        await input.home()
        try await Task.sleep(for: .seconds(1))
        XCTAssertNotEqual(color(), [0, 0, 255, 255])
        XCTAssertGreaterThan(frames, 5)
        framebuffer.stop()

        // Exercise the actual NSView used by the tab, including its layer and cleanup.
        let view = SimulatorScreenView()
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        view.attach(id: id, developerDirectory: developer) { XCTFail($0.localizedDescription) }
        for _ in 0..<100 where view.layer?.sublayers?.first?.contents == nil { try await Task.sleep(for: .milliseconds(20)) }
        view.layoutSubtreeIfNeeded()
        let displayed = try XCTUnwrap(view.layer?.sublayers?.first?.contents as? IOSurface)
        XCTAssertGreaterThan(displayed.width, 300)
        XCTAssertGreaterThan(view.layer?.sublayers?.first?.frame.height ?? 0, 500)
        view.detach()
        XCTAssertNil(view.layer?.sublayers?.first?.contents)
    }
}
