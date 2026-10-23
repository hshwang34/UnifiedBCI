import SwiftUI

/// §2.6: a point estimate and its interval on 0…1, as wide as its card, so the
/// uncertainty carries as much visual weight as the number. With no interval the track
/// is dashed and only the marker is drawn: the absence is visible, not blank.
struct RangeBar: View {
    struct Reference: Equatable {
        let value: Double
        let label: String
    }

    let value: Double
    let interval: ClosedRange<Double>?
    var reference: Reference? = nil
    /// VoiceOver label ("Accuracy interval").
    let label: String

    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let trackHeight: CGFloat = 12
    private static let marker: CGFloat = 18
    private static let height: CGFloat = 84

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = { (v: Double) in CGFloat(min(max(v, 0), 1)) * w }
            let barY: CGFloat = 30
            ZStack(alignment: .topLeading) {
                // Track: solid capsule, or dashed when there is no interval.
                if interval != nil {
                    Capsule().fill(Theme.surface2)
                        .frame(width: w, height: Self.trackHeight)
                        .position(x: w / 2, y: barY)
                } else {
                    Path { p in p.move(to: CGPoint(x: 0, y: barY)); p.addLine(to: CGPoint(x: w, y: barY)) }
                        .stroke(Theme.textTertiary, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 4]))
                }
                // Interval: gradient capsule with a surface1 outline (reads under Increase Contrast).
                if let interval {
                    let hi = x(interval.upperBound)
                    let width = min(max(hi - x(interval.lowerBound), Self.trackHeight), w)
                    // A minimum-width capsule near 1 is pulled back inside the track.
                    let lo = min(x(interval.lowerBound), w - width)
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.accentInk, Theme.aurora], startPoint: .leading, endPoint: .trailing))
                        .overlay(Capsule().strokeBorder(Theme.surface1, lineWidth: 1.5))
                        .frame(width: drawn ? width : 0, height: Self.trackHeight)
                        .position(x: lo + (drawn ? width : 0) / 2, y: barY)
                    edgeLabel(Fmt.fixed(interval.lowerBound), at: lo, y: barY + 20, width: w)
                    edgeLabel(Fmt.fixed(interval.upperBound), at: hi, y: barY + 20, width: w)
                }
                // Reference tick and its caption.
                if let reference {
                    let rx = x(reference.value)
                    Rectangle().fill(Theme.textSecondary)
                        .frame(width: 2, height: Self.marker + 8)
                        .position(x: clamp(rx, width: w, half: 1), y: barY)
                    Text("\(Fmt.fixed(reference.value)) \(reference.label)")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize()
                        .position(x: clamp(rx, width: w, half: 70), y: barY + 40)
                }
                // Point estimate: accentFill marker with a surface1 ring, value above.
                Circle().fill(Theme.accentFill)
                    .overlay(Circle().strokeBorder(Theme.surface1, lineWidth: 2))
                    .frame(width: Self.marker, height: Self.marker)
                    .position(x: clamp(x(value), width: w, half: Self.marker / 2), y: barY)
                Text(Fmt.fixed(value))
                    .font(Theme.Fonts.mono.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize()
                    .position(x: clamp(x(value), width: w, half: 18), y: barY - 20)
                // Scale ticks.
                ForEach([0.0, 0.5, 1.0], id: \.self) { t in
                    Text(t == 0.5 ? "0.5" : "\(Int(t))")
                        .font(Theme.Fonts.monoCaption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize()
                        .position(x: clamp(x(t), width: w, half: 10), y: barY + 40)
                        // A tick under the reference caption gives way to it.
                        .opacity(reference.map { abs(x($0.value) - x(t)) < 80 } == true ? 0 : 1)
                }
            }
        }
        .frame(height: Self.height)
        .onAppear { withAnimation(Theme.drawIn(reduceMotion: reduceMotion)) { drawn = true } }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(Self.accessibilityValue(value: value, interval: interval, reference: reference))
    }

    private func edgeLabel(_ text: String, at x: CGFloat, y: CGFloat, width: CGFloat) -> some View {
        Text(text)
            .font(Theme.Fonts.mono)
            .foregroundStyle(Theme.textPrimary)
            .fixedSize()
            .position(x: clamp(x, width: width, half: 18), y: y)
    }

    private func clamp(_ x: CGFloat, width: CGFloat, half: CGFloat) -> CGFloat {
        min(max(x, half), max(half, width - half))
    }

    static func accessibilityValue(value: Double, interval: ClosedRange<Double>?, reference: Reference?) -> String {
        var text = interval.map { "\(Fmt.fixed($0.lowerBound)) to \(Fmt.fixed($0.upperBound)), point estimate \(Fmt.fixed(value))" }
            ?? "no interval, point estimate \(Fmt.fixed(value))"
        if let reference { text += "; \(reference.label) \(Fmt.fixed(reference.value))" }
        return text
    }
}
