import SwiftUI

/// §1.2: what the glass refracts. Canvas plus two soft radial glows that fade out by
/// y = 420. Static; plain canvas under Reduce Transparency.
struct AmbientBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            Theme.canvas
            if !reduceTransparency {
                let dark = scheme == .dark
                RadialGradient(colors: [Theme.accentInk.opacity(dark ? 0.20 : 0.14), .clear],
                               center: .topLeading, startRadius: 0, endRadius: 420)
                RadialGradient(colors: [Theme.aurora.opacity(dark ? 0.14 : 0.10), .clear],
                               center: .topTrailing, startRadius: 0, endRadius: 360)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// §3: class labels shown in two forms; the stored label is never replaced. Only class
/// names (matrix, counts, the summary) use this: channels, events and exports stay verbatim.
enum ClassDisplay {
    /// `cue_left_fist` → "Left-fist cue"; any other `cue_<words>` → "<Words> cue";
    /// anything else verbatim.
    static func name(_ raw: String) -> String {
        if let m = raw.wholeMatch(of: /cue_(left|right)_fist/) {
            return m.1 == "left" ? "Left-fist cue" : "Right-fist cue"
        }
        if let m = raw.wholeMatch(of: /cue_(.+)/) {
            let words = m.1.split(separator: "_").joined(separator: " ")
            guard let first = words.first else { return raw }
            return first.uppercased() + words.dropFirst() + " cue"
        }
        return raw
    }

    /// For VoiceOver: "Left-fist cue, stored label cue_left_fist".
    static func spoken(_ raw: String) -> String {
        let display = name(raw)
        return display == raw ? raw : "\(display), stored label \(raw)"
    }

    /// For running text: "Left-fist cue (cue_left_fist)".
    static func inline(_ raw: String) -> String {
        let display = name(raw)
        return display == raw ? raw : "\(display) (\(raw))"
    }
}
