import AppKit
import Observation
import SwiftUI

// Brief 010: the participant window's cards between trials (instructions, pause, break,
// session done). They are SwiftUI over the cue view's layers and only ever drawn over the
// background: the cue view hides them in the same layer transaction that shows a fixation
// cross or a cue, so no card, and no card's animation, is on screen during a measured phase.
// Copy comes from `ParticipantCardModel` (CueWindowModels.swift).

/// What the hosted card view draws; set from the cue view on the main thread.
@MainActor @Observable
final class ParticipantCardState {
    var card: ParticipantCardModel?
    var increaseContrast = false
}

/// Hosts the cards; never takes clicks, so the cue view keeps the hidden cursor.
final class ParticipantCardHost: NSHostingView<ParticipantCardStage> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    override func cursorUpdate(with event: NSEvent) {}
}

struct ParticipantCardStage: View {
    let state: ParticipantCardState

    var body: some View {
        GeometryReader { g in
            let unit = min(g.size.width, g.size.height)
            ZStack {
                if let card = state.card {
                    ParticipantCardView(card: card, unit: unit, width: g.size.width, increaseContrast: state.increaseContrast)
                        .id(card)
                        // A soft rise on the way in; out is a plain fade (both skipped by Reduce Motion,
                        // which sets no animation at the call site).
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: unit * 0.012)), removal: .opacity))
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ParticipantCardView: View {
    let card: ParticipantCardModel
    let unit: CGFloat
    let width: CGFloat
    let increaseContrast: Bool

    private var ink: Color { Color(.sRGB, red: CueWindowModel.ink.r, green: CueWindowModel.ink.g, blue: CueWindowModel.ink.b) }
    private var secondary: Color {
        ink.opacity(increaseContrast ? CueWindowModel.inkSecondaryAlphaHighContrast : CueWindowModel.inkSecondaryAlpha)
    }

    var body: some View {
        let body = max(14, unit * CueWindowModel.instructionsSize)
        VStack(spacing: unit * 0.035) {
            if let eyebrow = card.eyebrow {
                Text(eyebrow.uppercased())
                    .font(.system(size: max(11, body * 0.5), weight: .semibold, design: .rounded))
                    .tracking(body * 0.08)
                    .foregroundStyle(secondary)
            }
            if let symbol = card.symbol {
                Image(systemName: symbol)
                    .font(.system(size: body * 2.2, weight: .light))
                    .foregroundStyle(secondary)
            }
            if let title = card.title {
                Text(title).font(.system(size: body * 1.35, weight: .semibold, design: .rounded)).foregroundStyle(ink)
            }
            Text(card.body)
                .font(.system(size: card.kind == .instructions ? body : body * 0.8, weight: .regular, design: .rounded))
                .lineSpacing(body * 0.25)
                .foregroundStyle(card.kind == .instructions ? ink : secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: width * CueWindowModel.instructionsWidth)
                .fixedSize(horizontal: false, vertical: true)
            if !card.legend.isEmpty {
                HStack(spacing: unit * 0.09) {
                    ForEach(card.legend) { item in
                        VStack(spacing: unit * 0.014) {
                            Image(systemName: CueWindowModel.cueGlyph(item.cue))
                                .font(.system(size: body * 1.5, weight: .semibold))
                                .foregroundStyle(ink)
                            Text(item.name)
                                .font(.system(size: body * 0.62, weight: .medium, design: .rounded))
                                .foregroundStyle(secondary)
                        }
                    }
                }
                .padding(.top, unit * 0.01)
            }
            if !card.runs.isEmpty {
                HStack(spacing: unit * 0.012) {
                    ForEach(card.runs.indices, id: \.self) { i in
                        Capsule()
                            .fill(card.runs[i] == .pending ? ink.opacity(0.18) : card.runs[i] == .current ? ink : secondary)
                            .frame(width: card.runs[i] == .current ? unit * 0.03 : unit * 0.011, height: unit * 0.011)
                    }
                }
                .padding(.top, unit * 0.01)
            }
            if let footer = card.footer {
                Text(footer)
                    .font(.system(size: body * 0.62, weight: .regular, design: .rounded))
                    .foregroundStyle(secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: width * CueWindowModel.instructionsWidth)
                    .padding(.top, unit * 0.02)
            }
        }
        .padding(unit * 0.04)
    }
}
