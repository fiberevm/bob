import Foundation

public struct RetryPolicy {
    public let maxRetries: Int
    public let baseDelay: TimeInterval
    public let maximumServerDelay: TimeInterval
    let sleep: (TimeInterval) async throws -> Void
    public init(maxRetries: Int = 2, baseDelay: TimeInterval = 0.5, maximumServerDelay: TimeInterval = 60,
                sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.maxRetries = max(0, maxRetries); self.baseDelay = max(0, baseDelay)
        self.maximumServerDelay = maximumServerDelay; self.sleep = sleep
    }
    public static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value), seconds.isFinite { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }
    func delay(error: Error, attempt: Int) -> TimeInterval? {
        guard attempt < maxRetries else { return nil }
        if let failure = error as? ModelHTTPError {
            guard failure.retryable else { return nil }
            if let delay = failure.retryAfter { return delay <= maximumServerDelay ? delay : nil }
        } else if let url = error as? URLError {
            guard [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed].contains(url.code) else { return nil }
        } else if !(error is IncompleteModelStream) { return nil }
        return min(8, baseDelay * pow(2, Double(attempt)))
    }
}

struct ModelHTTPError: LocalizedError {
    let message: String
    let retryable: Bool
    let retryAfter: TimeInterval?
    var errorDescription: String? { message }
}
struct IncompleteModelStream: LocalizedError {
    var errorDescription: String? { "The connection ended before the model completed its response." }
}
