import SwiftUI

// Liquid Glass (macOS 26+) with plain fallbacks for older systems.
// Glass belongs to the control layer that floats over content: bars, capsules, prominent
// buttons. Content itself (the file table) stays opaque and scrolls underneath.

extension View {
    /// Pins a bar above or below scrolling content. On macOS 26 this is `safeAreaBar`, which
    /// gives the content a scroll-edge effect instead of a hard divider or bar background.
    @ViewBuilder
    func edgeBar<Bar: View>(_ edge: VerticalEdge, @ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(macOS 26.0, *) {
            safeAreaBar(edge: edge, spacing: 0, content: bar)
        } else {
            safeAreaInset(edge: edge, spacing: 0) {
                VStack(spacing: 0) {
                    if edge == .bottom { Divider() }
                    bar().background(.bar)
                    if edge == .top { Divider() }
                }
            }
        }
    }

    /// A floating capsule of glass around small controls or status text.
    @ViewBuilder
    func glassCapsule(interactive: Bool = false) -> some View {
        let padded = padding(.horizontal, 12).padding(.vertical, 6)
        if #available(macOS 26.0, *) {
            padded.glassEffect(interactive ? .regular.interactive() : .regular, in: .capsule)
        } else {
            padded
        }
    }

    /// Groups glass shapes so neighbouring capsules blend and morph together.
    @ViewBuilder
    func glassGroup(spacing: CGFloat = 8) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }

    /// The main button of a sheet or dialog.
    @ViewBuilder
    func prominentButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}

/// Outline used while files are dragged over the list; follows the window's corner radius on macOS 26.
struct DropHighlight: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            ConcentricRectangle().stroke(Color.accentColor, lineWidth: 3).padding(5)
        } else {
            RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 3).padding(4)
        }
    }
}
