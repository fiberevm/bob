import AppKit
import SwiftUI

/// Named, adaptive colors shared by SwiftUI and the native text views.
enum Theme {
    static let background = color("background", light: 0xFFFFFF, dark: 0x191A1D)
    static let panel = color("panel", light: 0xF7F7F5, dark: 0x202124)
    static let raised = color("raised", light: 0xF0F0EE, dark: 0x292A2F)
    static let selection = color("selection", light: 0xE9E9E7, dark: 0x34353C)
    static let text = color("text", light: 0x292A2E, dark: 0xEEEFF2)
    static let secondary = color("secondary", light: 0x62646C, dark: 0xB0B2BC)
    static let muted = color("muted", light: 0x767881, dark: 0x93959F)
    static let line = color("line", light: 0xE5E5E3, dark: 0x323339)
    static let accent = color("accent", light: 0x5E6AD2, dark: 0xA2AAF4)
    // Native prominent buttons use white labels while their window is active.
    static let action = color("action", light: 0x5E6AD2, dark: 0x5E6AD2)
    static let statusBar = color("statusBar", light: 0x4E59B9, dark: 0x414B9A)
    static let onAccent = color("onAccent", light: 0xFFFFFF, dark: 0x191A2C)
    static let added = color("added", light: 0x287647, dark: 0x8BC7A0)
    static let removed = color("removed", light: 0xB44444, dark: 0xE89B9B)
    static let warning = color("warning", light: 0x9C5C0B, dark: 0xE5B875)

    static let nativeText = NSColor.labelColor
    static let nativeInsertion = NSColor.textColor

    private static func color(_ name: String, light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name("Bob.\(name)")) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
}

/// Refresh native text attributes when macOS changes appearance, even while idle.
class AdaptiveTextView: NSTextView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }
    func applyTheme() {
        textColor = Theme.nativeText
        insertionPointColor = Theme.nativeInsertion
        selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor,
                                  .foregroundColor: NSColor.selectedTextColor]
        needsDisplay = true
    }
}

/// Quiet pointer feedback for navigation rows, with a neutral selected state.
struct NavigationRowStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, selected: selected)
    }
    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @State private var hovering = false
        var body: some View {
            configuration.label
                .foregroundStyle(selected ? Theme.text : Theme.secondary)
                .background(selected || configuration.isPressed ? Theme.selection : hovering ? Theme.raised : .clear,
                            in: Capsule())
                .contentShape(Capsule())
                .onHover { hovering = $0 }
        }
    }
}
