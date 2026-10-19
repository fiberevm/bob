import AppKit
import QuartzCore
import SwiftUI
import XCTest
import BobCore
@testable import Bob

@MainActor final class MessageFlightTests: XCTestCase {
    func testSendingInAnEmptyChatActuallyStartsAFlight() async throws {
        try await checkChatFlight(previousMessages: [])
    }

    func testSendingInALongChatScrollsToTheLandingPositionBeforeFlying() async throws {
        let history = (0..<30).flatMap { index in
            [Message(role: .user, text: "Previous message \(index)"),
             Message(role: .assistant, text: String(repeating: "Previous response line.\n", count: 5))]
        }
        try await checkChatFlight(previousMessages: history)
    }

    private func checkChatFlight(previousMessages: [Message]) async throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "Send movement is intentionally disabled by Reduce Motion.")
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-send-animation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppStore(projectPath: root.path, storageDirectory: root.appendingPathComponent("state"))
        store.newSession(provider: .compatible); store.setModel("fixture")
        let sessionID = try XCTUnwrap(store.selectedID)
        store.mutate(sessionID) { $0.messages = previousMessages }
        let host = NSHostingView(rootView: ChatView(store: store))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        window.setContentSize(CGSize(width: 800, height: 700))
        defer {
            store.shutdown(); window.orderOut(nil); window.contentView = nil
            try? FileManager.default.removeItem(at: root)
        }
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
        try await Task.sleep(for: .milliseconds(50))
        store.draft = "A bubble that should visibly fly from the composer"
        store.send(transport: AnimationReplyModel())
        XCTAssertNotNil(store.lastSubmittedMessage)
        var flight: MessageFlightView?
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
            if let view = findFlight(in: host), view.bubbleLayer?.animation(forKey: "send") != nil {
                flight = view; break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let view = try XCTUnwrap(flight, "The send flow must create a moving bubble, not just insert transcript text.")
        let layer = try XCTUnwrap(view.bubbleLayer)
        let animation = try XCTUnwrap(layer.animation(forKey: "send") as? CASpringAnimation)
        let start = try XCTUnwrap(animation.fromValue as? NSValue).pointValue
        let end = try XCTUnwrap(animation.toValue as? NSValue).pointValue
        XCTAssertGreaterThan(start.y, end.y + 20)
        XCTAssertGreaterThan(end.x, start.x + 20)
        XCTAssertGreaterThan(end.y, 0)
        XCTAssertLessThan(end.y, host.bounds.height - 40)
        for _ in 0..<100 where view.bubbleLayer != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(view.bubbleLayer)
        XCTAssertEqual(store.selectedID, sessionID)
        XCTAssertEqual(store.selected?.messages.filter { $0.role == .user }.count,
                       previousMessages.filter { $0.role == .user }.count + 1)
    }

    private func findFlight(in view: NSView) -> MessageFlightView? {
        if let flight = view as? MessageFlightView { return flight }
        for child in view.subviews { if let flight = findFlight(in: child) { return flight } }
        return nil
    }

    func testBubbleMovesFromComposerAndCompletesAfterTheSpring() async throws {
        _ = NSApplication.shared
        let view = MessageFlightView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        defer { view.cancel(); window.orderOut(nil); window.contentView = nil }
        window.orderFront(nil)
        window.displayIfNeeded()
        CATransaction.flush()
        let message = Message(role: .user, text: "Animate this message")
        let source = CGRect(x: 16, y: 552, width: 720, height: 20)
        let target = CGRect(x: 580, y: 64, width: 200, height: 40)
        var completed: UUID?
        view.prepare(message: message, source: source, destination: target) { completed = $0 }
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        let layer = try XCTUnwrap(view.bubbleLayer)
        XCTAssertNotNil(layer.contents, "The flight must contain the rendered message, not an empty moving layer.")
        let animation = try XCTUnwrap(layer.animation(forKey: "send") as? CASpringAnimation)
        let from = try XCTUnwrap(animation.fromValue as? NSValue).pointValue
        let to = try XCTUnwrap(animation.toValue as? NSValue).pointValue
        XCTAssertEqual(to.x - from.x, target.minX - source.minX, accuracy: 0.5)
        XCTAssertEqual(from.y - to.y, source.midY - target.midY, accuracy: 0.5)
        XCTAssertNil(completed, "The real transcript bubble must remain hidden during the flight.")

        try await Task.sleep(for: .milliseconds(100))
        let moving = try XCTUnwrap(layer.presentation()).position
        XCTAssertGreaterThan(moving.x, from.x + 1)
        XCTAssertLessThan(moving.x, to.x - 1)
        XCTAssertGreaterThan(moving.y, to.y + 1)
        XCTAssertLessThan(moving.y, from.y - 1)
        XCTAssertNil(completed)

        for _ in 0..<100 where completed == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(completed, message.id)
        XCTAssertNil(view.bubbleLayer)
    }

    func testLazyDestinationCanArriveLaterAndCancelledFlightsDoNotComplete() throws {
        _ = NSApplication.shared
        let view = MessageFlightView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        defer { view.cancel(); window.contentView = nil }
        let message = Message(role: .user, text: "A message waiting for scroll layout")
        let source = CGRect(x: 16, y: 552, width: 720, height: 20)
        let target = CGRect(x: 450, y: 64, width: 330, height: 40)
        var completed = false
        view.prepare(message: message, source: source, destination: nil) { _ in completed = true }
        view.layoutSubtreeIfNeeded()
        XCTAssertNil(view.bubbleLayer)
        view.prepare(message: message, source: source, destination: target) { _ in completed = true }
        view.layoutSubtreeIfNeeded()
        XCTAssertNotNil(view.bubbleLayer?.animation(forKey: "send"))
        view.cancel()
        XCTAssertNil(view.bubbleLayer)
        XCTAssertTrue(view.subviews.isEmpty)
        XCTAssertFalse(completed)
    }
}

private actor AnimationReplyModel: ModelTransport {
    func complete(messages: [ModelMessage], system: String, tools: [ToolDefinition], onText: @escaping (String) async -> Void) async throws -> ModelMessage {
        return ModelMessage(role: "assistant", text: "Ready")
    }
}
