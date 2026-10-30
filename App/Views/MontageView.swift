import SwiftUI

/// The live montage view on the Recording screen (brief 003, decisions #16–#18): the head
/// with every placed electrode and its label, the reference marked, the unplaced labels
/// listed under "Positions undeclared". Selection and hover are by channel id and shared
/// with the channel table. No per-channel colour or value (decision #17): every electrode
/// looks the same except the one selected or hovered.
struct MontageView: View {
    let layout: MontageLayout
    @Binding var selected: String?
    @Binding var hovered: String?
    /// Called when an electrode is chosen, so the page can show the channel table.
    var onChoose: () -> Void = {}

    @State private var orbit = LaunchArguments.montagePreset?.orbit ?? .default
    @State private var dragBase: Orbit?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    static let stageHeight: CGFloat = 300

    private var reduceMotion: Bool { LaunchArguments.reduceMotion(system: systemReduceMotion) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Text("Montage").font(Theme.Fonts.sectionHeader).foregroundStyle(Theme.textPrimary)
                Spacer()
                presetButtons
            }
            stage
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(layout.caption).font(.callout).foregroundStyle(Theme.textSecondary)
                Label {
                    Text(layout.referenceCaption)
                } icon: {
                    ReferenceGlyph().frame(width: 12, height: 12)
                }
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                if let title = layout.undeclaredTitle {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.callout.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                        Text(layout.unplacedList).font(Theme.Fonts.mono).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                    }
                    .padding(.top, Theme.Space.xs)
                    .accessibilityElement(children: .combine)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(layout.accessibilityLabel)
    }

    private var presetButtons: some View {
        HStack(spacing: Theme.Space.xs) {
            ForEach(Orbit.Preset.allCases) { preset in
                Button {
                    withAnimation(reduceMotion ? nil : .smooth(duration: Orbit.transitionDuration(reduceMotion: false))) {
                        orbit = orbit.nearest(preset.orbit)
                    }
                } label: {
                    if preset == .reset { Label(preset.title, systemImage: preset.symbol).labelStyle(.iconOnly) } else { Text(preset.title) }
                }
                .help(preset.accessibilityLabel)
                .accessibilityLabel(preset.accessibilityLabel)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var stage: some View {
        HeadStage(orbit: orbit) { camera, size in
            ElectrodeOverlay(layout: layout, camera: camera, size: size, selected: $selected, hovered: $hovered, onChoose: onChoose)
        }
        .frame(height: Self.stageHeight)
        .frame(maxWidth: .infinity)
        .background(Theme.surface2.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Radius.cell, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cell, style: .continuous))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    let base = dragBase ?? orbit
                    dragBase = base
                    orbit = base.dragged(by: value.translation)
                }
                .onEnded { _ in dragBase = nil }
        )
    }
}

/// The electrode buttons on the head. Sorted back to front; a back-facing electrode is a
/// faint dot without a label (still a VoiceOver button, so every electrode stays reachable).
private struct ElectrodeOverlay: View {
    let layout: MontageLayout
    let camera: HeadCamera
    let size: CGSize
    @Binding var selected: String?
    @Binding var hovered: String?
    let onChoose: () -> Void

    var body: some View {
        let marks = layout.placed.compactMap { e -> (MontageLayout.Electrode, CGPoint, Double)? in
            let p = HeadGeometry.surfacePoint(e.site)
            guard let pt = camera.project(p, in: size) else { return nil }
            return (e, pt, camera.facing(p))
        }.sorted { $0.2 < $1.2 }
        ZStack {
            ForEach(marks, id: \.0.id) { e, pt, facing in
                ElectrodeButton(electrode: e, facing: facing,
                                highlighted: selected == e.channelID || hovered == e.channelID,
                                selected: selected == e.channelID) {
                    selected = e.channelID
                    onChoose()
                } hover: { inside in
                    if inside { hovered = e.channelID } else if hovered == e.channelID { hovered = nil }
                }
                .position(pt)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

private struct ElectrodeButton: View {
    let electrode: MontageLayout.Electrode
    let facing: Double
    let highlighted: Bool
    let selected: Bool
    let action: () -> Void
    let hover: (Bool) -> Void

    var body: some View {
        let front = facing > 0.12
        Button(action: action) {
            VStack(spacing: 1) {
                ZStack {
                    if electrode.isReference {
                        ReferenceGlyph().frame(width: highlighted ? 22 : 18, height: highlighted ? 22 : 18)
                    }
                    Circle()
                        .fill(highlighted ? Theme.accentFill : Theme.accentInk)
                        .overlay(Circle().strokeBorder(Theme.surface1, lineWidth: 1.5))
                        .frame(width: highlighted ? 14 : 10, height: highlighted ? 14 : 10)
                }
                .frame(width: 22, height: 22)
                Text(electrode.label)
                    .font(.system(size: 10, weight: highlighted ? .bold : .medium, design: .monospaced))
                    .foregroundStyle(highlighted ? Theme.textPrimary : Theme.textSecondary)
                    .padding(.horizontal, 3)
                    .background(highlighted ? Theme.surface1 : .clear, in: Capsule())
                    .fixedSize()
                    .opacity(front ? 1 : 0)
            }
            // The tap target covers the dot and its label; the layout puts the dot at the point.
            .offset(y: 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(front ? 0.4 + 0.6 * min(1, facing * 2) : 0.18)
        .allowsHitTesting(front)
        .onHover(perform: hover)
        .help(electrode.isReference ? "\(electrode.label) (reference)" : electrode.label)
        .accessibilityLabel(electrode.label)
        .accessibilityValue(electrode.isReference ? "reference" : "")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityHint("Selects its row in the channel table")
    }
}

/// The reference mark: a ring with a cross-hair, a shape and not a colour (decision #17).
struct ReferenceGlyph: View {
    var body: some View {
        ZStack {
            Circle().strokeBorder(Theme.textPrimary, lineWidth: 1.5)
            Rectangle().fill(Theme.textPrimary).frame(width: 1.5)
            Rectangle().fill(Theme.textPrimary).frame(height: 1.5)
        }
        .accessibilityHidden(true)
    }
}
