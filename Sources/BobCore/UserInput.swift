import Foundation

/// Codex-compatible request_user_input wire contract. The client always adds Other.
public struct UserInputQuestions: Codable, Equatable, Sendable {
    public struct Option: Codable, Equatable, Sendable {
        public let label: String
        public let description: String
    }
    public struct Question: Codable, Equatable, Sendable, Identifiable {
        public let id: String
        public let header: String
        public let question: String
        public let options: [Option]
    }
    public let questions: [Question]

    public func validate() throws {
        func present(_ text: String) -> Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard (1...3).contains(questions.count), Set(questions.map(\.id)).count == questions.count,
              questions.allSatisfy({ q in
                  present(q.id) && present(q.header) && present(q.question) && (2...3).contains(q.options.count)
                  && Set(q.options.map(\.label)).count == q.options.count
                  && q.options.allSatisfy { present($0.label) && present($0.description) }
              }) else { throw BobError.message("Provide 1–3 uniquely identified questions, each with 2–3 distinct choices and non-empty text.") }
    }

    public func response(_ values: [String: String]) throws -> UserInputResponse {
        guard Set(values.keys) == Set(questions.map(\.id)),
              values.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw BobError.message("Answer every question before submitting.")
        }
        return UserInputResponse(answers: values.mapValues { .init(answers: [$0]) })
    }

    public func transcript(_ response: UserInputResponse) -> String {
        questions.map { q in
            let answer = response.answers[q.id]?.answers.joined(separator: "\n") ?? ""
            let detail = q.options.first { $0.label == answer }.map { " — " + $0.description } ?? ""
            return "\(q.question)\n\(answer)\(detail)"
        }.joined(separator: "\n\n")
    }

    public static var definition: ToolDefinition {
        ToolDefinition(name: "request_user_input", description: "Ask the user 1–3 short questions and wait for their response. Use for meaningful choices or missing requirements, not facts you can inspect. Provide 2–3 mutually exclusive choices; put the recommended choice first with (Recommended) in its label. Never include Other; the UI adds free-form input. Do not request passwords or secrets. Answers do not bypass tool safety review.", parameters: [
            "type": "object", "properties": [
                "questions": ["type": "array", "minItems": 1, "maxItems": 3, "items": [
                    "type": "object", "properties": [
                        "id": ["type": "string", "description": "Stable snake_case answer identifier."],
                        "header": ["type": "string", "description": "Short header, ideally 12 or fewer characters."],
                        "question": ["type": "string"],
                        "options": ["type": "array", "minItems": 2, "maxItems": 3, "items": [
                            "type": "object", "properties": ["label": ["type": "string"], "description": ["type": "string"]],
                            "required": ["label", "description"], "additionalProperties": false
                        ]]
                    ], "required": ["id", "header", "question", "options"], "additionalProperties": false
                ]]
            ], "required": ["questions"], "additionalProperties": false
        ])
    }
}

public struct UserInputResponse: Codable, Equatable, Sendable {
    public struct Answer: Codable, Equatable, Sendable { public let answers: [String] }
    public let answers: [String: Answer]
}
