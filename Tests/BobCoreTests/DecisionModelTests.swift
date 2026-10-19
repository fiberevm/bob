import XCTest
@testable import BobCore
@testable import Bob

final class DecisionModelTests: XCTestCase {
    private let response = #"{"decisions":[{"id":"intent","probabilities":{"review":0.8,"edit":0.2},"selected_option":"review","confidence":0.8}],"input_tokens":100,"load_seconds":0.01,"decision_seconds":0.02}"#
    private var request: DecisionRequest {
        .init(state: "Review this code", questions: [
            .init(id: "intent", type: .choice, instructions: "What task?", choices: ["review": "Review code", "edit": "Edit code"])
        ])
    }

    func testSchemaDefaultsAndRejectsInvalidQuestions() throws {
        let data = Data(#"{"state":"Review code","questions":[{"id":"intent","type":"choice","instructions":"Task?","choices":{"review":"Review code"}}]}"#.utf8)
        let decoded = try JSONDecoder().decode(DecisionRequest.self, from: data)
        XCTAssertEqual(decoded.maxTokens, 4096)
        try decoded.validate()
        XCTAssertThrowsError(try DecisionRequest(state: "", questions: []).validate())
        XCTAssertThrowsError(try DecisionRequest(state: "", questions: request.questions + request.questions).validate())
        XCTAssertThrowsError(try DecisionRequest(state: "", questions: [.init(id: "x", type: .score, instructions: "Rate it")]).validate())
        XCTAssertThrowsError(try DecisionRequest(state: "", questions: request.questions, maxTokens: 16385).validate())
    }

    func testRejectsWrongOptionsUnnormalizedAndIncorrectSelectedProbabilities() throws {
        let good = try JSONDecoder().decode(DecisionResponse.self, from: Data(response.utf8))
        try good.validate(for: request)
        for invalid in [response.replacingOccurrences(of: "review", with: "unknown"),
                        response.replacingOccurrences(of: "0.2", with: "0.7"),
                        response.replacingOccurrences(of: "\"confidence\":0.8", with: "\"confidence\":0.4")] {
            let result = try JSONDecoder().decode(DecisionResponse.self, from: Data(invalid.utf8))
            XCTAssertThrowsError(try result.validate(for: request))
        }
    }

    private func fixture(_ body: String, timeout: TimeInterval = 5) throws -> (LocalDecisionModel, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bob-decision-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("worker.sh")
        try ("printf 'launch\\n' >> '\(directory.path)/launches'\n" + body).write(to: script, atomically: true, encoding: .utf8)
        return (LocalDecisionModel(executable: URL(fileURLWithPath: "/bin/sh"), modelDirectory: script, timeout: timeout), directory)
    }

    func testConcurrentRequestsShareOneWorkerAndUnloadRestartsIt() async throws {
        let (model, directory) = try fixture("while IFS= read -r line; do printf '%s\\n' '\(response)'; done\n")
        defer { model.unload(); try? FileManager.default.removeItem(at: directory) }
        async let first = model.decide(request)
        async let second = model.decide(request)
        let results = try await [first, second]
        XCTAssertEqual(results.map { $0.decisions.first?.selectedOption }, ["review", "review"])
        let launches = directory.appendingPathComponent("launches")
        XCTAssertEqual(try String(contentsOf: launches).split(separator: "\n").count, 1)
        model.unload()
        _ = try await model.decide(request)
        XCTAssertEqual(try String(contentsOf: launches).split(separator: "\n").count, 2)
    }

    func testCancellationAndTimeoutStopTheWorker() async throws {
        let (model, directory) = try fixture("read -r line\nwhile :; do :; done\n", timeout: 0.2)
        defer { model.unload(); try? FileManager.default.removeItem(at: directory) }
        let task = Task { try await model.decide(request) }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        do { _ = try await model.decide(request); XCTFail("Expected timeout") }
        catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
    }

    func testWorkerExitAndMalformedResponsesFailWithoutHanging() async throws {
        for body in ["exit 1\n", "read -r line\nprintf 'garbage\\n'\n", "read -r line\nprintf '%s\\n' '{\"error\":\"Too many tokens\"}'\n"] {
            let (model, directory) = try fixture(body)
            do { _ = try await model.decide(request); XCTFail("Expected an error") } catch {}
            model.unload()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testTokenLimitRejectionKeepsTheLoadedWorkerForRetry() async throws {
        let failure = #"{"error":"Request requires 8569 tokens; maximum is 8192. State is never silently truncated."}"#
        let (model, directory) = try fixture("read -r line\nprintf '%s\\n' '\(failure)'\nwhile IFS= read -r line; do printf '%s\\n' '\(response)'; done\n")
        defer { model.unload(); try? FileManager.default.removeItem(at: directory) }
        do { _ = try await model.decide(request); XCTFail("Expected token rejection") }
        catch let limit as DecisionInputLimitError {
            XCTAssertEqual(limit.requiredTokens, 8569)
            XCTAssertEqual(limit.maximumTokens, 8192)
        }
        let answer = try await model.decide(request)
        XCTAssertEqual(answer.decisions.first?.selectedOption, "review")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("launches")).split(separator: "\n").count, 1)
    }

    @MainActor func testToolOnlyAdvertisedWhenConfigured() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-decision-tools-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = WorkspaceFiles(root: root, checkpointDirectory: root.appendingPathComponent("checkpoints"))
        let tools = AgentTools(files: files, project: root.path, browser: nil, decisions: nil,
                               approvals: ApprovalCoordinator(runID: UUID()) { _ in }, rootInstructions: "")
        XCTAssertFalse(tools.registry.definitions.contains { $0.name == "local_decide" })
        XCTAssertEqual(LocalDecisions.definitions.first?.name, "local_decide")
    }

    @MainActor func testAgentCanUseTheConfiguredLocalModel() async throws {
        let (model, directory) = try fixture("while IFS= read -r line; do printf '%s\\n' '\(response)'; done\n")
        defer { model.unload(); try? FileManager.default.removeItem(at: directory) }
        let tools = AgentTools(files: WorkspaceFiles(root: directory, checkpointDirectory: directory.appendingPathComponent("checkpoints")),
            project: directory.path, browser: nil, decisions: model, reviewer: FixtureToolSafetyReviewer(),
            approvals: ApprovalCoordinator(runID: UUID()) { _ in XCTFail("Inference should not request action approval") }, rootInstructions: "")
        XCTAssertTrue(tools.registry.definitions.contains { $0.name == "local_decide" })
        let output = try await tools.registry.execute(.init(id: "decision-1", name: "local_decide",
            arguments: String(decoding: JSONEncoder().encode(request), as: UTF8.self)))
        let decoded = try JSONDecoder().decode(DecisionResponse.self, from: Data(output.utf8))
        XCTAssertEqual(decoded.decisions.first?.selectedOption, "review")
    }

    func testCancellingAQueuedCallDoesNotCancelAnotherCaller() async throws {
        let (model, directory) = try fixture("read -r line\nwhile [ ! -f \"$0.release\" ]; do :; done\nprintf '%s\\n' '\(response)'\nwhile IFS= read -r line; do printf '%s\\n' '\(response)'; done\n")
        defer { model.unload(); try? FileManager.default.removeItem(at: directory) }
        let first = Task { try await model.decide(request) }
        try await Task.sleep(nanoseconds: 20_000_000)
        let queued = Task { try await model.decide(request) }
        queued.cancel()
        try Data().write(to: directory.appendingPathComponent("worker.sh.release"))
        let answer = try await first.value
        XCTAssertEqual(answer.decisions.first?.selectedOption, "review")
        do { _ = try await queued.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let next = try await model.decide(request)
        XCTAssertEqual(next.decisions.first?.selectedOption, "review")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("launches")).split(separator: "\n").count, 1)
    }

    func testLiveClefFlash() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let executable = environment["BOB_CLEF_EXECUTABLE"], let directory = environment["BOB_CLEF_MODEL_DIRECTORY"] else {
            throw XCTSkip("Set BOB_CLEF_EXECUTABLE and BOB_CLEF_MODEL_DIRECTORY to run local GPU inference.")
        }
        let model = LocalDecisionModel(executable: URL(fileURLWithPath: executable), modelDirectory: URL(fileURLWithPath: directory))
        defer { model.unload() }
        let probes: [(String, String)] = [
            ("Review these changes for bugs. Do not implement anything.", "review"),
            ("Implement a new Save button in the editor.", "edit")
        ]
        var warmed: [Double] = []
        for index in 0..<12 {
            let probe = probes[index % probes.count]
            let result = try await model.decide(.init(state: probe.0, questions: request.questions))
            XCTAssertEqual(result.decisions.first?.selectedOption, probe.1)
            if index == 0 { print("CLEF first load: \(result.loadSeconds)s; first decision: \(result.decisionSeconds)s; tokens: \(result.inputTokens)") }
            else { warmed.append(result.decisionSeconds) }
        }
        print("CLEF warmed decisions: n=\(warmed.count), mean=\(warmed.reduce(0, +) / Double(warmed.count))s, min=\(warmed.min()!)s, max=\(warmed.max()!)s")
        let joint = try await model.decide(.init(state: "Review this code for bugs. This is a routine request with no urgency. Do not browse any websites.", questions: request.questions + [
            .init(id: "needs_browser", type: .noul, instructions: "Does the request require browsing a website?"),
            .init(id: "urgency", type: .score, instructions: "Rate the urgency of this request.", levels: ["Routine with no urgency", "Urgent emergency"])
        ]))
        XCTAssertEqual(joint.decisions.map(\.selectedOption), ["review", "false", "0"])
        XCTAssertNotNil(joint.decisions[1].noul)
        XCTAssertNotNil(joint.decisions[2].score)
        print("CLEF joint choice/boolean/score: \(joint.inputTokens) tokens, \(joint.decisionSeconds)s")
        // Verify the worker rejects oversized requests and can be started again.
        do {
            _ = try await model.decide(.init(state: "Review code", questions: request.questions, maxTokens: 1))
            XCTFail("Expected token-limit rejection")
        } catch { XCTAssertTrue(error.localizedDescription.contains("tokens")) }
        let result = try await model.decide(request)
        XCTAssertEqual(result.decisions.first?.selectedOption, "review")
    }
}
