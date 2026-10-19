import Foundation

/// Frames bytes before decoding, preserving Unicode split across pipe reads.
public struct JSONLineBuffer {
    private var buffer = Data()
    public init() {}
    public mutating func append(_ data: Data) throws -> [[String: Any]] {
        buffer.append(data)
        guard buffer.count <= 16 * 1024 * 1024 else {
            throw BobError.message("Agent output exceeded the 16 MB event limit.")
        }
        var messages: [[String: Any]] = []
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            if line.allSatisfy({ $0 == 13 || $0 == 32 }) { continue }
            guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw BobError.message("The agent returned an invalid JSON event.")
            }
            messages.append(object)
        }
        return messages
    }
}

public struct SSEParser {
    private var dataLines: [String] = []
    public init() {}
    public mutating func consume(line: String) -> String? {
        if line.isEmpty {
            guard !dataLines.isEmpty else { return nil }
            defer { dataLines.removeAll(keepingCapacity: true) }
            return dataLines.joined(separator: "\n")
        }
        if line.hasPrefix("data:") {
            var value = String(line.dropFirst(5))
            if value.first == " " { value.removeFirst() }
            dataLines.append(value)
        }
        return nil
    }
}

public enum CompatibleEndpoint {
    public static func url(base: String, resource: String) throws -> URL {
        guard let url = URL(string: base.trimmingCharacters(in: .whitespacesAndNewlines)),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.scheme == "https" || (components.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)) else {
            throw BobError.message("Use an HTTPS API base URL, or HTTP on localhost for a local model server. Include its API prefix, such as /v1.")
        }
        return url.appendingPathComponent(resource)
    }

    public static func delta(from payload: String) throws -> String? {
        if payload == "[DONE]" { return nil }
        guard let data = payload.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any] {
            throw BobError.message(error["message"] as? String ?? "The model server returned an error.")
        }
        let choices = object["choices"] as? [[String: Any]]
        return (choices?.first?["delta"] as? [String: Any])?["content"] as? String
    }
}
