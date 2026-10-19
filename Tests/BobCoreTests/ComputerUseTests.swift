import XCTest
import AppKit
import ScreenCaptureKit
import ApplicationServices
@testable import Bob
@testable import BobCore

private let fixtureApp = ComputerApp(bundleID: "com.example.ComputerFixture", name: "Computer Fixture", pid: 1234)
private let fixtureImage = ModelImage(data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jX1sAAAAASUVORK5CYII=")!, mimeType: "image/png", width: 800, height: 600)
private func fixtureState(id: String = "state-1", date: Date = Date()) -> ComputerSnapshot {
    ComputerSnapshot(id: id, app: fixtureApp, windowID: 42, title: "Fixture", frame: CGRect(x: -400, y: 100, width: 400, height: 300), elements: [
        ComputerElement(reference: 1, role: "AXTextField", label: "Message", value: "Original", frame: CGRect(x: -390, y: 110, width: 100, height: 30), editable: true),
        ComputerElement(reference: 2, role: "AXButton", label: "Apply", frame: CGRect(x: -390, y: 160, width: 100, height: 30)),
        ComputerElement(reference: 3, role: "AXSecureTextField", label: "Password", value: "never-return-this", frame: CGRect(x: -390, y: 210, width: 100, height: 30), editable: true, secure: true)
    ], image: fixtureImage, date: date)
}

final class ComputerProtocolTests: XCTestCase {
    func testScreenshotCoordinatesAccountForScaleAndNegativeDisplayOrigins() throws {
        let state = fixtureState()
        XCTAssertEqual(try state.screenPoint(x: 400, y: 300), CGPoint(x: -200, y: 250))
        for point in [(-1.0, 0.0), (800, 0), (0, 600), (Double.nan, 0), (0, Double.infinity)] {
            XCTAssertThrowsError(try state.screenPoint(x: point.0, y: point.1))
        }
    }
    func testStaleUnknownAndProtectedTargetsAreRejected() throws {
        let state = fixtureState()
        for args: [String: Any] in [
            ["action":"click", "snapshot":"old", "reference":2],
            ["action":"click", "snapshot":state.id, "reference":99],
            ["action":"type", "snapshot":state.id, "reference":3, "text":"secret"],
            ["action":"click", "snapshot":state.id, "x":40, "y":240],
            ["action":"drag", "snapshot":state.id, "reference":2, "end_x":40, "end_y":240],
            ["action":"type", "snapshot":state.id, "reference":2, "text":"wrong target"]
        ] { XCTAssertThrowsError(try ComputerAction(arguments: args).validate(in: state)) }
        XCTAssertThrowsError(try ComputerAction(arguments: ["action":"click", "snapshot":state.id, "reference":2]).validate(in: fixtureState(date: Date().addingTimeInterval(-121))))
        XCTAssertFalse(state.result.text.contains("never-return-this"))
    }
    func testKeysAndInputLimits() throws {
        XCTAssertEqual(try ComputerKeyChord("command+shift+s").keyCode, 1)
        XCTAssertTrue(try ComputerKeyChord("command+shift+s").modifiers.contains(.maskShift))
        for key in ["command+space", "command+tab", "control+command+q", "command+option+escape", "control+right", "bad+return", "nonsense"] { XCTAssertThrowsError(try ComputerKeyChord(key)) }
        XCTAssertThrowsError(try ComputerAction(arguments: ["action":"type", "snapshot":"s", "text":"text"]))
        XCTAssertThrowsError(try ComputerAction(arguments: ["action":"scroll", "snapshot":"s", "amount":9000]))
    }
    func testImageOutputsReachAllProvidersWithoutBreakingToolGroups() throws {
        let calls = [ToolCall(id: "a", name: "computer_snapshot", arguments: "{}"), ToolCall(id: "b", name: "read_file", arguments: "{}")]
        let messages = [ModelMessage(role: "assistant", toolCalls: calls), ModelMessage(role: "tool", text: "Screenshot", toolCallID: "a", images: [fixtureImage]), ModelMessage(role: "tool", text: "File", toolCallID: "b")]
        let responses = try ModelClient.responsesInput(messages)
        let output = try XCTUnwrap(responses[2]["output"] as? [[String: Any]])
        XCTAssertEqual(output.last?["image_url"] as? String, fixtureImage.dataURL)
        XCTAssertEqual(responses[2]["call_id"] as? String, "a")
        let anthropic = ModelClient.anthropicInput(messages)
        let blocks = try XCTUnwrap(anthropic.last?["content"] as? [[String: Any]])
        let content = try XCTUnwrap(blocks.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.last?["type"] as? String, "image")
        let chat = ModelClient.chatInput(messages)
        XCTAssertEqual(chat.map { $0["role"] as? String ?? "" }, ["assistant", "tool", "tool", "user"])
        let images = try XCTUnwrap(chat.last?["content"] as? [[String: Any]])
        XCTAssertEqual((images.last?["image_url"] as? [String: Any])?["url"] as? String, fixtureImage.dataURL)
    }
    func testImagesAreBoundedAndOldHistoriesStillDecode() throws {
        let old = Data(#"{"role":"user","text":"old","toolCalls":[],"providerItems":[]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ModelMessage.self, from: old).images)
        let messages = (0..<6).map { ModelMessage(role: "tool", text: "Frame \($0)", toolCallID: "\($0)", images: [fixtureImage]) }
        let bounded = ConversationHistory.limitingImages(messages)
        XCTAssertEqual(bounded.compactMap(\.images).flatMap { $0 }.count, 2)
        XCTAssertTrue(bounded[0].text.contains("omitted"))
        XCTAssertEqual(try JSONDecoder().decode([ModelMessage].self, from: JSONEncoder().encode(bounded)), bounded)
        let textOnly = ContextManager().estimatedTokens([ModelMessage(role: "tool", text: "Frame")])
        let multimodal = ContextManager().estimatedTokens([ModelMessage(role: "tool", text: "Frame", images: [fixtureImage])])
        XCTAssertGreaterThan(multimodal, textOnly + 1000)
    }
    func testScreenshotJournalCheckpointsStayBoundedAndRecoverImages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-images-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("turn.jsonl"), journal = TurnJournal(url: url), runID = UUID()
        let image = ModelImage(data: Data(repeating: 1, count: 1024 * 1024), width: 1000, height: 1000)
        var history = [ModelMessage(role: "user", text: "Inspect")]
        try await journal.begin(runID: runID, history: history)
        for index in 0..<5 {
            let call = ToolCall(id: "\(index)", name: "computer_snapshot", arguments: "{}")
            let assistant = ModelMessage(role: "assistant", toolCalls: [call]), result = ModelMessage(role: "tool", text: "Frame \(index)", toolCallID: call.id, images: [image])
            history += [assistant, result]
            try await journal.append(assistant); try await journal.started(call); try await journal.append(result)
            history = ConversationHistory.limitingImages(history)
            try await journal.replace(history)
        }
        try await journal.finish()
        let recovered = try XCTUnwrap(TurnJournal.recover(from: url))
        XCTAssertEqual(recovered.runID, runID); XCTAssertEqual(recovered.history, history)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        XCTAssertLessThan(try XCTUnwrap(size).intValue, 8 * 1024 * 1024)
    }
}

@MainActor private final class FixtureComputerDriver: ComputerDriver {
    var permissions = ComputerPermissions(screenRecording: true, accessibility: true)
    var onUserInput: (() -> Void)?
    var captures = 0, cancellations = 0
    var actions: [ComputerAction.Kind] = []
    var blockCapture: (() -> Void)?
    func applications() -> [ComputerApp] { [fixtureApp] }
    func application(_ bundleID: String) throws -> ComputerApp { ComputerApp(bundleID: bundleID, name: "Computer Fixture", pid: fixtureApp.pid) }
    func open(_ bundleID: String) async throws -> ComputerApp { try application(bundleID) }
    func capture(_ app: String, windowID: UInt32?) async throws -> ComputerSnapshot {
        captures += 1
        if let blockCapture { blockCapture(); try await Task.sleep(for: .seconds(30)) }
        return fixtureState(id: "state-\(captures)")
    }
    func perform(_ action: ComputerAction, in snapshot: ComputerSnapshot) async throws { actions.append(action.kind) }
    func cancel() { cancellations += 1 }
}
private actor ComputerModel: ModelTransport {
    var responses: [ModelMessage]
    private(set) var histories: [[ModelMessage]] = []
    init(_ values: [ModelMessage]) { responses = values }
    func complete(messages: [ModelMessage], system: String, tools: [ToolDefinition], onText: @escaping (String) async -> Void) async throws -> ModelMessage {
        histories.append(messages)
        guard !responses.isEmpty else { throw BobError.message("Unexpected model call") }
        return responses.removeFirst()
    }
}

@MainActor final class ComputerSessionTests: XCTestCase {
    private let config = ModelConfiguration(provider: .compatible, model: "fixture", baseURL: "http://localhost/v1", token: "")
    private func access() -> (ComputerAccess, UserDefaults, String) {
        let suite = "bob-computer-tests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let access = ComputerAccess(defaults: defaults); access.enabled = true
        return (access, defaults, suite)
    }
    private func call(_ id: String, _ name: String, _ args: [String: Any]) throws -> ModelMessage {
        ModelMessage(role: "assistant", toolCalls: [ToolCall(id: id, name: name, arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self))])
    }
    func testAgentApprovesAppAndActionThenSeesImageFeedback() async throws {
        let (access, defaults, suite) = access(); defer { defaults.removePersistentDomain(forName: suite) }
        let driver = FixtureComputerDriver(), computer = ComputerSession(access: access, driver: driver), harness = AgentHarness(reviewer: FixtureToolSafetyReviewer())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-cua-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = WorkspaceFiles(root: root, checkpointDirectory: root.appendingPathComponent("checkpoints"))
        let model = ComputerModel([try call("snapshot", "computer_snapshot", ["app":fixtureApp.bundleID]), try call("action", "computer_action", ["action":"type", "snapshot":"state-1", "reference":1, "text":"Updated"]), ModelMessage(role: "assistant", text: "Verified")])
        var approvals = 0
        harness.onEvent = { if case .approval(let request?) = $0 { approvals += 1; request.resolve(true) } }
        let history = try await harness.run(configuration: config, messages: [ModelMessage(role: "user", text: "Update the fixture")], files: files, project: root.path, transport: model, computer: computer)
        XCTAssertEqual(approvals, 2); XCTAssertEqual(driver.actions, [.type]); XCTAssertEqual(driver.captures, 2)
        XCTAssertEqual(history.compactMap(\.images).flatMap { $0 }.count, 2)
        let inputs = await model.histories
        XCTAssertTrue(inputs.last?.contains { !($0.images ?? []).isEmpty && $0.text.contains("state-2") } == true)
        XCTAssertThrowsError(try computer.current("state-2"), "Run completion must invalidate control references")
        XCTAssertNotNil(computer.latest, "Keep the final preview visible")
    }
    func testRevokingAppDuringApprovalPreventsInput() async throws {
        let (access, defaults, suite) = access(); defer { defaults.removePersistentDomain(forName: suite) }
        access.allow(fixtureApp.bundleID)
        let driver = FixtureComputerDriver(), computer = ComputerSession(access: access, driver: driver), harness = AgentHarness(reviewer: FixtureToolSafetyReviewer())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-cua-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ComputerModel([try call("snapshot", "computer_snapshot", ["app":fixtureApp.bundleID]), try call("action", "computer_action", ["action":"click", "snapshot":"state-1", "reference":2]), ModelMessage(role: "assistant", text: "Stopped")])
        harness.onEvent = { if case .approval(let request?) = $0 { access.revoke(fixtureApp.bundleID); request.resolve(true) } }
        _ = try await harness.run(configuration: config, messages: [], files: WorkspaceFiles(root: root, checkpointDirectory: root), project: root.path, transport: model, computer: computer)
        XCTAssertTrue(driver.actions.isEmpty)
        XCTAssertFalse(access.allowedApps.contains(fixtureApp.bundleID))
    }
    func testBlockedAppsAndDisabledComputerNeverCapture() async throws {
        let (access, defaults, suite) = access(); defer { defaults.removePersistentDomain(forName: suite) }
        let driver = FixtureComputerDriver(), computer = ComputerSession(access: access, driver: driver)
        for id in ["com.apple.Terminal", "com.openai.chat", "com.bob.native", "com.apple.systempreferences", "com.apple.SecurityAgent"] {
            XCTAssertThrowsError(try computer.application(id)); access.allow(id); XCTAssertFalse(access.allowedApps.contains(id))
        }
        access.enabled = false
        do { _ = try await computer.capture(fixtureApp.bundleID); XCTFail("Disabled computer captured a window") } catch {}
        XCTAssertEqual(driver.captures, 0)
    }
    func testActionConsumesSnapshotAndDisablingRevokesReferences() async throws {
        let (access, defaults, suite) = access(); defer { defaults.removePersistentDomain(forName: suite) }
        let driver = FixtureComputerDriver(), computer = ComputerSession(access: access, driver: driver)
        let snapshot = try await computer.capture(fixtureApp.bundleID)
        let action = try ComputerAction(arguments: ["action":"click", "snapshot":snapshot.id, "reference":2])
        _ = try await computer.perform(action)
        do { _ = try await computer.perform(action); XCTFail("Reused an old snapshot") } catch {}
        XCTAssertEqual(driver.actions.count, 1)
        access.enabled = false
        XCTAssertThrowsError(try computer.current("state-2"))
    }
    func testCallerCancellationStopsCaptureAndDiscardsLateState() async throws {
        let (access, defaults, suite) = access(); defer { defaults.removePersistentDomain(forName: suite) }
        let driver = FixtureComputerDriver(), ready = expectation(description: "Capture started")
        driver.blockCapture = { ready.fulfill() }
        let computer = ComputerSession(access: access, driver: driver)
        let task = Task { try await computer.capture(fixtureApp.bundleID) }
        await fulfillment(of: [ready], timeout: 2); task.cancel(); computer.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertNil(computer.latest); XCTAssertFalse(computer.busy)
    }
    func testUserTakeoverRevokesSnapshotAndNotifiesRunOwner() async throws {
        let (access, defaults, suite) = access(); defer { defaults.removePersistentDomain(forName: suite) }
        let driver = FixtureComputerDriver(), computer = ComputerSession(access: access, driver: driver)
        let state = try await computer.capture(fixtureApp.bundleID)
        var stopped = false; computer.onTakeover = { stopped = true }
        driver.onUserInput?()
        XCTAssertTrue(stopped); XCTAssertThrowsError(try computer.current(state.id))
        XCTAssertGreaterThan(driver.cancellations, 0)
    }
    func testStaleAlwaysAllowCallbackCannotPersistAnotherAppGrant() async throws {
        var old: ApprovalRequest?, count = 0, remembered: [String] = []
        let coordinator = ApprovalCoordinator(runID: UUID()) { request in
            guard let request else { return }; count += 1
            if count == 1 { old = request; request.resolve(true) }
            else { old?.alwaysAllow?(); request.resolve(false) }
        }
        _ = await coordinator.request(callID: "one", title: "App one", detail: "", remember: { remembered.append("one") })
        _ = await coordinator.request(callID: "two", title: "App two", detail: "", remember: { remembered.append("two") })
        XCTAssertTrue(remembered.isEmpty)
    }
    func testProtectedFieldsAreRedactedInScreenshotPixels() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let image = try XCTUnwrap(context.makeImage())
        let element = ComputerElement(reference: 1, role: "AXSecureTextField", label: "Password", frame: CGRect(x: 20, y: 20, width: 60, height: 60), secure: true)
        let output = try NativeComputerDriver().redact(image, frame: CGRect(x: 0, y: 0, width: 100, height: 100), elements: [element])
        let pixels = NSBitmapImageRep(cgImage: output)
        XCTAssertLessThan(try XCTUnwrap(pixels.colorAt(x: 50, y: 50)).redComponent, 0.2)
        XCTAssertGreaterThan(try XCTUnwrap(pixels.colorAt(x: 5, y: 5)).redComponent, 0.8)
    }
    func testNativeCaptureAccessibilityAndCoordinateInputInIsolatedFixture() async throws {
        guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else { throw XCTSkip("Native integration requires Accessibility and Screen Recording for the test host.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-native-cua-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = root.appendingPathComponent("ComputerUseFixture.app"), contents = appURL.appendingPathComponent("Contents"), binaryDirectory = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        try FileManager.default.copyItem(at: products.appendingPathComponent("ComputerUseFixture"), to: binaryDirectory.appendingPathComponent("ComputerUseFixture"))
        let id = "com.bob.ComputerUseFixture." + UUID().uuidString
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName":"ComputerUseFixture", "CFBundleExecutable":"ComputerUseFixture", "CFBundlePackageType":"APPL", "NSHighResolutionCapable":true]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let signature = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--force", "--sign", "-", appURL.path])
        XCTAssertEqual(signature.status, 0, signature.error)
        let launch = NSWorkspace.OpenConfiguration(); launch.createsNewApplicationInstance = true
        let app = try await NSWorkspace.shared.openApplication(at: appURL, configuration: launch)
        defer { app.terminate() }
        try await Task.sleep(for: .milliseconds(500))
        let ready = try? String(contentsOf: root.appendingPathComponent("ready.txt"), encoding: .utf8)
        XCTAssertNotNil(ready, "Fixture UI did not finish launching")
        var fixtureVisible = false
        for _ in 0..<40 {
            let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            fixtureVisible = windows.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier && ($0[kCGWindowName as String] as? String) == "Bob Computer Fixture" }
            if fixtureVisible { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(fixtureVisible, "Fixture window not exposed by WindowServer. UI: \(ready ?? "not ready")")
        // Trust flags alone do not guarantee that a GUI test host exposes remote AX geometry.
        // Check the independent OS prerequisite; driver/mapping failures after this still fail.
        let rootElement = AXUIElementCreateApplication(app.processIdentifier)
        var rawWindows: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(rootElement, kAXWindowsAttribute as CFString, &rawWindows)
        let nativeWindows = rawWindows as? [AXUIElement] ?? []
        let usableWindow = nativeWindows.contains { element in
            var role: CFTypeRef?, position: CFTypeRef?, size: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            _ = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position)
            _ = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size)
            return role as? String == kAXWindowRole && position.map { CFGetTypeID($0) == AXValueGetTypeID() } == true && size.map { CFGetTypeID($0) == AXValueGetTypeID() } == true
        }
        guard usableWindow else { throw XCTSkip("The native test host exposes the fixture app but no AXWindow geometry. Live capture/input requires verification in a full macOS accessibility session.") }
        let driver = NativeComputerDriver()
        XCTAssertEqual(try driver.application(id).pid, app.processIdentifier)
        let initial = try await driver.capture(id, windowID: nil)
        XCTAssertGreaterThan(initial.image.data.count, 100)
        XCTAssertNotNil(NSImage(data: initial.image.data))
        XCTAssertFalse(initial.result.text.contains("never-return-this"))
        let input = try XCTUnwrap(initial.elements.first { $0.editable && $0.label == "Fixture input" })
        try await driver.perform(ComputerAction(arguments: ["action":"type", "snapshot":initial.id, "reference":input.reference, "text":"Native update"]), in: initial)
        let typed = try await driver.capture(id, windowID: initial.windowID)
        XCTAssertTrue(typed.elements.contains { $0.value == "Native update" })
        let button = try XCTUnwrap(typed.elements.first { $0.label == "Apply" && $0.role == "AXButton" })
        let x = (button.frame.midX - typed.frame.minX) / typed.frame.width * Double(typed.image.width)
        let y = (button.frame.midY - typed.frame.minY) / typed.frame.height * Double(typed.image.height)
        try await driver.perform(ComputerAction(arguments: ["action":"click", "snapshot":typed.id, "x":x, "y":y]), in: typed)
        try await Task.sleep(for: .milliseconds(200))
        let clicked = try await driver.capture(id, windowID: typed.windowID)
        XCTAssertTrue(clicked.elements.contains { $0.value.contains("Applied: Native update") || $0.label.contains("Applied: Native update") })
        XCTAssertTrue(clicked.elements.contains { $0.secure && $0.value == "[Protected]" })
    }
}
