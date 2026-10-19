import SwiftUI
import BobCore

struct ChatView: View {
    @ObservedObject var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isComposerFocused: Bool
    @State private var flight: Message?
    @State private var bubbleFrames: [UUID: CGRect] = [:]
    @State private var isFlying = false
    @State private var flightTimeout: Task<Void, Never>?
    @State private var composerDockHeight: CGFloat = 76
    private let padding: CGFloat = 16
    private var canSend: Bool { !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && store.selected != nil }
    private var showsThinkingIndicator: Bool {
        guard store.isRunning, store.approval == nil else { return false }
        if store.activity == "Compacting context" { return true }
        guard let last = store.selected?.messages.last else { return true }
        if let tool = last.tool { return tool.status != .running }
        return last.role != .assistant || last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var body: some View {
        let transcript = ChatTranscript.items(from: store.selected?.messages ?? [])
        return GeometryReader { geometry in
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                FadingScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(transcript) { item in
                            switch item {
                            case .message(let message):
                                MessageView(message: message, auth: store.auth, userWidth: min(560, geometry.size.width * 0.78), hidesBubble: flight?.id == message.id)
                            case .tools(let group): ToolGroupView(group: group).transition(.opacity)
                            }
                        }
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: transcript.compactMap { item -> UUID? in
                            if case .tools(let group) = item { return group.id }
                            return nil
                        })
                        if showsThinkingIndicator {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.mini)
                                ActivityText(store.activity).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                                Spacer()
                            }.accessibilityElement(children: .combine).transition(.opacity)
                        }
                        Color.clear.frame(height: composerDockHeight + 1).id("bottom")
                    }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: showsThinkingIndicator)
                    // Read bubble geometry inside the scroll content, before
                    // its edge mask isolates preference propagation. Cache it
                    // even before a send notification so fast replies cannot
                    // lose the landing frame.
                    .onPreferenceChange(RenderedBubbleFrames.self) { frames in
                        bubbleFrames = frames
                    }
                    .padding(padding).frame(maxWidth: .infinity, alignment: .leading)
                }
                .anchorPreference(key: ChatAnchors.self, value: .bounds) { ChatAnchorValues(viewport: $0) }
                .onChange(of: store.selected?.messages.last(where: { $0.role == .assistant })?.text) { _, _ in scrollToBottom(proxy) }
                .onChange(of: store.selected?.messages.count) { _, _ in scrollToBottom(proxy) }
                .onChange(of: store.selectedID) { _, _ in scrollToBottom(proxy) }
                .onChange(of: showsThinkingIndicator) { _, _ in scrollToBottom(proxy) }
                .onChange(of: composerDockHeight) { _, _ in scrollToBottom(proxy) }
                .onChange(of: flight?.id) { _, _ in scrollToBottom(proxy, force: true) }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.background)
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    if let request = store.approval {
                        approvalCard(request).clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    composer
                }
                .padding(.horizontal, padding).padding(.top, 8).padding(.bottom, padding)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: ComposerDockHeight.self, value: proxy.size.height)
                    }.allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: "chat")
            .overlayPreferenceValue(ChatAnchors.self) { anchors in
                GeometryReader { geometry in
                    if let flight, let composer = anchors.composer {
                        let target = bubbleFrames[flight.id]
                        let viewport = anchors.viewport.map { geometry[$0] } ?? .zero
                        let visibleTarget = target.flatMap { target in
                            target.maxY <= viewport.maxY - composerDockHeight + 1 && target.maxY > viewport.minY ? target : nil
                        }
                        MessageFlightOverlay(message: flight, source: geometry[composer].insetBy(dx: -14, dy: 0), destination: visibleTarget, started: { id in
                            if self.flight?.id == id { isFlying = true }
                        }) { id in
                            guard self.flight?.id == id else { return }
                            finishFlight()
                        }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.allowsHitTesting(false).accessibilityHidden(true)
            }
            .onChange(of: store.selectedID) { _, _ in finishFlight() }
            .onChange(of: store.composerFocusRequest) { _, _ in isComposerFocused = true }
            .onPreferenceChange(ComposerDockHeight.self) { composerDockHeight = $0 }
            .onChange(of: store.lastSubmittedMessage?.id) { _, _ in
                guard store.lastSubmittedSessionID == store.selectedID, let message = store.lastSubmittedMessage else { return }
                beginFlight(message)
            }
            .onChange(of: reduceMotion) { _, reduced in if reduced { finishFlight() } }
            .onDisappear { finishFlight() }
            // Keep the split view and composer identity intact; only new chats reveal.
            .keyframeAnimator(initialValue: CGFloat(1), trigger: store.lastCreatedSessionID) { content, progress in
                content
                    .opacity(reduceMotion ? 1 : Double(progress))
                    .offset(y: reduceMotion ? 0 : (1 - progress) * 12)
            } keyframes: { _ in
                MoveKeyframe(CGFloat(0))
                CubicKeyframe(CGFloat(1), duration: 0.24)
            }
        }
    }
    private func submit() {
        guard canSend else { return }
        store.send()
    }
    private func beginFlight(_ message: Message) {
        guard !reduceMotion else { return }
        finishFlight()
        flight = message
        // A missing lazy-layout anchor must never leave a message hidden.
        flightTimeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            finishFlight()
        }
    }
    private func finishFlight() {
        flightTimeout?.cancel(); flightTimeout = nil
        flight = nil; isFlying = false
    }
    private func scrollToBottom(_ proxy: ScrollViewProxy, force: Bool = false) {
        // Keep the landing position steady while a fast response streams in.
        guard force || !isFlying else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { proxy.scrollTo("bottom", anchor: .bottom) }
    }
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("Message", text: $store.draft, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(1...8)
                .focused($isComposerFocused)
                .onSubmit { submit() }
                .frame(maxWidth: .infinity, minHeight: 32)
                .accessibilityLabel("Message to agent")
                .anchorPreference(key: ChatAnchors.self, value: .bounds) { ChatAnchorValues(composer: $0) }
            if store.isRunning {
                Button { store.stop() } label: { Image(systemName: "stop.fill").font(.system(size: 11)).frame(width: 32, height: 32) }
                    .buttonStyle(.plain).background(Theme.accent.opacity(0.15), in: Circle()).foregroundStyle(Theme.accent)
                    .accessibilityLabel("Stop agent").help("Stop Agent · ⌘.")
            }
            if !store.isRunning || canSend {
                Button { submit() } label: { Image(systemName: store.isRunning ? "arrow.turn.up.right" : "arrow.up").font(.system(size: 13, weight: .semibold)).frame(width: 32, height: 32) }
                    .buttonStyle(.plain).background(canSend ? Theme.accent : Theme.raised, in: Circle())
                    .foregroundStyle(canSend ? Theme.onAccent : Theme.muted)
                    .keyboardShortcut(.return, modifiers: .command).disabled(!canSend)
                    .accessibilityLabel(store.isRunning ? "Steer agent" : "Send message").help(store.isRunning ? "Steer current task · ⌘Return" : "Send · ⌘Return")
            }
        }.padding(.leading, 20).padding(.trailing, 10).padding(.vertical, 10)
            .foregroundStyle(Theme.text)
            .modifier(FloatingGlass(cornerRadius: 26))
    }
    private func approvalCard(_ request: ApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
            FadingScrollView { Text(request.detail).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 200)
            HStack {
                Spacer()
                Button("Decline") { request.resolve(false) }
                if let alwaysAllow = request.alwaysAllow { Button("Always allow app", action: alwaysAllow) }
                Button("Allow once") { request.resolve(true) }.buttonStyle(.borderedProminent).tint(Theme.action)
            }
        }.padding(padding).frame(maxWidth: .infinity, alignment: .leading).background(Theme.panel)
            .overlay(alignment: .top) { Theme.accent.opacity(0.3).frame(height: 1) }
    }
}

private struct MessageView: View {
    let message: Message
    let auth: ChatGPTAuth
    let userWidth: CGFloat
    var hidesBubble = false
    var body: some View {
        if message.role == .user {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                UserBubble(text: message.text)
                    .opacity(hidesBubble ? 0 : 1)
                    .background { GeometryReader { geometry in Color.clear.preference(key: RenderedBubbleFrames.self, value: [message.id: geometry.frame(in: .named("chat"))]) } }
                    .frame(maxWidth: userWidth, alignment: .trailing)
            }.frame(maxWidth: .infinity, alignment: .trailing)
        } else if message.role == .activity {
            Text(message.text).font(.system(size: 10, design: .monospaced)).lineLimit(3)
                .foregroundStyle(Theme.muted).textSelection(.enabled)
        } else if message.role == .error {
            VStack(alignment: .leading, spacing: 10) {
                Label(message.text, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(Theme.warning).textSelection(.enabled)
                if message.text.hasPrefix("ChatGPT HTTP 401:") {
                    ChatGPTSignInRecovery(auth: auth)
                }
            }
        } else if !message.text.isEmpty {
            ChatMarkdownView(markdown: message.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ChatGPTSignInRecovery: View {
    @ObservedObject var auth: ChatGPTAuth
    @State private var signedIn = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if signedIn {
                Label("Signed in. Send your message again to continue.", systemImage: "checkmark.circle")
                    .foregroundStyle(Theme.secondary)
            } else {
                HStack(spacing: 10) {
                    Button(auth.isSigningIn ? "Waiting for browser…" : "Sign in") { signIn() }
                        .buttonStyle(.borderedProminent).tint(Theme.action).controlSize(.small)
                        .disabled(auth.isSigningIn).accessibilityLabel("Sign in to ChatGPT")
                    if auth.isSigningIn {
                        Button("Cancel") { auth.cancelSignIn() }.controlSize(.small)
                    }
                }
            }
            if let error { Text(error).foregroundStyle(Theme.warning).textSelection(.enabled) }
        }.font(.system(size: 12))
    }
    private func signIn() {
        error = nil
        let target: ChatGPTAuth.SignInTarget
        if let account = auth.selected { target = .account(account) }
        else { target = auth.hasPendingRegistration ? .pendingRegistration : .newAccount }
        Task {
            do { try await auth.signIn(target); signedIn = true }
            catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}

struct UserBubble: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
            .foregroundStyle(Theme.text).padding(.horizontal, 14).padding(.vertical, 10)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct ComposerDockHeight: PreferenceKey {
    static var defaultValue: CGFloat = 76
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ChatAnchorValues {
    var composer: Anchor<CGRect>?
    var viewport: Anchor<CGRect>?
}

private struct RenderedBubbleFrames: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
private struct ChatAnchors: PreferenceKey {
    static var defaultValue = ChatAnchorValues()
    static func reduce(value: inout ChatAnchorValues, nextValue: () -> ChatAnchorValues) {
        let next = nextValue()
        if let composer = next.composer { value.composer = composer }
        if let viewport = next.viewport { value.viewport = viewport }
    }
}

struct ToolCallView: View {
    let tool: ToolActivity
    @Binding var expanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    ToolStatusIndicator(status: tool.status)
                    ActivityText(tool.title).font(.system(size: 12, design: tool.call.name == "run_command" ? .monospaced : .default))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                }.foregroundStyle(Theme.secondary).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(tool.title)
                .accessibilityValue("\(tool.status.label), \(expanded ? "expanded" : "collapsed")")
            if expanded {
                FadingScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(tool.call.name).font(.system(size: 11, weight: .medium, design: .monospaced))
                        if let review = tool.review {
                            Text(review.summary).font(.system(size: 11)).foregroundStyle(review.outcome == .allow ? Theme.secondary : Theme.warning)
                        }
                        Text(arguments).font(.system(size: 11, design: .monospaced))
                        if !tool.output.isEmpty { Text(tool.output).font(.system(size: 11, design: .monospaced)) }
                    }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }.frame(maxHeight: 220).background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                    .transition(.opacity)
            } else if tool.call.name == "run_command", !tool.output.isEmpty {
                Text(tool.output.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().suffix(3).joined(separator: "\n").trimmingCharacters(in: .newlines))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted).lineLimit(3)
                    .textSelection(.enabled).padding(.leading, 20).transition(.opacity)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: tool.status)
    }
    private var arguments: String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(tool.call.arguments.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return tool.call.arguments }
        return String(decoding: data, as: UTF8.self)
    }
}
