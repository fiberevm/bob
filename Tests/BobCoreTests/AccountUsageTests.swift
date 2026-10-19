import XCTest
import AppKit
import SwiftUI
@testable import Bob
@testable import BobCore

final class AccountUsageTests: XCTestCase {
    func testReportedWindowsUseRemainingPercentAndRealDurations() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let snapshot = AccountUsageSnapshot.decode([
            "rateLimits": ["primary": ["usedPercent": 99]],
            "rateLimitsByLimitId": ["codex": [
                "primary": ["usedPercent": 27.5, "windowDurationMins": 300, "resetsAt": 2000],
                "secondary": ["usedPercent": 62, "windowDurationMins": 10080, "resetsAt": 3000]
            ]]
        ], email: "fixture@example.com", planType: "pro", at: now)
        XCTAssertEqual(snapshot.buckets.count, 1)
        let windows = snapshot.buckets[0].windows
        XCTAssertEqual(windows.map(\.title), ["5 hours", "This week"])
        XCTAssertEqual(windows[0].remainingPercent(at: now), 72.5)
        XCTAssertEqual(windows[1].remainingPercent(at: now), 38)
        XCTAssertNil(windows[1].remainingPercent(at: Date(timeIntervalSince1970: 3000)))
        XCTAssertEqual(snapshot.planType, "pro")
        XCTAssertEqual(try JSONDecoder().decode(AccountUsageSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
    }

    func testLegacyMissingAndExhaustedLimitsAreNotInvented() {
        let snapshot = AccountUsageSnapshot.decode(["rateLimits": ["planType": "plus", "primary": ["usedPercent": 150], "secondary": ["windowDurationMins": 10080]]], email: "fixture@example.com", planType: nil)
        XCTAssertEqual(snapshot.planType, "plus")
        XCTAssertEqual(snapshot.buckets[0].windows[0].remainingPercent(), 0)
        XCTAssertNil(snapshot.buckets[0].windows[1].remainingPercent())
        XCTAssertTrue(AccountUsageSnapshot.decode([:], email: "fixture@example.com", planType: nil).buckets.isEmpty)
        let invalid = AccountUsageSnapshot.decode(["rateLimits": ["primary": ["usedPercent": -1, "resetsAt": 0, "windowDurationMins": -1]]], email: "fixture@example.com", planType: nil)
        XCTAssertNil(invalid.buckets[0].windows[0].remainingPercent())
        XCTAssertNil(invalid.buckets[0].windows[0].resetsAt)
        XCTAssertNil(invalid.buckets[0].windows[0].windowDurationMins)
    }

    private func fixture(email: String = "fixture@example.com", mode: String = "success") throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bob-usage-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("codex-fixture")
        let script = #"""
        #!/usr/bin/env python3
        import json,sys,os,time
        root=os.path.dirname(__file__)
        config=json.load(open(os.path.join(root,'config.json')))
        assert sys.argv[1:]==['app-server','--listen','stdio://']
        assert not any(k in os.environ for k in ['OPENAI_API_KEY','CODEX_API_KEY','OPENAI_BASE_URL'])
        for line in sys.stdin:
            req=json.loads(line)
            method=req['method']
            with open(os.path.join(root,'requests.log'),'a') as log: log.write(method+'\n')
            if method=='initialized': continue
            if method=='initialize': result={}
            elif method=='account/read':
                assert req['params']=={'refreshToken':False}
                result={'account':None if config['mode']=='signedOut' else {'type':'chatgpt','email':config['email'],'planType':'pro'}}
            elif method=='account/rateLimits/read':
                if config['mode']=='hang': time.sleep(60)
                if config['mode']=='error':
                    print(json.dumps({'id':req['id'],'error':{'message':'private diagnostic'}}),flush=True)
                    continue
                result={'rateLimitsByLimitId':{'codex':{'primary':{'usedPercent':12,'windowDurationMins':300,'resetsAt':int(time.time())+1000},'secondary':{'usedPercent':34,'windowDurationMins':10080,'resetsAt':int(time.time())+5000}}}}
            else: raise Exception('Unexpected method '+method)
            print(json.dumps({'method':'account/updated','params':{}}),flush=True)
            print(json.dumps({'id':req['id'],'result':result}),flush=True)
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: ["email": email, "mode": mode]).write(to: root.appendingPathComponent("config.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (root, executable)
    }

    func testReadsOnlyAccountAndLimitsThroughInstalledProtocol() async throws {
        let (root, executable) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let result = try await AccountUsageClient(executable: executable).read(expectedEmail: " FIXTURE@example.com ")
        XCTAssertEqual(result.email, "fixture@example.com")
        XCTAssertEqual(result.buckets[0].windows.map { $0.remainingPercent() }, [88, 66])
        let requests = try String(contentsOf: root.appendingPathComponent("requests.log"), encoding: .utf8)
        XCTAssertEqual(requests, "initialize\ninitialized\naccount/read\naccount/rateLimits/read\n")
    }

    func testDifferentAccountDoesNotRequestOrExposeItsUsage() async throws {
        let (root, executable) = try fixture(email: "someone-else@example.com"); defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await AccountUsageClient(executable: executable).read(expectedEmail: "fixture@example.com")
            XCTFail("A different account's limits were accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("different account"))
            XCTAssertFalse(error.localizedDescription.contains("someone-else"))
        }
        let requests = try String(contentsOf: root.appendingPathComponent("requests.log"), encoding: .utf8)
        XCTAssertFalse(requests.contains("account/rateLimits/read"))
    }

    func testSignedOutAndServiceFailureStayUnavailable() async throws {
        for mode in ["signedOut", "error"] {
            let (root, executable) = try fixture(mode: mode); defer { try? FileManager.default.removeItem(at: root) }
            do {
                _ = try await AccountUsageClient(executable: executable).read(expectedEmail: "fixture@example.com")
                XCTFail("An unavailable limit was accepted")
            } catch { XCTAssertFalse(error.localizedDescription.contains("private diagnostic")) }
        }
    }

    func testTimeoutTerminatesTheRead() async throws {
        let (root, executable) = try fixture(mode: "hang"); defer { try? FileManager.default.removeItem(at: root) }
        let start = Date()
        do {
            _ = try await AccountUsageClient(executable: executable, timeout: 0.3).read(expectedEmail: "fixture@example.com")
            XCTFail("An unresponsive process did not time out")
        } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testLiveUsageMatchesBobSelectedAccount() async throws {
        guard ProcessInfo.processInfo.environment["BOB_LIVE_ACCOUNT_USAGE"] == "1" else { throw XCTSkip("Set BOB_LIVE_ACCOUNT_USAGE=1 to read the signed-in account's live limits.") }
        let defaults = UserDefaults(suiteName: "com.bob.native")!
        let data = try XCTUnwrap(defaults.data(forKey: "chatgpt.accounts"))
        let accounts = try JSONDecoder().decode([ChatGPTAccount].self, from: data)
        let account = try XCTUnwrap(accounts.first { $0.id == defaults.string(forKey: "chatgpt.active") })
        let result = try await AccountUsageClient(executable: XCTUnwrap(ExecutableLocator.find("codex"))).read(expectedEmail: account.email)
        XCTAssertEqual(result.email.lowercased(), account.email.lowercased())
        XCTAssertFalse(result.buckets.isEmpty)
        print("Verified matching live account: \(result.buckets.flatMap(\.windows).map(\.title).joined(separator: ", ")) quota windows returned.")
    }
}

private actor UsageRequestFixture {
    private(set) var calls: [String] = []
    private var pending: [String: CheckedContinuation<AccountUsageSnapshot, Error>] = [:]
    func read(_ email: String) async throws -> AccountUsageSnapshot {
        calls.append(email)
        return try await withCheckedThrowingContinuation { pending[email] = $0 }
    }
    func complete(_ email: String, fail: Bool = false) {
        let continuation = pending.removeValue(forKey: email)
        if fail { continuation?.resume(throwing: BobError.message("Offline")) }
        else { continuation?.resume(returning: AccountUsageSnapshot.decode(["rateLimits": ["primary": ["usedPercent": 12]]], email: email, planType: "pro")) }
    }
}

@MainActor final class AccountUsageStoreTests: XCTestCase {
    private func account(_ id: String) -> ChatGPTAccount { ChatGPTAccount(clientID: id, subject: id, email: id + "@example.com") }
    private func waitForCalls(_ count: Int, on fixture: UsageRequestFixture) async throws {
        for _ in 0..<200 {
            if await fixture.calls.count >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Usage read did not start")
    }

    func testCoalescesReadsCachesAndRetainsLastSampleOnFailure() async throws {
        let fixture = UsageRequestFixture(), account = account("first")
        let store = AccountUsageStore { try await fixture.read($0) }
        let first = Task { await store.refresh(account: account) }
        try await waitForCalls(1, on: fixture)
        let second = Task { await store.refresh(account: account) }
        await fixture.complete(account.email)
        await first.value; await second.value
        await store.refresh(account: account)
        let count = await fixture.calls.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.snapshot?.email, account.email)
        let refresh = Task { await store.refresh(account: account, force: true) }
        try await waitForCalls(2, on: fixture)
        await fixture.complete(account.email, fail: true)
        await refresh.value
        XCTAssertEqual(store.error, "Offline")
        XCTAssertEqual(store.snapshot?.email, account.email)
        XCTAssertFalse(store.isRefreshing)
    }

    func testAccountSwitchDiscardsLateResponseAndSignOutClearsDetails() async throws {
        let fixture = UsageRequestFixture(), first = account("first"), second = account("second")
        let store = AccountUsageStore { try await fixture.read($0) }
        let old = Task { await store.refresh(account: first) }
        try await waitForCalls(1, on: fixture)
        let new = Task { await store.refresh(account: second) }
        try await waitForCalls(2, on: fixture)
        XCTAssertNil(store.snapshot)
        await fixture.complete(second.email)
        await new.value
        await fixture.complete(first.email)
        await old.value
        XCTAssertEqual(store.snapshot?.email, second.email)
        await store.refresh(account: nil)
        XCTAssertNil(store.snapshot)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.isRefreshing)
    }

    func testUsagePopoverHasRoomForQuotaAndSessionDetails() async throws {
        _ = NSApplication.shared
        let suite = "bob-usage-view-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let account = account("fixture")
        defaults.set(try JSONEncoder().encode([account]), forKey: "chatgpt.accounts")
        defaults.set(account.id, forKey: "chatgpt.active")
        let snapshot = AccountUsageSnapshot.decode(["rateLimits": ["limitId": "codex", "primary": ["usedPercent": 22, "windowDurationMins": 300, "resetsAt": Date().addingTimeInterval(1000).timeIntervalSince1970], "secondary": ["usedPercent": 38, "windowDurationMins": 10080, "resetsAt": Date().addingTimeInterval(100000).timeIntervalSince1970]]], email: account.email, planType: "pro")
        let usage = AccountUsageStore { _ in snapshot }
        let connections = ConnectionPreferences(defaults: defaults, usage: usage)
        let store = AppStore(storageDirectory: root, connections: connections)
        defer { store.shutdown() }
        store.sessions = [Session(projectPath: "")]
        store.selectedID = store.sessions[0].id
        store.setModel("gpt-fixture")
        await usage.refresh(account: account)
        let host = NSHostingView(rootView: UsagePopover(store: store, connect: {}))
        let size = host.fittingSize
        XCTAssertEqual(size.width, 350, accuracy: 1)
        XCTAssertEqual(size.height, 520, accuracy: 1)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        host.layoutSubtreeIfNeeded()
        if let path = ProcessInfo.processInfo.environment["BOB_USAGE_PREVIEW"] {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
    }
}
