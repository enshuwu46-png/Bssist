import SwiftUI
import AppKit

// MARK: - Window Translucent Visual Effect Backdrop

struct WindowVisualEffectBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Liquid Glass Container Wrapper

struct LiquidGlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}

// MARK: - Liquid Glass Surface Modifier (Sections / Cards / Bars)

struct LiquidGlassSectionModifier: ViewModifier {
    var cornerRadius: CGFloat = 14
    var interactive: Bool = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            content
                .glassEffect(
                    interactive ? .regular.interactive() : .regular,
                    in: shape
                )
        } else {
            content
                .background(
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(
                            LinearGradient(
                                colors: [
                                    Color.primary.opacity(0.055),
                                    Color.primary.opacity(0.015)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    }
                )
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.28),
                                Color.primary.opacity(0.08),
                                Color.white.opacity(0.12)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
                )
                .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 4)
        }
    }
}

// MARK: - Liquid Glass Pill / Button Modifier

struct LiquidGlassPillModifier: ViewModifier {
    var cornerRadius: CGFloat = 8
    var isProminent: Bool = false
    var isSelected: Bool = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let activeProminent = isProminent || isSelected

        if #available(macOS 26.0, *) {
            content
                .background {
                    if activeProminent {
                        shape.fill(Color.primary.opacity(0.86))
                    }
                }
                .glassEffect(
                    .regular.interactive(),
                    in: shape
                )
        } else {
            content
                .background(
                    ZStack {
                        if activeProminent {
                            shape.fill(Color.primary.opacity(0.88))
                        } else {
                            shape.fill(.thinMaterial)
                            shape.fill(Color.primary.opacity(0.04))
                        }
                    }
                )
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(activeProminent ? 0.35 : 0.22),
                                Color.primary.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.65
                    )
                )
        }
    }
}

extension View {
    func liquidGlassSection(cornerRadius: CGFloat = 14, interactive: Bool = false) -> some View {
        modifier(LiquidGlassSectionModifier(cornerRadius: cornerRadius, interactive: interactive))
    }

    func liquidGlassPill(cornerRadius: CGFloat = 8, isProminent: Bool = false, isSelected: Bool = false) -> some View {
        modifier(LiquidGlassPillModifier(cornerRadius: cornerRadius, isProminent: isProminent, isSelected: isSelected))
    }
}
