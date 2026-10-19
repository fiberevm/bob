import Foundation
import CoreFoundation

public struct AccountUsageWindow: Codable, Equatable, Sendable {
    public let usedPercent: Double?
    public let windowDurationMins: Int?
    public let resetsAt: Date?

    public var title: String {
        switch windowDurationMins {
        case 10080: return "This week"
        case 1440: return "Today"
        case 60: return "1 hour"
        case let minutes? where minutes > 0 && minutes % 60 == 0: return "\(minutes / 60) hours"
        case let minutes? where minutes > 0: return "\(minutes) minutes"
        default: return "Usage window"
        }
    }
    public func remainingPercent(at date: Date = Date()) -> Double? {
        // A passed reset invalidates the sample; it does not prove a full refill.
        guard resetsAt.map({ $0 > date }) ?? true, let usedPercent else { return nil }
        return min(100, max(0, 100 - usedPercent))
    }
}

public struct AccountUsageBucket: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String?
    public let planType: String?
    public let windows: [AccountUsageWindow]
}

public struct AccountUsageSnapshot: Codable, Equatable, Sendable {
    public let email: String
    public let planType: String?
    public let buckets: [AccountUsageBucket]
    public let fetchedAt: Date

    public static func decode(_ result: [String: Any], email: String, planType: String?, at date: Date = Date()) -> Self {
        func window(_ value: Any?) -> AccountUsageWindow? {
            guard let object = value as? [String: Any] else { return nil }
            func number(_ value: Any?) -> Double? {
                guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
                return value.doubleValue
            }
            let percent = number(object["usedPercent"])
            let minutes = number(object["windowDurationMins"]).flatMap(Int.init(exactly:))
            let reset = number(object["resetsAt"])
            return AccountUsageWindow(usedPercent: percent.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
                                      windowDurationMins: minutes.flatMap { $0 > 0 ? $0 : nil },
                                      resetsAt: reset.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil })
        }
        func bucket(_ object: [String: Any], id: String) -> AccountUsageBucket {
            AccountUsageBucket(id: object["limitId"] as? String ?? id, name: object["limitName"] as? String,
                               planType: object["planType"] as? String,
                               windows: [window(object["primary"]), window(object["secondary"])].compactMap { $0 })
        }
        let buckets: [AccountUsageBucket]
        if let values = result["rateLimitsByLimitId"] as? [String: [String: Any]], !values.isEmpty {
            buckets = values.keys.sorted().map { bucket(values[$0]!, id: $0) }
        } else if let value = result["rateLimits"] as? [String: Any] {
            buckets = [bucket(value, id: "account")]
        } else { buckets = [] }
        return Self(email: email, planType: planType ?? buckets.compactMap(\.planType).first, buckets: buckets, fetchedAt: date)
    }
}

/// Reads the installed Codex client's account-status RPCs. No thread, inference,
/// login, credential export, or tool execution is requested by this connection.
public struct AccountUsageClient: Sendable {
    public let executable: URL
    public var timeout: TimeInterval = 25
    public init(executable: URL, timeout: TimeInterval = 25) { self.executable = executable; self.timeout = timeout }

    public func read(expectedEmail: String) async throws -> AccountUsageSnapshot {
        var environment = ExecutableLocator.environment
        for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "OPENAI_BASE_URL", "OPENAI_ORG_ID", "OPENAI_ORGANIZATION", "OPENAI_PROJECT_ID"] {
            environment.removeValue(forKey: key)
        }
        let process = try JSONLineProcess(executable: executable, arguments: ["app-server", "--listen", "stdio://"],
                                          directory: FileManager.default.homeDirectoryForCurrentUser, environment: environment)
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(timeout)) }
            catch { return }
            process.fail(AccountUsageError(message: "Usage refresh timed out. Try again."))
        }
        defer { deadline.cancel(); process.stop() }
        do { return try await withTaskCancellationHandler(operation: {
            try process.send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "bob", "title": "Bob Usage", "version": "1.0"]]])
            var email: String?, plan: String?
            for try await message in process.messages {
                try Task.checkCancellation()
                guard let id = message["id"] as? Int else { continue }
                guard message["error"] == nil else {
                    // Diagnostics may contain account metadata; keep the UI error bounded.
                    throw AccountUsageError(message: "The local Codex client could not read usage. Check its sign-in and try again.")
                }
                switch id {
                case 1:
                    try process.send(["method": "initialized"])
                    try process.send(["id": 2, "method": "account/read", "params": ["refreshToken": false]])
                case 2:
                    let result = message["result"] as? [String: Any]
                    guard let account = result?["account"] as? [String: Any], account["type"] as? String == "chatgpt",
                          let accountEmail = account["email"] as? String, !accountEmail.isEmpty else {
                        throw AccountUsageError(message: "Sign in to the local Codex client with this account to read its limits here.")
                    }
                    guard !expectedEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          accountEmail.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(expectedEmail.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame else {
                        throw AccountUsageError(message: "The local Codex client is signed in to a different account. Switch it to Bob's selected account, then refresh.")
                    }
                    email = accountEmail; plan = account["planType"] as? String
                    try process.send(["id": 3, "method": "account/rateLimits/read"])
                case 3:
                    guard let email, let result = message["result"] as? [String: Any] else {
                        throw AccountUsageError(message: "The account service returned incomplete usage details.")
                    }
                    return AccountUsageSnapshot.decode(result, email: email, planType: plan)
                default: break
                }
            }
            throw AccountUsageError(message: "The local Codex client stopped before returning usage.")
        }, onCancel: { process.stop() })
        } catch is CancellationError { throw CancellationError() }
        catch let error as AccountUsageError { throw error }
        catch { throw AccountUsageError(message: "Could not read usage from the local Codex client. Check its sign-in and try again.") }
    }
}

private struct AccountUsageError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
