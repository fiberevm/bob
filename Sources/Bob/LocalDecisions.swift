import Foundation
import BobCore

enum LocalDecisions {
    /// One worker is shared by every project window. Weights stay on disk until
    /// a caller makes a decision; model setup is explicit and separate.
    static let model: LocalDecisionModel? = {
        #if arch(arm64)
        guard #available(macOS 15, *),
              let configuration = Bundle.main.url(forResource: "DecisionModel", withExtension: "json"),
              let data = try? Data(contentsOf: configuration),
              let settings = try? JSONDecoder().decode(Configuration.self, from: data),
              let executable = Bundle.main.executableURL?.deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Helpers/BobDecision"),
              FileManager.default.isExecutableFile(atPath: executable.path),
              FileManager.default.fileExists(atPath: settings.modelDirectory + "/model.safetensors") else { return nil }
        return LocalDecisionModel(executable: executable, modelDirectory: URL(fileURLWithPath: settings.modelDirectory))
        #else
        return nil
        #endif
    }()
    private struct Configuration: Decodable { let modelDirectory: String }

    static var definitions: [ToolDefinition] {
        [ToolDefinition(name: "local_decide", description: "Score typed questions about a text state using local Clef-flash. Returns probabilities without generating text. Use for classification, routing, relevance, and ranking. Scores do not authorize actions or replace user approvals.", parameters: [
            "type": "object",
            "properties": [
                "state": ["type": "string", "description": "Complete text or JSON state to classify."],
                "max_tokens": ["type": "integer", "minimum": 1, "maximum": 16384, "description": "Total encoded token limit; defaults to 4096. Oversized states fail without truncation."],
                "questions": ["type": "array", "minItems": 1, "maxItems": 32, "items": [
                    "type": "object", "properties": [
                        "id": ["type": "string"],
                        "type": ["type": "string", "enum": ["choice", "noul", "score"]],
                        "instructions": ["type": "string"],
                        "choices": ["type": "object", "additionalProperties": ["type": "string"], "description": "Required for choice: option ID to description."],
                        "levels": ["type": "array", "items": ["type": "string"], "description": "Required for score: ordered criteria from lowest to highest."]
                    ], "required": ["id", "type", "instructions"], "additionalProperties": false
                ]]
            ], "required": ["state", "questions"], "additionalProperties": false
        ])]
    }
}
