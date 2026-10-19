import SwiftUI
import AppKit

struct ComputerView: View {
    @ObservedObject var session: ComputerSession
    @ObservedObject var access: ComputerAccess
    @State private var selectedApp = ""
    @State private var selectedWindow: UInt32 = 0
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Computer use", isOn: $access.enabled).toggleStyle(.switch).controlSize(.small)
                Spacer()
            }.padding(12).background(Theme.panel)
            Theme.line.frame(height: 1)
            if access.enabled {
                if !session.permissions.screenRecording || !session.permissions.accessibility {
                    VStack(alignment: .leading, spacing: 12) {
                        permission("Screen Recording", granted: session.permissions.screenRecording) { session.requestScreenRecording(); session.openPermissionSettings(false) }
                        permission("Accessibility", granted: session.permissions.accessibility) { session.requestAccessibility(); session.openPermissionSettings(true) }
                    }.padding(16)
                    Theme.line.frame(height: 1)
                }
                HStack {
                    Picker("App", selection: $selectedApp) {
                        Text("Choose app").tag("")
                        ForEach(session.applications) { app in Text(app.name).tag(app.bundleID) }
                    }.labelsHidden()
                    Button {
                        Task { do { _ = try await session.capture(selectedApp, windowID: selectedWindow == 0 ? nil : selectedWindow) } catch { session.error = error.localizedDescription } }
                    } label: { Image(systemName: "camera") }
                        .disabled(selectedApp.isEmpty || session.busy || !session.permissions.screenRecording || !session.permissions.accessibility)
                        .accessibilityLabel("Capture App Window").help("Capture App Window")
                    if session.busy { ProgressView().controlSize(.small) }
                }.padding(12)
                if let state = session.latest, state.app.bundleID == selectedApp, state.windows.count > 1 {
                    Picker("Window", selection: $selectedWindow) {
                        Text("Main window").tag(UInt32(0))
                        ForEach(state.windows, id: \.id) { window in Text(window.title).tag(window.id) }
                    }.padding(.horizontal, 12)
                }
                if let error = session.error {
                    Text(error).font(.system(size: 11)).foregroundStyle(Theme.warning).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                if let snapshot = session.latest, let image = NSImage(data: snapshot.image.data) {
                    HStack {
                        Text(snapshot.app.name).fontWeight(.medium)
                        Text(snapshot.title).foregroundStyle(Theme.muted).lineLimit(1)
                        Spacer()
                        Text(snapshot.date, style: .time).foregroundStyle(Theme.muted)
                    }.font(.system(size: 11)).padding(.horizontal, 12).padding(.bottom, 8)
                    GeometryReader { geometry in
                        Image(nsImage: image).resizable().scaledToFit().frame(width: geometry.size.width, height: geometry.size.height)
                    }.padding(12)
                } else { EmptyPanel(title: "Capture an app window") }
            } else { EmptyPanel(title: "Enable computer use to work with Mac apps") }
            if !access.allowedApps.isEmpty {
                Theme.line.frame(height: 1)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Always-allowed apps").font(.system(size: 10)).foregroundStyle(Theme.muted)
                    ForEach(access.allowedApps.sorted(), id: \.self) { id in
                        HStack {
                            Text(session.applications.first(where: { $0.bundleID == id })?.name ?? id).font(.system(size: 11)).lineLimit(1)
                            Spacer()
                            Button("Remove") { access.revoke(id) }.font(.system(size: 11))
                        }
                    }
                }.padding(12).background(Theme.panel)
            }
        }
        .onAppear { session.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in session.refresh() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in session.refresh() }
        .onChange(of: session.latest?.app.bundleID) { _, value in if let value { selectedApp = value } }
        .onChange(of: selectedApp) { _, _ in selectedWindow = 0 }
    }
    private func permission(_ title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Label(title, systemImage: granted ? "checkmark.circle.fill" : "lock").foregroundStyle(granted ? Theme.secondary : Theme.text)
            Spacer()
            if !granted { Button("Allow…", action: action) }
        }.font(.system(size: 12))
    }
}
