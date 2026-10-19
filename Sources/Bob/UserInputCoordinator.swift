import Foundation
import Combine
import BobCore

@MainActor final class UserInputDraft: ObservableObject {
    @Published var index = 0
    @Published var choices: [String: String] = [:]
    @Published var other = Set<String>()
    @Published var custom: [String: String] = [:]
}

struct UserInputRequest: Identifiable {
    let id: UUID
    let runID: UUID
    let callID: String
    let questions: UserInputQuestions
    let draft: UserInputDraft
    let resolve: ([String: String]) -> Void
    let cancel: () -> Void
}

/// Main-actor ownership and identity checks prevent late UI callbacks from answering another request.
@MainActor final class UserInputCoordinator {
    private var pending: (id: UUID, continuation: CheckedContinuation<UserInputResponse?, Never>)?
    let runID: UUID
    let emit: (UserInputRequest?) -> Void
    let answered: (String) -> Void

    init(runID: UUID, emit: @escaping (UserInputRequest?) -> Void, answered: @escaping (String) -> Void = { _ in }) {
        self.runID = runID; self.emit = emit; self.answered = answered
    }

    func request(callID: String, questions: UserInputQuestions) async throws -> UserInputResponse? {
        try questions.validate()
        let id = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, pending == nil else { continuation.resume(returning: nil); return }
                pending = (id, continuation)
                emit(UserInputRequest(id: id, runID: runID, callID: callID, questions: questions, draft: UserInputDraft(), resolve: { [weak self] values in
                    guard let self, self.pending?.id == id, let response = try? questions.response(values) else { return }
                    self.answered(questions.transcript(response))
                    self.finish(id: id, response: response)
                }, cancel: { [weak self] in self?.finish(id: id, response: nil) }))
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.finish(id: id, response: nil) } })
    }

    private func finish(id: UUID, response: UserInputResponse?) {
        guard let current = pending, current.id == id else { return }
        pending = nil
        emit(nil)
        current.continuation.resume(returning: response)
    }
    func cancel() { if let current = pending { finish(id: current.id, response: nil) } }
}
