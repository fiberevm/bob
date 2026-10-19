import XCTest
import Darwin
@testable import Bob
@testable import BobCore

private actor ClaudeToolCounter {
    private(set) var calls = 0
    func run() -> ToolResult { calls += 1; return ToolResult(text: "Fixture contents") }
}

@MainActor final class ClaudeCodeTests: XCTestCase {
    private func fixture() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-claude-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("claude-fixture")
        let script = #"""
        #!/usr/bin/env python3
        import json,sys,uuid,os
        def send(x): print(json.dumps(x),flush=True)
        def read(): return json.loads(sys.stdin.readline())
        assert '--max-turns' not in sys.argv
        if 'auth' in sys.argv:
            if 'login' in sys.argv:
                print('Paste sign-in code:',flush=True)
                sys.exit(0 if sys.stdin.readline().strip()=='fixture-code' else 1)
            send({'loggedIn':True,'authMethod':'claude.ai','email':'fixture@example.com','subscriptionType':'max'})
            sys.exit(0)
        init=read()
        send({'type':'control_response','response':{'subtype':'success','request_id':init['request_id'],'response':{'models':[{'value':'sonnet','displayName':'Sonnet','supportedEffortLevels':['low','high']}]}}})
        servers=json.loads(sys.argv[sys.argv.index('--mcp-config')+1])['mcpServers']
        if '--no-session-persistence' in sys.argv:
            assert not servers
            assert sys.argv[sys.argv.index('--tools')+1]==''
            assert not any(x.startswith('--resume=') for x in sys.argv)
            user=read()
            assert json.loads(user['message']['content'])=='Fix the login redirect loop'
            send({'type':'system','subtype':'init','session_id':str(uuid.uuid4())})
            send({'type':'assistant','uuid':'title','message':{'content':[{'type':'text','text':'Fix login redirect loop'}]}})
            send({'type':'result','subtype':'success','is_error':False,'result':'Fix login redirect loop'})
            sys.stdin.read()
            sys.exit(0)
        if not servers: sys.stdin.read(); sys.exit(0)
        user=read()
        session=next((x.split('=',1)[1] for x in sys.argv if x.startswith('--resume=')),str(uuid.uuid4()))
        send({'type':'system','subtype':'init','session_id':session})
        if user['message']['content']=='STEERING_FIXTURE':
            send({'type':'stream_event','event':{'type':'content_block_delta','delta':{'type':'text_delta','text':'Original work'}}})
            interrupt=read()
            assert interrupt['type']=='control_request' and interrupt['request']['subtype']=='interrupt'
            send({'type':'control_response','response':{'subtype':'success','request_id':interrupt['request_id'],'response':{}}})
            send({'type':'assistant','uuid':'interrupted','message':{'content':[{'type':'text','text':'Original work'},{'type':'tool_use','id':'stale','name':'mcp__bob__write_file','input':{'path':'old.txt','content':'stale'}}]}})
            send({'type':'result','subtype':'error_during_execution','is_error':True,'errors':['Interrupted']})
            update=read()
            assert update['type']=='user' and update['session_id']==session
            assert update['message']['content']=='Focus on the parser\n\nDo not edit files'
            send({'type':'assistant','uuid':'steered','message':{'content':[{'type':'text','text':'Following the updated direction'}]}})
            send({'type':'result','subtype':'success','is_error':False,'result':'Following the updated direction','session_id':session})
            sys.stdin.read()
            sys.exit(0)
        def control(id,request):
            send({'type':'control_request','request_id':id,'request':request})
            response=read()
            assert response['response']['request_id']==id
            return response['response']['response']
        denied=control('native',{'subtype':'can_use_tool','tool_name':'Bash','input':{'command':'touch forbidden'}})
        assert denied['behavior']=='deny'
        listed=control('list',{'subtype':'mcp_message','server_name':'bob','message':{'jsonrpc':'2.0','id':1,'method':'tools/list'}})
        assert any(x['name']=='read_file' for x in listed['mcp_response']['result']['tools'])
        send({'type':'stream_event','event':{'type':'content_block_delta','delta':{'type':'text_delta','text':'Checking '}}})
        tool_count=32 if user['message']['content']=='LONG_RUN_FIXTURE' else 1
        for index in range(tool_count):
            toolid=('read-2' if any(x.startswith('--resume=') for x in sys.argv) else 'read-1') if tool_count==1 else 'read-'+str(index+1)
            message={'type':'assistant','uuid':'first-'+str(index),'message':{'id':'message-'+str(index),'model':'claude-fixture','usage':{'input_tokens':100+index,'cache_read_input_tokens':20,'cache_creation_input_tokens':30,'output_tokens':10},'content':[{'type':'text','text':'Checking fixture.'},{'type':'tool_use','id':toolid,'name':'mcp__bob__read_file','input':{'path':'README.md'}}]}}
            send(message)
            send(message)
            req={'subtype':'mcp_message','server_name':'bob','message':{'jsonrpc':'2.0','id':index+2,'method':'tools/call','params':{'name':'read_file','arguments':{'path':'README.md'}}}}
            request_id='invoke-'+str(index)
            output=control(request_id,req)['mcp_response']
            assert 'error' not in output
            duplicate=control(request_id,req)['mcp_response']
            assert 'error' in duplicate
        text='Denied' if output.get('result',{}).get('isError') else 'Done'
        send({'type':'assistant','uuid':'final','message':{'id':'message2','model':'claude-fixture','usage':{'input_tokens':200,'cache_read_input_tokens':20,'cache_creation_input_tokens':30,'output_tokens':15},'content':[{'type':'text','text':text}]}})
        usage={'input_tokens':sum(100+i for i in range(tool_count))+200,'cache_read_input_tokens':20*(tool_count+1),'cache_creation_input_tokens':30*(tool_count+1),'output_tokens':10*tool_count+15}
        send({'type':'result','subtype':'success','is_error':False,'result':text,'session_id':session,'usage':usage,'modelUsage':{'claude-fixture':{'contextWindow':200000}}})
        sys.stdin.read()
        open(os.path.join(os.path.dirname(__file__),'flushed.txt'),'w').write('saved')
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try "Fixture contents".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        return (root, executable)
    }
    private var configuration: ModelConfiguration { .init(provider: .claudeCode, model: "sonnet", baseURL: "", token: "") }

    func testSubscriptionUsageDeduplicatesMessagesAndResultAndReportsContextWindow() async throws {
        let (root, executable) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let harness = AgentHarness(reviewer: FixtureToolSafetyReviewer())
        var usage: [String: ModelUsage] = [:], context: ContextUsage?
        harness.onEvent = { event in
            if case .usage(let record) = event { usage[record.id] = record.usage }
            if case .context(let value) = event { context = value }
        }
        let url = root.appendingPathComponent("usage.jsonl")
        _ = try await harness.run(configuration: configuration, messages: [.init(role: "user", text: "Read the fixture")],
            files: WorkspaceFiles(root: root, checkpointDirectory: root.appendingPathComponent("checkpoints")), project: root.path,
            journal: TurnJournal(url: url), claudeExecutable: executable)
        XCTAssertEqual(usage.count, 1)
        XCTAssertEqual(usage.values.first, .init(inputTokens: 400, outputTokens: 25))
        XCTAssertEqual(context?.tokens, 265)
        XCTAssertEqual(context?.budget, 200000)
        XCTAssertEqual(context?.source, .provider)
        XCTAssertEqual(try TurnJournal.recover(from: url)?.usageRecords, usage)
    }

    func testSubscriptionTitleUsesIsolatedToollessSession() async throws {
        let (root, executable) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let title = try await ConversationTitle.generate(for: "Fix the login redirect loop", configuration: configuration, claudeExecutable: executable)
        XCTAssertEqual(title, "Fix login redirect loop")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("flushed.txt").path))
        XCTAssertFalse(try ClaudeCodeBackend.arguments().contains("--no-session-persistence"))
    }

    func testCLIArgumentsDisableNativeToolsAndOnlyAllowReviewedBobTools() throws {
        let tools = [ToolDefinition(name: "read_file", description: "Read", parameters: [:])]
        let args = try ClaudeCodeBackend.arguments(model: "sonnet", effort: "high", system: "Bob rules", tools: tools)
        XCTAssertEqual(args[args.firstIndex(of: "--tools")! + 1], "")
        XCTAssertTrue(args.contains("--strict-mcp-config"))
        XCTAssertFalse(args.contains("--max-turns"))
        XCTAssertTrue(args.contains("--model=sonnet")); XCTAssertTrue(args.contains("--effort=high"))
        XCTAssertEqual(args[args.firstIndex(of: "--allowedTools")! + 1], "mcp__bob__read_file")
        XCTAssertFalse(args.contains("--dangerously-skip-permissions"))
        XCTAssertFalse(args.contains("--system-prompt"), "Append Bob rules while retaining Claude Code's own identity")
        XCTAssertThrowsError(try ClaudeCodeBackend.arguments(resume: "--dangerously-skip-permissions"))
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN"] {
            XCTAssertNil(ClaudeCodeBackend.environment[key])
        }
    }

    func testSubscriptionConnectionAndCatalogComeFromOfficialBinary() async throws {
        let (root, executable) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let connection = ClaudeCodeConnection(executable: executable)
        await connection.refresh()
        XCTAssertTrue(connection.isConnected, connection.error ?? "")
        XCTAssertEqual(connection.models.first?.id, "sonnet")
        XCTAssertEqual(connection.models.first?.reasoningEfforts, ["low", "high"])
        XCTAssertTrue(connection.accountLabel.contains("Max"))
        let suite = "bob-claude-test-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ConnectionPreferences(defaults: defaults, claude: connection)
        XCTAssertTrue(preferences.connectedProviders.contains(.claudeCode))
        XCTAssertEqual(preferences.defaultModel(for: .claudeCode), "sonnet")
        let store = AppStore(projectPath: root.path, storageDirectory: root.appendingPathComponent("state"), connections: preferences)
        store.newSession(provider: .claudeCode); store.setModel("sonnet")
        store.draft = "Read the fixture"
        store.send(reviewer: FixtureToolSafetyReviewer(.init(risk: .low, reason: "Low-risk fixture")))
        for _ in 0..<300 where store.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isRunning)
        XCTAssertEqual(store.selected?.messages.last?.text, "Done")
        let sessionID = try XCTUnwrap(store.selected?.claudeCodeSessionID)
        XCTAssertNil(store.approval)
        store.shutdown()
        let reopened = AppStore(projectPath: root.path, storageDirectory: root.appendingPathComponent("state"), connections: preferences)
        XCTAssertEqual(reopened.selected?.claudeCodeSessionID, sessionID)
        reopened.shutdown()
    }

    func testStreamingToolReviewAndSessionRecoveryWithoutAPIKeyOrDuplicateExecution() async throws {
        let (root, executable) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = TurnJournal(url: root.appendingPathComponent("turn.jsonl")), harness = AgentHarness(reviewer: FixtureToolSafetyReviewer(.init(risk: .low, reason: "No material hazard")))
        var text = "", sessionID: String?, activities: [ToolActivity] = [], approvals = 0
        harness.onEvent = { event in
            switch event {
            case .text(let value): text += value
            case .backendSession(let value): sessionID = value
            case .tool(let value): activities.append(value)
            case .approval(let request?): approvals += 1; request.resolve(false)
            default: break
            }
        }
        let history = try await harness.run(configuration: configuration, messages: [.init(role: "user", text: "Read the fixture")],
            files: WorkspaceFiles(root: root, checkpointDirectory: root.appendingPathComponent("checkpoints")), project: root.path, journal: journal, claudeExecutable: executable)
        XCTAssertEqual(text, "Checking fixture.Done")
        XCTAssertEqual(history.filter { $0.role == "tool" }.count, 1, "A duplicate control request must never repeat execution")
        XCTAssertEqual(history.first { $0.role == "tool" }?.text, "Fixture contents")
        XCTAssertEqual(approvals, 0)
        let recovered = try XCTUnwrap(TurnJournal.recover(from: root.appendingPathComponent("turn.jsonl")))
        XCTAssertEqual(recovered.backendSessionID, sessionID)
        XCTAssertEqual(recovered.reviews["read-1"]?.outcome, .allow)
        XCTAssertEqual(recovered.reviews["read-1"]?.risk, .low)
        XCTAssertEqual(recovered.history, history)
        XCTAssertFalse(recovered.interrupted)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("flushed.txt")), "saved", "Wait for Claude Code to flush its session after stdin closes")
        XCTAssertEqual(activities.last?.status, .completed)
    }

    func testClaudeToolBridgeContinuesPastSixteenCallsAndReviewsEachOnce() async throws {
        let (root, executable) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let journalURL = root.appendingPathComponent("long-turn.jsonl")
        let harness = AgentHarness(reviewer: FixtureToolSafetyReviewer(.init(risk: .low, reason: "Read fixture")))
        let history = try await harness.run(configuration: configuration, messages: [.init(role: "user", text: "LONG_RUN_FIXTURE")],
            files: WorkspaceFiles(root: root, checkpointDirectory: root.appendingPathComponent("checkpoints")), project: root.path,
            journal: TurnJournal(url: journalURL), claudeExecutable: executable)
        XCTAssertEqual(history.last?.text, "Done")
        let results = history.filter { $0.role == "tool" }
        XCTAssertEqual(results.map(\.toolCallID), (1...32).map { Optional("read-\($0)") })
        XCTAssertTrue(results.allSatisfy { $0.text == "Fixture contents" })
        let recovered = try XCTUnwrap(TurnJournal.recover(from: journalURL))
        XCTAssertEqual(recovered.reviews.count, 32)
        XCTAssertEqual(recovered.history, history)
        XCTAssertFalse(recovered.interrupted)
    }

    func testOfficialSignInSupportsPastingCodeIntoItsNativeTerminal() async throws {
        let (root, executable) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let connection = ClaudeCodeConnection(executable: executable)
        let task = Task { try await connection.signIn() }
        for _ in 0..<200 {
            if connection.loginTerminal.output.contains("Paste sign-in code") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(connection.isSigningIn)
        XCTAssertTrue(connection.loginTerminal.output.contains("Paste sign-in code"))
        connection.loginTerminal.send("fixture-code\n")
        try await task.value
        XCTAssertFalse(connection.isSigningIn)
        XCTAssertTrue(connection.isConnected, connection.error ?? "")
    }

    func testResumedCallsWithTheSameArgumentsKeepTheirOwnIdentityAndResult() async throws {
        let (root, executable) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let harness = AgentHarness(reviewer: FixtureToolSafetyReviewer()), files = WorkspaceFiles(root: root, checkpointDirectory: root.appendingPathComponent("checkpoints"))
        var sessionID: String?
        harness.onEvent = { if case .backendSession(let id) = $0 { sessionID = id } }
        let first = try await harness.run(configuration: configuration, messages: [.init(role: "user", text: "Read")], files: files, project: root.path, claudeExecutable: executable)
        let second = try await harness.run(configuration: configuration, messages: first + [.init(role: "user", text: "Read again")], files: files, project: root.path,
            claudeExecutable: executable, claudeSessionID: try XCTUnwrap(sessionID))
        XCTAssertEqual(second.filter { $0.role == "tool" }.map(\.toolCallID), ["read-1", "read-2"])
        XCTAssertTrue(second.filter { $0.role == "tool" }.allSatisfy { $0.text == "Fixture contents" })
        XCTAssertEqual(ConversationHistory.repaired(second), second)
    }

    func testDeniedReviewCannotExecuteAndCancellationInterruptsPendingReview() async throws {
        let (root, executable) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let counter = ClaudeToolCounter(), definition = ToolDefinition(name: "read_file", description: "Read", parameters: [:])
        let registry = ToolRegistry(definitions: [definition], review: { _, _ in
            .unavailable("Risk scoring failed")
        }, perform: { _ in await counter.run() })
        let history = try await ClaudeCodeRuntime().run(executable: executable, runID: UUID(), resume: nil, messages: [.init(role: "user", text: "Read")], system: "Bob", model: "sonnet", effort: nil, project: root.path, tools: registry, journal: nil) { _ in }
        XCTAssertEqual(history.last?.text, "Denied")
        let count = await counter.calls
        XCTAssertEqual(count, 0)
        let began = expectation(description: "Review started")
        let waiting = ToolRegistry(definitions: [definition], review: { _, _ in
            began.fulfill(); try await Task.sleep(for: .seconds(10))
            return .init(risk: .low, reason: "Late result")
        }, perform: { _ in await counter.run() })
        let task = Task {
            try await ClaudeCodeRuntime().run(executable: executable, runID: UUID(), resume: nil, messages: [.init(role: "user", text: "Read")], system: "Bob", model: "sonnet", effort: nil, project: root.path, tools: waiting, journal: nil) { _ in }
        }
        await fulfillment(of: [began], timeout: 3)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        let after = await counter.calls
        XCTAssertEqual(after, 0)
    }

    func testOlderProviderSettingsAndSessionsStillDecode() throws {
        let old = #"{"baseURL":"http://localhost/v1","apiModel":"","openAIModel":"","chatGPTModel":"","claudeModel":"claude-opus-4-6"}"#
        let settings = try JSONDecoder().decode(ProviderSettings.self, from: Data(old.utf8))
        XCTAssertEqual(settings[.claude], "claude-opus-4-6")
        XCTAssertEqual(settings[.claudeCode], "")
    }

    func testSteeringInterruptsGenerationAndContinuesInsideTheSameClaudeProcessAndSession() async throws {
        let (root, executable) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let input = AgentInput(), harness = AgentHarness(reviewer: FixtureToolSafetyReviewer())
        let journalURL = root.appendingPathComponent("steering.jsonl"), journal = TurnJournal(url: root.appendingPathComponent("steering.jsonl"))
        var applied = 0, text = "", sessionIDs: [String] = []
        harness.onEvent = { event in
            switch event {
            case .text(let value):
                text += value
                if value == "Original work" {
                    input.send("Focus on the parser"); input.send("Do not edit files")
                    harness.steer()
                }
            case .steered: applied += 1
            case .backendSession(let id): sessionIDs.append(id)
            default: break
            }
        }
        let history = try await harness.run(configuration: configuration, messages: [.init(role: "user", text: "STEERING_FIXTURE")],
            files: WorkspaceFiles(root: root, checkpointDirectory: root.appendingPathComponent("checkpoints")), project: root.path,
            journal: journal, claudeExecutable: executable, input: input)
        XCTAssertEqual(applied, 1)
        XCTAssertEqual(sessionIDs.count, 1)
        XCTAssertEqual(history.filter { $0.role == "user" }.map(\.text), ["STEERING_FIXTURE", "Focus on the parser", "Do not edit files"])
        XCTAssertEqual(history.last?.text, "Following the updated direction")
        XCTAssertEqual(text, "Original workFollowing the updated direction")
        XCTAssertEqual(ConversationHistory.repaired(history), history)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("old.txt").path))
        XCTAssertEqual(try TurnJournal.recover(from: journalURL)?.history, history)
    }

    func testLiveSubscriptionUsesReviewedBobToolsAndResumesTheSameSession() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["BOB_CLAUDE_EXECUTABLE"] else { throw XCTSkip("Set BOB_CLAUDE_EXECUTABLE to verify subscription inference.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-claude-live-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let code = "verified-" + UUID().uuidString
        try code.write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let reviewer: any ToolSafetyReviewing
        var decision: LocalDecisionModel?
        if let exe = env["BOB_CLEF_EXECUTABLE"], let model = env["BOB_CLEF_MODEL_DIRECTORY"] {
            let local = LocalDecisionModel(executable: URL(fileURLWithPath: exe), modelDirectory: URL(fileURLWithPath: model))
            decision = local; reviewer = ClefToolSafetyReviewer(model: local)
        } else { reviewer = FixtureToolSafetyReviewer(.init(risk: .low, reason: "Fixture")) }
        defer { decision?.unload() }
        let harness = AgentHarness(reviewer: reviewer), files = WorkspaceFiles(root: root, checkpointDirectory: root.appendingPathComponent("checkpoints"))
        var sessionID: String?, approvals = 0, reads = 0
        harness.onEvent = { event in
            if case .backendSession(let id) = event { sessionID = id }
            if case .approval(let request?) = event { approvals += 1; request.resolve(false) }
            if case .tool(let activity) = event, activity.status == .completed, activity.call.name == "read_file" { reads += 1 }
        }
        let config = ModelConfiguration(provider: .claudeCode, model: "haiku", baseURL: "", token: "")
        let first = try await harness.run(configuration: config, messages: [.init(role: "user", text: "Call mcp__bob__read_file exactly once to read README.md. Reply with its complete contents only. Do not call other tools.")],
            files: files, project: root.path, claudeExecutable: URL(fileURLWithPath: path))
        XCTAssertTrue(first.last?.text.contains(code) == true, first.last?.text ?? "No reply")
        let id = try XCTUnwrap(sessionID)
        let second = try await harness.run(configuration: config, messages: first + [.init(role: "user", text: "What exact code did you just read? Reply with it only, without calling any tools.")],
            files: files, project: root.path, claudeExecutable: URL(fileURLWithPath: path), claudeSessionID: id)
        XCTAssertTrue(second.last?.text.contains(code) == true, second.last?.text ?? "No reply")
        XCTAssertEqual(sessionID, id)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(approvals, 0)
    }
}
