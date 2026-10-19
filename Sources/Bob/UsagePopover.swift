import SwiftUI
import BobCore

struct UsagePopover: View {
    @ObservedObject var store: AppStore
    @ObservedObject var usage: AccountUsageStore
    let connect: () -> Void

    init(store: AppStore, connect: @escaping () -> Void) {
        self.store = store; self.usage = store.connections.usage; self.connect = connect
    }

    private var account: ChatGPTAccount? { store.selectedProvider == .chatgpt ? store.auth.selected : nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Usage", systemImage: "chart.bar").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if account != nil {
                        if usage.isRefreshing { ProgressView().controlSize(.mini) }
                        Button {
                            Task { await usage.refresh(account: account, force: true) }
                        } label: { Image(systemName: "arrow.clockwise") }
                            .disabled(usage.isRefreshing).help("Refresh usage").accessibilityLabel("Refresh usage")
                    }
                }
                if let account {
                    Text(account.email).foregroundStyle(Theme.secondary).textSelection(.enabled)
                    if let snapshot = usage.snapshot {
                        ForEach(snapshot.buckets) { bucket in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(bucket.name ?? bucket.id.replacingOccurrences(of: "_", with: " ").capitalized)
                                    .fontWeight(.medium)
                                ForEach(Array(bucket.windows.enumerated()), id: \.offset) { _, window in
                                    UsageWindowView(window: window, isStale: usage.error != nil)
                                }
                                if bucket.windows.isEmpty { Text("No percentage limits reported.").foregroundStyle(Theme.secondary) }
                            }
                        }
                        if snapshot.buckets.isEmpty { Text("The account service did not report percentage limits.").foregroundStyle(Theme.secondary) }
                        Text("Updated \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 10)).foregroundStyle(Theme.secondary)
                    } else if usage.isRefreshing {
                        Text("Loading account limits…").foregroundStyle(Theme.secondary)
                    }
                    if let error = usage.error { Text(error).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true) }
                    Text("Limits are reported by the local Codex sign-in with this email. Its workspace and Bob's app allowance can differ.")
                        .font(.system(size: 10)).foregroundStyle(Theme.secondary)
                    Link("Manage usage and app allowance", destination: URL(string: "https://chatgpt.com/settings/usage")!)
                } else if store.selectedProvider == .chatgpt {
                    Text("Connect your account to view usage.").foregroundStyle(Theme.secondary)
                    Button("Connect account", action: connect)
                }

            }.padding(18)
        }.frame(width: 350, height: account != nil ? 400 : 160)
            .font(.system(size: 11)).foregroundStyle(Theme.text).background(Theme.panel)
            .buttonStyle(.borderless).tint(Theme.accent)
            .task(id: account?.id) {
                guard let account else { return }
                while !Task.isCancelled {
                    await usage.refresh(account: account)
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                }
            }
    }
}

private struct UsageWindowView: View {
    let window: AccountUsageWindow
    let isStale: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(window.title)
                    Spacer()
                    if let remaining = window.remainingPercent(at: timeline.date) {
                        Text("\(remaining.formatted(.number.precision(.fractionLength(0...1))))% left\(isStale ? " · last reported" : "")")
                            .monospacedDigit().fontWeight(.medium)
                    } else { Text("Awaiting update").foregroundStyle(Theme.secondary) }
                }
                if let remaining = window.remainingPercent(at: timeline.date) {
                    ProgressView(value: remaining, total: 100)
                        .tint(remaining <= 15 ? Theme.removed : Theme.accent)
                        .accessibilityLabel("\(window.title) remaining")
                }
                if let reset = window.resetsAt {
                    Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 10)).foregroundStyle(Theme.secondary)
                }
            }
        }
    }
}
