import SwiftUI

// The wrappers of visual spec §1.8. Every `#available` in the app lives in this file, so
// call sites read the same on macOS 15 (material + rim) and macOS 26 (Liquid Glass).
// Reduce Transparency and Increase Contrast make every glass surface solid with a border.

/// How one glass surface looks. Opacities are (light, dark).
struct GlassStyle {
    var tint: Color? = nil
    var tintOpacity: (light: Double, dark: Double) = (0.10, 0.14)
    /// Solid surface1 behind the content, so text contrast never depends on what the glass refracts.
    var scrim: (light: Double, dark: Double)? = nil
    var elevation = 2

    static let floating = GlassStyle()
    static let hero = GlassStyle(tint: Theme.accentInk, scrim: (0.60, 0.55), elevation: 2)
}

/// Whether the user asked for solid surfaces.
private struct SolidSurfaces {
    let reduceTransparency: Bool
    let increaseContrast: Bool
    var solid: Bool { reduceTransparency || increaseContrast }
}

struct GlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    var style: GlassStyle = .floating
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let a11y = SolidSurfaces(reduceTransparency: reduceTransparency, increaseContrast: contrast == .increased)
        if a11y.solid {
            content
                .background(Theme.surface1, in: shape)
                .overlay(shape.strokeBorder(a11y.increaseContrast ? Theme.textTertiary : Theme.hairline,
                                            lineWidth: a11y.increaseContrast ? 1.5 : 1))
                .elevation(a11y.reduceTransparency ? 0 : style.elevation)
        } else if #available(macOS 26, *) {
            let glass: Glass = style.tint.map { .regular.tint($0.opacity(scheme == .dark ? style.tintOpacity.dark : style.tintOpacity.light)) } ?? .regular
            content
                .background(Theme.surface1.opacity(scrimOpacity ?? 0), in: shape)
                .glassEffect(glass, in: shape)
        } else {
            content
                .background(Theme.surface1.opacity(scrimOpacity ?? 0.35), in: shape)
                .background(.ultraThinMaterial, in: shape)
                .overlay(RimStroke(shape: shape))
                .elevation(style.elevation)
        }
    }

    private var scrimOpacity: Double? {
        style.scrim.map { scheme == .dark ? $0.dark : $0.light }
    }
}

/// The 1pt rim of the macOS 15 fallback (§1.6).
private struct RimStroke: View {
    let shape: RoundedRectangle
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if scheme == .dark {
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        } else {
            ZStack {
                shape.stroke(.black.opacity(0.06), lineWidth: 1)
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            }
        }
    }
}

/// §1.7 shadows. Level 0 flat, 1 card, 2 floating. Reduce Transparency keeps only the contact shadow.
private struct Elevation: ViewModifier {
    let level: Int
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let ink = Color(red: 0x0F / 255, green: 0x17 / 255, blue: 0x22 / 255)
        switch (level, reduceTransparency) {
        case (_, true), (0, _):
            content.shadow(color: .black.opacity(level == 0 ? 0 : 0.06), radius: 2, y: 1)
        case (1, _):
            content
                .shadow(color: dark ? .black.opacity(0.35) : ink.opacity(0.10), radius: dark ? 24 : 20, y: dark ? 12 : 8)
                .shadow(color: .black.opacity(dark ? 0 : 0.06), radius: 2, y: 1)
        default:
            content.shadow(color: dark ? .black.opacity(0.45) : .black.opacity(0.14), radius: dark ? 32 : 28, y: dark ? 16 : 12)
        }
    }
}

extension View {
    func glassSurface(cornerRadius: CGFloat, style: GlassStyle = .floating) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius, style: style))
    }

    fileprivate func elevation(_ level: Int) -> some View { modifier(Elevation(level: level)) }

    /// §1.8 `Card`: solid surface1, radius 20, hairline border, level-1 shadow. The
    /// container for tables, the matrix and numbers: never glass.
    func card(padding: CGFloat = Theme.Space.cardPadding) -> some View {
        modifier(CardModifier(padding: padding))
    }

    /// The tappable Welcome cards: interactive glass on 26, material + rim (+ hover) on 15.
    func interactiveGlassCard(cornerRadius: CGFloat, enabled: Bool) -> some View {
        modifier(InteractiveGlassCard(cornerRadius: cornerRadius, enabled: enabled))
    }

    /// §1.8 `appProminentButton()`: glass-prominent on 26, bordered-prominent on 15.
    @ViewBuilder func appProminentButton() -> some View {
        if #available(macOS 26, *) {
            self.buttonStyle(.glassProminent).buttonBorderShape(.capsule).controlSize(.large)
        } else {
            self.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
        }
    }

    /// Lets a backdrop continue under the sidebar and inspector (macOS 26 only).
    @ViewBuilder func extendedBackground() -> some View {
        if #available(macOS 26, *) { self.backgroundExtensionEffect() } else { self }
    }

    /// A soft scroll-edge effect at `edges` (macOS 26 only).
    @ViewBuilder func softScrollEdge(_ edges: Edge.Set) -> some View {
        if #available(macOS 26, *) { self.scrollEdgeEffectStyle(.soft, for: edges) } else { self }
    }
}

private struct CardModifier: ViewModifier {
    let padding: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        content
            .padding(padding)
            .background(Theme.surface1, in: shape)
            .overlay(shape.strokeBorder(contrast == .increased ? Theme.textTertiary : Theme.hairline, lineWidth: contrast == .increased ? 1.5 : 1))
            .elevation(1)
    }
}

private struct InteractiveGlassCard: ViewModifier {
    let cornerRadius: CGFloat
    let enabled: Bool
    @State private var hovering = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency || contrast == .increased {
            content.glassSurface(cornerRadius: cornerRadius, style: GlassStyle(elevation: 0))
        } else if #available(macOS 26, *) {
            content.glassEffect(enabled ? .regular.interactive() : .regular, in: shape)
        } else {
            content
                .glassSurface(cornerRadius: cornerRadius, style: GlassStyle(elevation: 0))
                .brightness(enabled && hovering ? 0.06 : 0)
                .onHover { hovering = $0 }
        }
    }
}

/// Groups nearby glass so it blends instead of stacking (GlassEffectContainer on 26).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// A fixed gap between toolbar groups (ToolbarSpacer on 26; nothing on 15).
struct FixedToolbarSpacer: ToolbarContent {
    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
    }
}

/// §1.8 `StatusChip`: a solid tinted chip with a symbol and primary-colour text.
struct StatusChip: View {
    enum Kind {
        case warning, danger, info, positive

        var symbol: String {
            switch self {
            case .warning: return "exclamationmark.triangle.fill"
            case .danger: return "exclamationmark.octagon.fill"
            case .info: return "info.circle.fill"
            case .positive: return "checkmark.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .warning: return Theme.warning
            case .danger: return Theme.danger
            case .info: return Theme.accentInk
            case .positive: return Theme.positive
            }
        }

        var fill: Color {
            switch self {
            case .warning: return Theme.warningFill
            case .danger: return Theme.danger.opacity(0.11)
            case .info: return Theme.accentInk.opacity(0.10)
            case .positive: return Theme.positive.opacity(0.11)
            }
        }
    }

    let kind: Kind
    let text: String
    var symbol: String? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Image(systemName: symbol ?? kind.symbol)
                .foregroundStyle(kind.color)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s + 2)
        .background {
            ZStack {
                shape.fill(Theme.surface1)
                shape.fill(kind.fill)
            }
        }
        .overlay(shape.strokeBorder(kind.color, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}
