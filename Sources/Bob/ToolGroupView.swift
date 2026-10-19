import SwiftUI
import BobCore

struct ToolGroupView: View {
    let group: ToolActivityGroup
    @State private var expanded = false
    @State private var expandedCalls = Set<String>()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            if group.tools.count == 1 {
                ToolCallView(tool: group.tools[0], expanded: Binding(
                    get: { expanded },
                    set: { value in
                        expanded = value
                        if value { expandedCalls.insert(group.tools[0].id) }
                        else { expandedCalls.remove(group.tools[0].id) }
                    })).transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { expanded.toggle() }
                    } label: {
                        HStack(spacing: 8) {
                            ToolStatusIndicator(status: group.status)
                            ActivityText(group.title).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            if !group.notices.isEmpty {
                                ActivityText(group.notices).font(.system(size: 10)).foregroundStyle(Theme.muted).transition(.opacity)
                            }
                        }.foregroundStyle(Theme.secondary).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel(group.title + (group.notices.isEmpty ? "" : ", " + group.notices))
                        .accessibilityValue("\(group.status.label), \(expanded ? "expanded" : "collapsed")")
                    if expanded {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(group.tools) { tool in
                                ToolCallView(tool: tool, expanded: Binding(
                                    get: { expandedCalls.contains(tool.id) },
                                    set: { value in
                                        if value { expandedCalls.insert(tool.id) }
                                        else { expandedCalls.remove(tool.id) }
                                    })).transition(.opacity)
                            }
                        }.padding(.leading, 20)
                            .overlay(alignment: .leading) { Theme.line.frame(width: 1).padding(.leading, 5) }
                            .transition(.opacity)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: group.tools.map(\.id))
                    } else if let active = group.activeTool {
                        ActivityText(active.title).font(.system(size: 11)).foregroundStyle(Theme.muted)
                            .lineLimit(1).truncationMode(.middle).padding(.leading, 20)
                            .transition(.opacity)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: group.tools.count == 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: group.activeTool?.id)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: group.notices)
    }
}
