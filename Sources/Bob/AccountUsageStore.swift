import Foundation
import Combine
import BobCore

@MainActor final class AccountUsageStore: ObservableObject {
    @Published private(set) var snapshot: AccountUsageSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var error: String?
    private var accountID: String?
    private var requestID = UUID()
    private var task: Task<Void, Never>?
    private let read: (String) async throws -> AccountUsageSnapshot

    init(read: ((String) async throws -> AccountUsageSnapshot)? = nil) {
        self.read = read ?? { email in
            guard let executable = ExecutableLocator.find("codex") else {
                throw BobError.message("Install and sign in to the Codex client to read account limits here.")
            }
            return try await AccountUsageClient(executable: executable).read(expectedEmail: email)
        }
    }

    func reset() {
        task?.cancel(); task = nil; requestID = UUID(); accountID = nil
        snapshot = nil; error = nil; isRefreshing = false
    }

    func refresh(account: ChatGPTAccount?, force: Bool = false) async {
        guard let account else { reset(); return }
        if accountID != account.id { reset(); accountID = account.id }
        if let task { await task.value; return }
        if !force, let snapshot, Date().timeIntervalSince(snapshot.fetchedAt) < 60,
           !snapshot.buckets.flatMap(\.windows).contains(where: { $0.resetsAt.map { $0 <= Date() } ?? false }) { return }
        let id = UUID(); requestID = id; isRefreshing = true; error = nil
        let read = self.read
        let request = Task { [weak self] in
            do {
                let result = try await read(account.email)
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                self.snapshot = result
            } catch {
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            guard let self, self.requestID == id else { return }
            self.isRefreshing = false; self.task = nil
        }
        task = request
        await request.value
    }
}
