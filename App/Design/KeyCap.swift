import SwiftUI

/// A keyboard key as macOS draws it in menus and help (brief 010): small, rounded, monospaced.
/// Decorative: the button it sits in carries the shortcut in its help and accessibility hint.
struct KeyCap: View {
    let key: String
    var prominent = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        Text(key)
            .font(.caption.weight(.medium).monospaced())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(prominent ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(Theme.textSecondary))
            .background(prominent ? AnyShapeStyle(.white.opacity(0.18)) : AnyShapeStyle(Theme.surface2), in: shape)
            .overlay(shape.strokeBorder(prominent ? .white.opacity(0.25) : (contrast == .increased ? Theme.textTertiary : Theme.hairline), lineWidth: 1))
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// A button label with its key cap: "Pause  [Space]".
struct ShortcutLabel: View {
    let title: String
    var symbol: String? = nil
    let key: String?
    var prominent = false

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if let symbol { Image(systemName: symbol).accessibilityHidden(true) }
            Text(title)
            if let key { KeyCap(key: key, prominent: prominent) }
        }
    }
}
