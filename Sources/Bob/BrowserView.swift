import SwiftUI
import WebKit

struct BrowserView: View {
    @ObservedObject var session: BrowserSession
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { session.back() } label: { Image(systemName: "chevron.left") }
                    .disabled(!session.canGoBack).help("Back").accessibilityLabel("Back")
                Button { session.forward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!session.canGoForward).help("Forward").accessibilityLabel("Forward")
                TextField("URL", text: $session.address).textFieldStyle(.plain)
                    .font(.system(size: 12)).onSubmit { session.openAddress() }.accessibilityLabel("Browser address")
                Button { session.reloadOrStop() } label: { Image(systemName: session.isLoading ? "xmark" : "arrow.clockwise") }
                    .help(session.isLoading ? "Stop Loading" : "Reload Page").accessibilityLabel(session.isLoading ? "Stop Loading" : "Reload Page")
                    .disabled(session.currentURL.isEmpty && !session.isLoading)
            }.buttonStyle(.plain).foregroundStyle(Theme.secondary).padding(.horizontal, 12).frame(height: 39).background(Theme.panel)
            Theme.line.frame(height: 1)
            if let error = session.error {
                HStack {
                    Text(error).font(.system(size: 11)).foregroundStyle(Theme.removed).textSelection(.enabled)
                    Spacer()
                    Button { session.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss Browser Error")
                }.padding(12).background(Theme.panel)
            }
            ZStack {
                NativeBrowser(session: session)
                if session.currentURL.isEmpty && !session.isLoading { EmptyPanel(title: "Enter a URL").allowsHitTesting(false) }
            }
        }
    }
}

private struct NativeBrowser: NSViewRepresentable {
    let session: BrowserSession
    func makeNSView(context: Context) -> WKWebView { session.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
