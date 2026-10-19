import SwiftUI

/// Fade clipped content while leaving the first and last items clear at rest.
struct FadingScrollView<Content: View>: View {
    private let axes: Axis.Set
    private let showsIndicators: Bool
    private let content: Content
    @Namespace private var coordinateSpace
    @State private var contentFrame = CGRect.zero
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(_ axes: Axis.Set = .vertical, showsIndicators: Bool = true,
         @ViewBuilder content: () -> Content) {
        self.axes = axes
        self.showsIndicators = showsIndicators
        self.content = content()
    }

    var body: some View {
        ScrollView(axes, showsIndicators: showsIndicators) {
            content.background {
                GeometryReader { geometry in
                    Color.clear.preference(key: ScrollContentFrames.self,
                                           value: [coordinateSpace: geometry.frame(in: .named(coordinateSpace))])
                }
            }
        }
        .coordinateSpace(name: coordinateSpace)
        .onPreferenceChange(ScrollContentFrames.self) { frames in
            if let frame = frames[coordinateSpace] { contentFrame = frame }
        }
        .mask {
            GeometryReader { geometry in
                let depth = min(20, geometry.size.height / 2)
                let top = min(depth, max(0, -contentFrame.minY))
                let bottom = min(depth, max(0, contentFrame.maxY - geometry.size.height))
                if reduceTransparency || !axes.contains(.vertical) {
                    Color.black
                } else {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: top)
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: bottom)
                    }
                }
            }.allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

private struct ScrollContentFrames: PreferenceKey {
    static let defaultValue: [Namespace.ID: CGRect] = [:]
    static func reduce(value: inout [Namespace.ID: CGRect], nextValue: () -> [Namespace.ID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
