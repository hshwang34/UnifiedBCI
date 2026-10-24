import SwiftUI

/// Design tokens (docs/product/briefs/001-visual-spec.md §1). Colours live in
/// App/Assets.xcassets (Any / Dark, each with a High Contrast variant, written by
/// scripts/make_theme_assets.py), so Dark mode and Increase Contrast come from the system.
enum Theme {
    // §1.1 colour
    static let canvas = Color("canvas")
    static let surface1 = Color("surface1")
    static let surface2 = Color("surface2")
    static let hairline = Color("hairline")
    static let textPrimary = Color("textPrimary")
    static let textSecondary = Color("textSecondary")
    static let textTertiary = Color("textTertiary")
    static let accentFill = Color("accentFill")
    static let accentInk = Color("accentInk")
    static let aurora = Color("aurora")
    static let warning = Color("warning")
    static let warningFill = Color("warningFill")
    static let danger = Color("danger")
    static let positive = Color("positive")

    /// §1.3 radii
    enum Radius {
        static let control: CGFloat = 8
        static let row: CGFloat = 10
        static let chip: CGFloat = 12
        static let cell: CGFloat = 14
        static let card: CGFloat = 20
        static let hero: CGFloat = 28
    }

    /// §1.4 spacing
    enum Space {
        static let xxs: CGFloat = 2, xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12
        static let l: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32, xxxl: CGFloat = 48
        static let cardPadding: CGFloat = 20
        static let heroPadding: CGFloat = 28
        static let cardGap: CGFloat = 16
        static let pageMargin: CGFloat = 24
    }

    /// §1.5 type. `display` is sized through `@ScaledMetric` at the call site.
    enum Fonts {
        static func display(size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .rounded).monospacedDigit() }
        static let heroLabel = Font.system(.title3, design: .rounded).weight(.semibold)
        static let title = Font.system(.title2, design: .rounded).weight(.semibold)
        static let sectionHeader = Font.system(.headline, design: .rounded)
        static let inspectorHeader = Font.system(.subheadline, design: .rounded).weight(.semibold)
        static let matrixNumber = Font.system(size: 32, weight: .semibold, design: .rounded).monospacedDigit()
        static let accuracyLine = Font.system(.title3, design: .rounded).weight(.semibold).monospacedDigit()
        static let mono = Font.system(.callout, design: .monospaced)
        static let monoCaption = Font.system(.caption, design: .monospaced)
    }

    /// §1.8 motion: nil when Reduce Motion is on, so `withAnimation(Theme.motion(...))`
    /// and `.animation(Theme.motion(...), value:)` become no-ops.
    static func motion(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.3)
    }

    static func drawIn(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.4)
    }
}
