import Foundation

public enum ChatTranscript {
    public enum Item: Identifiable, Equatable {
        case message(Message)
        case tools(ToolActivityGroup)
        public var id: UUID {
            switch self {
            case .message(let message): return message.id
            case .tools(let group): return group.id
            }
        }
    }

    /// Adjacent calls share a row, including across empty assistant placeholders.
    /// The first call's message ID keeps the group's disclosure stable as it grows.
    public static func items(from messages: [Message]) -> [Item] {
        var items: [Item] = []
        for message in messages {
            if let tool = message.tool {
                if case .tools(var group)? = items.last {
                    group.tools.append(tool)
                    items[items.count - 1] = .tools(group)
                } else { items.append(.tools(ToolActivityGroup(id: message.id, tools: [tool]))) }
            } else if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                items.append(.message(message))
            }
        }
        return items
    }

    /// Rebuild only the latest turn from its durable journal, without replaying tools.
    public static func recoveredMessages(history: [ModelMessage], runID: UUID, reviews: [String: ToolSafetyAssessment] = [:], delegatedTools: [ToolActivity] = [], startingAfter userMessageID: UUID? = nil) -> [Message] {
        let user = userMessageID.flatMap { id in history.firstIndex { $0.userMessageID == id } }
            ?? history.lastIndex(where: { $0.role == "user" }) ?? -1
        let turn = Array(history.dropFirst(user + 1))
        var messages = [Message(role: .assistant, text: "", id: runID)]
        for model in turn {
            if model.role == "user" {
                messages.append(Message(role: .user, text: model.text, id: model.userMessageID ?? UUID(), isSteering: true))
                continue
            }
            guard model.role == "assistant" else { continue }
            if !model.text.isEmpty {
                if messages.count == 1 { messages[0].text = model.text }
                else { messages.append(Message(role: .assistant, text: model.text)) }
            }
            for call in model.toolCalls {
                let output = turn.first { $0.role == "tool" && $0.toolCallID == call.id }?.text ?? "Aborted before execution."
                var activity = ToolActivity(call: call)
                activity.review = reviews[call.id]
                activity.finish(output: output, failed: output.hasPrefix("Tool error:"), cancelled: output.hasPrefix("Interrupted") || output.hasPrefix("Aborted"))
                messages.append(Message(role: .activity, text: "", tool: activity))
                if call.name == "request_user_input",
                   let request = try? JSONDecoder().decode(UserInputQuestions.self, from: Data(call.arguments.utf8)),
                   (try? request.validate()) != nil,
                   let response = try? JSONDecoder().decode(UserInputResponse.self, from: Data(output.utf8)),
                   response.answers.values.allSatisfy({ $0.answers.count == 1 }),
                   (try? request.response(response.answers.mapValues { $0.answers[0] })) != nil {
                    messages.append(Message(role: .user, text: request.transcript(response)))
                }
                for child in delegatedTools where child.parentCallID == call.id {
                    messages.append(Message(role: .activity, text: "", tool: child))
                }
            }
        }
        return messages
    }
}
