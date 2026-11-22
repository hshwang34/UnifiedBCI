import Observation
import SwiftUI

// Brief 007 PR 4: "Show me" rings the control a guide step points at. Views mark their
// controls with `.guideAnchor(_:)`; the project's `GuideSpotlight` (in the environment)
// says which anchor to ring. About 2 s, pulsing, or a static ring under Reduce Motion.

/// Which anchor is ringed now. One per project window.
@MainActor
@Observable
final class GuideSpotlight {
    static let duration: Duration = .seconds(2)

    private(set) var anchor: GuideAnchor?
    /// Bumped per highlight, so ringing the same control twice restarts the ring.
    private(set) var token = 0
    @ObservationIgnored var duration: Duration = GuideSpotlight.duration
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Rings `anchor` after `delay` (time for a section change or sheet to appear), then clears.
    func highlight(_ anchor: GuideAnchor, after delay: Duration = .milliseconds(300)) {
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.token += 1
            self.anchor = anchor
            try? await Task.sleep(for: self.duration)
            guard !Task.isCancelled else { return }
            self.anchor = nil
        }
    }

    func clear() {
        task?.cancel()
        anchor = nil
    }

    /// Waits until the current highlight has been shown and cleared (tests).
    func awaitHighlight() async { await task?.value }
}

extension View {
    /// Marks the control "Show me" rings for `anchor` (nil: not a target).
    func guideAnchor(_ anchor: GuideAnchor?) -> some View { modifier(GuideAnchorModifier(anchor: anchor)) }
}

private struct GuideAnchorModifier: ViewModifier {
    let anchor: GuideAnchor?
    @Environment(GuideSpotlight.self) private var spotlight: GuideSpotlight?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            if let spotlight, let anchor, spotlight.anchor == anchor {
                SpotlightRing(reduceMotion: LaunchArguments.reduceMotion(system: reduceMotion))
                    .id(spotlight.token)
                    .transition(.opacity)
            }
        }
    }
}

/// A 3 pt accent ring just outside the control; never takes clicks.
private struct SpotlightRing: View {
    let reduceMotion: Bool
    @State private var on = false

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
            .strokeBorder(Theme.accentInk, lineWidth: 3)
            .padding(-5)
            .shadow(color: Theme.accentInk.opacity(0.55), radius: on ? 10 : 3)
            .scaleEffect(reduceMotion ? 1 : (on ? 1.03 : 0.99))
            .opacity(reduceMotion || on ? 1 : 0.6)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                // Four half-second swells: about 2 s, matching `GuideSpotlight.duration`.
                withAnimation(.easeInOut(duration: 0.5).repeatCount(4, autoreverses: true)) { on = true }
            }
    }
}
