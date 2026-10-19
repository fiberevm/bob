import AppKit
import CryptoKit
import Network
import Security
import BobCore

enum SecretStore {
    static func read(_ account: String) throws -> String {
        if ProcessInfo.processInfo.environment["BOB_NO_KEYCHAIN"] == "1" { return "" }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.bob.native", kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = value as? Data else { throw BobError.message("Could not read the macOS Keychain (\(status)).") }
        return String(decoding: data, as: UTF8.self)
    }
    static func write(_ value: String, account: String) throws {
        if ProcessInfo.processInfo.environment["BOB_NO_KEYCHAIN"] == "1" { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.bob.native", kSecAttrAccount as String: account]
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw BobError.message("Could not clear the Keychain item (\(status)).") }
            return
        }
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw BobError.message("Could not save to the macOS Keychain (\(status)).") }
    }
}

struct ChatGPTAccount: Codable, Identifiable, Hashable {
    var id: String { clientID }
    let clientID: String
    let subject: String
    let email: String
    var label: String { "\(email) · \(clientID.suffix(6))" }
}

struct OAuthTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var idToken: String
    var expiresAt: Date
    var scopes: [String]
}

@MainActor final class ChatGPTAuth: ObservableObject {
    enum SignInTarget {
        case newAccount
        case pendingRegistration
        case account(ChatGPTAccount)
    }
    @Published private(set) var accounts: [ChatGPTAccount] = []
    @Published var selectedID: String? { didSet { defaults.set(selectedID, forKey: "chatgpt.active") } }
    @Published private(set) var isSigningIn = false
    @Published private(set) var pendingClientID: String?
    private let defaults: UserDefaults
    private var listener: LoopbackCallback?
    private var refreshTasks: [String: Task<OAuthTokens, Error>] = [:]
    var selected: ChatGPTAccount? { accounts.first { $0.id == selectedID } }
    var hasPendingRegistration: Bool { pendingClientID != nil }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "chatgpt.accounts") { accounts = (try? JSONDecoder().decode([ChatGPTAccount].self, from: data)) ?? [] }
        selectedID = defaults.string(forKey: "chatgpt.active")
        pendingClientID = defaults.string(forKey: "chatgpt.pendingClientID")
    }
    private var hostID: String {
        if let existing = defaults.string(forKey: "chatgpt.host") { return existing }
        let id = "urn:uuid:\(UUID().uuidString.lowercased())"
        defaults.set(id, forKey: "chatgpt.host"); return id
    }
    func authorizationParameters(for target: SignInTarget, redirectURI: String, state: String, nonce: String, challenge: String) throws -> [String: String] {
        let clientID: String
        switch target {
        case .newAccount: clientID = "dynamic_agent_client"
        case .pendingRegistration:
            guard let pendingClientID else { throw BobError.message("There is no unfinished ChatGPT sign-in to retry.") }
            clientID = pendingClientID
        case .account(let account): clientID = account.clientID
        }
        var parameters = ["client_id": clientID, "ext_agent_host_id": hostID,
            "response_type": "code", "redirect_uri": redirectURI, "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
            "resource": "https://api.openai.com/v1", "state": state, "nonce": nonce,
            "code_challenge_method": "S256", "code_challenge": challenge]
        if case .newAccount = target { parameters["agent_name_hint"] = "Bob" }
        if case .account(let account) = target { parameters["login_hint"] = account.email }
        return parameters
    }
    func signIn(_ target: SignInTarget) async throws {
        guard !isSigningIn else { return }
        isSigningIn = true
        defer { isSigningIn = false; listener?.cancel(); listener = nil }
        let state = try Self.random(), nonce = try Self.random(), verifier = try Self.random()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let callback = LoopbackCallback(); listener = callback
        let redirect = try await callback.start()
        var parameters = try authorizationParameters(for: target, redirectURI: redirect, state: state, nonce: nonce, challenge: challenge)
        let requestedClientID = parameters["client_id"]!
        let existing: ChatGPTAccount?
        if case .account(let account) = target {
            existing = account
            if let tokens = try? load(account.id), !tokens.idToken.isEmpty { parameters["id_token_hint"] = tokens.idToken }
        } else { existing = nil }
        var components = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
        components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url, NSWorkspace.shared.open(url) else { throw BobError.message("Could not open the browser for ChatGPT sign-in.") }
        let values = try await callback.result(expectedState: state)
        if let error = values["error"] { throw BobError.message("ChatGPT sign-in: \(error)") }
        guard let code = values["code"] else { throw BobError.message("ChatGPT did not return an authorization code.") }
        let issuedID = try retainRegistration(callback: values, requestedClientID: requestedClientID)
        let tokens = try await Self.tokenRequest(["grant_type": "authorization_code", "client_id": issuedID,
            "code": code, "code_verifier": verifier, "redirect_uri": redirect, "resource": "https://api.openai.com/v1"])
        let claims = try await Self.validateIDToken(tokens.idToken, audience: issuedID, nonce: nonce)
        guard let subject = claims["sub"] as? String else { throw BobError.message("ChatGPT identity is missing its subject.") }
        guard existing == nil || existing?.subject == subject else { throw BobError.message("The signed-in account does not match the selected registration.") }
        guard tokens.scopes.contains("chatgpt.tokens.use.direct") else { throw BobError.message("ChatGPT plan access was not granted. Enable it during sign-in.") }
        let account = ChatGPTAccount(clientID: issuedID, subject: subject, email: claims["email"] as? String ?? "ChatGPT account")
        try save(tokens, account: issuedID)
        accounts.removeAll { $0.clientID == issuedID }; accounts.append(account)
        defaults.set(try JSONEncoder().encode(accounts), forKey: "chatgpt.accounts")
        if pendingClientID == issuedID {
            defaults.removeObject(forKey: "chatgpt.pendingClientID")
            pendingClientID = nil
        }
        selectedID = issuedID
    }
    /// Save the registration before exchanging the short-lived, single-use code.
    /// Retrying this sign-in reuses the client; switching accounts starts a new registration.
    func retainRegistration(callback: [String: String], requestedClientID: String) throws -> String {
        let supplied = callback["client_id"]
        if requestedClientID != "dynamic_agent_client" {
            guard supplied == nil || supplied == requestedClientID else { throw BobError.message("ChatGPT returned a different account registration.") }
            return requestedClientID
        }
        guard let supplied, supplied.hasPrefix("oaiapp_"), supplied.count > 7 else { throw BobError.message("ChatGPT registration did not return an issued client ID.") }
        defaults.set(supplied, forKey: "chatgpt.pendingClientID")
        pendingClientID = supplied
        return supplied
    }
    func cancelSignIn() { listener?.cancel() }
    func accessToken() async throws -> String {
        guard let account = selected else { throw BobError.message("Connect your ChatGPT account in Settings first.") }
        var tokens = try load(account.clientID)
        guard tokens.scopes.contains("chatgpt.tokens.use.direct") else { throw BobError.message("This ChatGPT account has not granted plan access.") }
        if tokens.expiresAt.timeIntervalSinceNow < 60 {
            let task: Task<OAuthTokens, Error>
            if let existing = refreshTasks[account.id] { task = existing }
            else {
                task = Task { try await Self.tokenRequest(["grant_type": "refresh_token", "client_id": account.clientID, "refresh_token": tokens.refreshToken, "resource": "https://api.openai.com/v1"], previous: tokens) }
                refreshTasks[account.id] = task
            }
            defer { refreshTasks[account.id] = nil }
            tokens = try await task.value
            try save(tokens, account: account.id)
        }
        return tokens.accessToken
    }
    func signOut() async throws {
        guard let account = selected else { return }
        let tokens = try load(account.id)
        var revocationError: Error?
        do {
            let (data, _) = try await URLSession.shared.data(from: URL(string: "https://auth.openai.com/.well-known/openid-configuration")!)
            let discovery = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let endpoint = discovery?["revocation_endpoint"] as? String, let url = URL(string: endpoint), url.scheme == "https", url.host == "auth.openai.com" else { throw BobError.message("The revocation endpoint is unavailable.") }
            var request = URLRequest(url: url); request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.form(["token": tokens.refreshToken, "token_type_hint": "refresh_token", "client_id": account.id])
            let (_, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw BobError.message("Remote session revocation was not confirmed.") }
        } catch { revocationError = error }
        try SecretStore.write("", account: "chatgpt.\(account.id)")
        selectedID = nil
        if revocationError != nil { throw BobError.message("Signed out locally. Remote revocation was not confirmed; disconnect Bob in ChatGPT Settings → Apps.") }
    }
    private func load(_ account: String) throws -> OAuthTokens {
        let value = try SecretStore.read("chatgpt.\(account)")
        guard let tokens = try? JSONDecoder().decode(OAuthTokens.self, from: Data(value.utf8)) else { throw BobError.message("This ChatGPT account needs to sign in again.") }
        return tokens
    }
    private func save(_ tokens: OAuthTokens, account: String) throws {
        try SecretStore.write(String(decoding: JSONEncoder().encode(tokens), as: UTF8.self), account: "chatgpt.\(account)")
    }
    static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(values.map { "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&").utf8)
    }
    static func tokenRequest(_ values: [String: String], previous: OAuthTokens? = nil, session: URLSession = .shared) async throws -> OAuthTokens {
        var request = URLRequest(url: URL(string: "https://auth.openai.com/api/accounts/oauth/token")!)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(values)
        let (data, response) = try await session.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 200, let access = object["access_token"] as? String else {
            let nested = object["error"] as? [String: Any]
            let code = object["error"] as? String ?? nested?["code"] as? String ?? "unknown_error"
            var detail = object["error_description"] as? String ?? nested?["message"] as? String ?? object["detail"] as? String ?? ""
            for key in ["code", "code_verifier", "refresh_token"] {
                if let secret = values[key], !secret.isEmpty { detail = detail.replacingOccurrences(of: secret, with: "[redacted]") }
            }
            let requestID = http?.value(forHTTPHeaderField: "x-request-id")
            let diagnostic = "ChatGPT authorization failed: \(code) (HTTP \(http?.statusCode ?? 0))." + (detail.isEmpty ? "" : " \(detail)") + (requestID.map { " Request ID: \($0)." } ?? "")
            throw BobError.message(diagnostic)
        }
        let scope = (object["scope"] as? String)?.split(separator: " ").map(String.init) ?? previous?.scopes ?? []
        return OAuthTokens(accessToken: access, refreshToken: object["refresh_token"] as? String ?? previous?.refreshToken ?? "",
            idToken: object["id_token"] as? String ?? previous?.idToken ?? "",
            expiresAt: Date().addingTimeInterval(object["expires_in"] as? Double ?? 3600), scopes: scope)
    }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw BobError.message("Could not generate secure sign-in parameters.") }
        return Data(bytes).base64URL
    }
    private static func validateIDToken(_ token: String, audience: String, nonce: String) async throws -> [String: Any] {
        let parts = token.split(separator: ".").map(String.init)
        guard parts.count == 3, let headerData = Data(base64URL: parts[0]), let payload = Data(base64URL: parts[1]), let signature = Data(base64URL: parts[2]),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any], let claims = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let kid = header["kid"] as? String else { throw BobError.message("Invalid ChatGPT identity token.") }
        let (data, response) = try await URLSession.shared.data(from: URL(string: "https://auth.openai.com/.well-known/jwks.json")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw BobError.message("Could not verify the ChatGPT identity.") }
        let keys = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["keys"] as? [[String: Any]] ?? []
        guard let jwk = keys.first(where: { $0["kid"] as? String == kid }) else { throw BobError.message("ChatGPT identity signing key was not found.") }
        let input = Data("\(parts[0]).\(parts[1])".utf8)
        var verified = false
        if header["alg"] as? String == "RS256", jwk["kty"] as? String == "RSA",
           let modulus = Data(base64URL: jwk["n"] as? String ?? ""), let exponent = Data(base64URL: jwk["e"] as? String ?? "") {
            func der(_ tag: UInt8, _ data: Data) -> Data {
                var length = Data()
                if data.count < 128 { length.append(UInt8(data.count)) }
                else {
                    var count = data.count, bytes: [UInt8] = []
                    while count > 0 { bytes.insert(UInt8(count & 255), at: 0); count >>= 8 }
                    length.append(0x80 | UInt8(bytes.count)); length.append(contentsOf: bytes)
                }
                return Data([tag]) + length + data
            }
            func integer(_ data: Data) -> Data { der(0x02, (data.first ?? 0) >= 128 ? Data([0]) + data : data) }
            let keyData = der(0x30, integer(modulus) + integer(exponent))
            let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
            if let key = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, nil) {
                verified = SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, input as CFData, signature as CFData, nil)
            }
        } else if header["alg"] as? String == "ES256", jwk["kty"] as? String == "EC", jwk["crv"] as? String == "P-256",
                  let x = Data(base64URL: jwk["x"] as? String ?? ""), let y = Data(base64URL: jwk["y"] as? String ?? "") {
            let key = try P256.Signing.PublicKey(x963Representation: Data([4]) + x + y)
            verified = key.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signature), for: input)
        }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard verified, claims["iss"] as? String == "https://auth.openai.com", audiences.contains(audience), claims["nonce"] as? String == nonce,
              let expiry = claims["exp"] as? Double, expiry > Date().timeIntervalSince1970 else { throw BobError.message("ChatGPT identity verification failed.") }
        return claims
    }
}

private extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init?(base64URL: String) {
        let text = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: text + String(repeating: "=", count: (4 - text.count % 4) % 4))
    }
}

@MainActor final class LoopbackCallback {
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<String, Error>?
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var expectedState = ""
    private var earlyURL: URL?
    private var cancelled = false
    func start() async throws -> String {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                connection.start(queue: .main)
                self?.read(connection, buffer: Data())
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, let continuation = self.startContinuation else { return }
                    switch state {
                    case .ready:
                        self.startContinuation = nil
                        continuation.resume(returning: "http://127.0.0.1:\(listener.port!.rawValue)/auth/callback")
                    case .failed(let error): self.startContinuation = nil; continuation.resume(throwing: error)
                    case .cancelled: self.startContinuation = nil; continuation.resume(throwing: CancellationError())
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
        }
    }
    func result(expectedState: String) async throws -> [String: String] {
        self.expectedState = expectedState
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            if cancelled { cancel() }
            else if let earlyURL { receive(earlyURL) }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(600))
                guard let self, self.continuation != nil else { return }
                self.continuation?.resume(throwing: BobError.message("ChatGPT sign-in timed out. Try again."))
                self.continuation = nil; self.listener?.cancel()
            }
        }
    }
    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
          Task { @MainActor in
            guard let self else { connection.cancel(); return }
            let buffer = buffer + (data ?? Data())
            guard buffer.count <= 16384 else { connection.cancel(); return }
            if let header = String(data: buffer, encoding: .utf8), header.contains("\r\n\r\n") {
                let request = header.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
                guard request.count >= 2, request[0] == "GET", let url = URL(string: "http://127.0.0.1\(request[1])"), url.path == "/auth/callback" else {
                    connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() }); return
                }
                let html = "<html><body style='font:18px system-ui;padding:48px'>You can return to Bob to finish connecting.</body></html>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Security-Policy: default-src 'none'; style-src 'unsafe-inline'\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                if self.continuation == nil { self.earlyURL = url } else { self.receive(url) }
            } else if !complete && error == nil { self.read(connection, buffer: buffer) }
            else { connection.cancel() }
          }
        }
    }
    private func receive(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count else { return }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard values["state"] == expectedState else { return }
        continuation?.resume(returning: values); continuation = nil; listener?.cancel()
    }
    func cancel() {
        cancelled = true; listener?.cancel(); continuation?.resume(throwing: CancellationError()); continuation = nil
    }
}
