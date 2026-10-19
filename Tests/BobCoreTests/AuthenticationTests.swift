import XCTest
@testable import Bob

private final class OAuthFixtureProtocol: URLProtocol {
    static var errorBody = ""
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: "HTTP/1.1", headerFields: ["x-request-id": "request_fixture"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.errorBody.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class AuthenticationTests: XCTestCase {
    func testRegistrationSurvivesAnExchangeFailure() async throws {
        let suite = "bob-auth-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let auth = ChatGPTAuth(defaults: defaults)
        let clientID = try auth.retainRegistration(callback: ["client_id": "oaiapp_fixture"], requestedClientID: "dynamic_agent_client")
        XCTAssertEqual(clientID, "oaiapp_fixture")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OAuthFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        OAuthFixtureProtocol.errorBody = #"{"error":"invalid_grant"}"#
        do {
            _ = try await ChatGPTAuth.tokenRequest(["client_id": clientID, "code": "fixture-code"], session: session)
            XCTFail("An invalid grant was accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("invalid_grant"))
        }
        XCTAssertEqual(defaults.string(forKey: "chatgpt.pendingClientID"), clientID)
        let restarted = ChatGPTAuth(defaults: defaults)
        XCTAssertTrue(restarted.accounts.isEmpty)
        XCTAssertNil(restarted.selectedID)
        XCTAssertTrue(restarted.hasPendingRegistration)
        let retry = try restarted.authorizationParameters(for: .pendingRegistration, redirectURI: "http://127.0.0.1:1455/auth/callback", state: "fresh-state", nonce: "fresh-nonce", challenge: "fresh-challenge")
        XCTAssertEqual(retry["client_id"], clientID)
        XCTAssertNil(retry["agent_name_hint"])
        XCTAssertEqual(try restarted.retainRegistration(callback: [:], requestedClientID: clientID), clientID)
        XCTAssertThrowsError(try restarted.retainRegistration(callback: ["client_id": "oaiapp_different"], requestedClientID: clientID))
    }

    func testSwitchingAccountsDoesNotReuseThePendingWorkspace() throws {
        let suite = "bob-auth-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = ChatGPTAccount(clientID: "oaiapp_saved", subject: "saved-user", email: "saved@example.com")
        defaults.set(try JSONEncoder().encode([saved]), forKey: "chatgpt.accounts")
        defaults.set(saved.id, forKey: "chatgpt.active")
        let auth = ChatGPTAuth(defaults: defaults)
        _ = try auth.retainRegistration(callback: ["client_id": "oaiapp_other_workspace"], requestedClientID: "dynamic_agent_client")

        let fresh = try auth.authorizationParameters(for: .newAccount, redirectURI: "http://127.0.0.1:54321/auth/callback", state: "fresh-state", nonce: "fresh-nonce", challenge: "fresh-challenge")
        XCTAssertEqual(fresh["client_id"], "dynamic_agent_client")
        XCTAssertEqual(fresh["agent_name_hint"], "Bob")
        XCTAssertNil(fresh["login_hint"])
        XCTAssertEqual(fresh["redirect_uri"], "http://127.0.0.1:54321/auth/callback")
        XCTAssertEqual(fresh["state"], "fresh-state")
        XCTAssertEqual(fresh["nonce"], "fresh-nonce")
        XCTAssertEqual(fresh["code_challenge"], "fresh-challenge")
        XCTAssertEqual(fresh["code_challenge_method"], "S256")
        XCTAssertEqual(auth.selected, saved)
        XCTAssertEqual(auth.accounts, [saved])
        XCTAssertEqual(auth.pendingClientID, "oaiapp_other_workspace")

        let restarted = ChatGPTAuth(defaults: defaults)
        let returning = try restarted.authorizationParameters(for: .account(saved), redirectURI: "http://127.0.0.1:1455/auth/callback", state: "returning-state", nonce: "returning-nonce", challenge: "returning-challenge")
        XCTAssertEqual(returning["client_id"], saved.clientID)
        XCTAssertEqual(returning["login_hint"], saved.email)
        XCTAssertNil(returning["agent_name_hint"])
        XCTAssertEqual(returning["ext_agent_host_id"], fresh["ext_agent_host_id"])
    }

    func testRetryWithoutAPendingRegistrationDoesNotRegisterAnotherClient() {
        let suite = "bob-auth-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let auth = ChatGPTAuth(defaults: defaults)
        XCTAssertFalse(auth.hasPendingRegistration)
        XCTAssertThrowsError(try auth.authorizationParameters(for: .pendingRegistration, redirectURI: "http://127.0.0.1:1455/auth/callback", state: "state", nonce: "nonce", challenge: "challenge"))
    }

    func testOAuthErrorIncludesServerDetailAndRedactsSecrets() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OAuthFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        OAuthFixtureProtocol.errorBody = #"{"error":"invalid_grant","error_description":"PKCE verification failed for fixture-code"}"#
        do {
            _ = try await ChatGPTAuth.tokenRequest(["code": "fixture-code", "code_verifier": "fixture-verifier"], session: session)
            XCTFail("An invalid grant was accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("invalid_grant"))
            XCTAssertTrue(error.localizedDescription.contains("HTTP 400"))
            XCTAssertTrue(error.localizedDescription.contains("PKCE verification failed"))
            XCTAssertTrue(error.localizedDescription.contains("request_fixture"))
            XCTAssertFalse(error.localizedDescription.contains("fixture-code"))
        }
    }

    func testFormEncodingPreservesOAuthValues() {
        let encoded = String(decoding: ChatGPTAuth.form(["code": "a+b/c= .~"]), as: UTF8.self)
        XCTAssertEqual(encoded, "code=a%2Bb%2Fc%3D%20.~")
    }

    func testLoopbackCallbackReturnsValidatedCode() async throws {
        let callback = LoopbackCallback()
        defer { callback.cancel() }
        let redirect = try await callback.start()
        XCTAssertEqual(URL(string: redirect)?.host, "127.0.0.1")
        let result = Task { try await callback.result(expectedState: "expected-state") }
        var request = URLRequest(url: URL(string: redirect + "?code=fixture-code&state=expected-state&client_id=oaiapp_fixture")!)
        request.timeoutInterval = 5
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let values = try await result.value
        XCTAssertEqual(values["code"], "fixture-code")
        XCTAssertEqual(values["client_id"], "oaiapp_fixture")
    }
}
