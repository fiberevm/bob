import SwiftUI
import BobCore

struct ActivityText: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .contentTransition(.opacity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: text)
    }
}

struct ToolStatusIndicator: View {
    let status: ToolActivity.Status
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            indicator.id(status).transition(.opacity)
        }
        .frame(width: 12, height: 12)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: status)
    }

    @ViewBuilder private var indicator: some View {
        switch status {
        case .running: ProgressView().controlSize(.mini)
        case .completed: Image(systemName: "checkmark").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.added)
        case .failed: Image(systemName: "circle.fill").font(.system(size: 4)).foregroundStyle(Theme.muted)
        case .declined, .cancelled: Image(systemName: "minus.circle").font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
    }
}
