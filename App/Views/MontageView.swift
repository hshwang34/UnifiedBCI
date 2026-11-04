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

    @State private var orbit: Orbit
    @State private var dragBase: Orbit?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    static let stageHeight: CGFloat = 340
    /// Framed on the dome, not the study's neck-inclusive framing, so labels have room.
    static let target = SIMD3<Double>(0, -6, 6)
    static let distance = 820.0

    init(layout: MontageLayout, selected: Binding<String?>, hovered: Binding<String?>, initialOrbit: Orbit? = nil, onChoose: @escaping () -> Void = {}) {
        self.layout = layout
        _selected = selected
        _hovered = hovered
        self.onChoose = onChoose
        _orbit = State(initialValue: initialOrbit ?? LaunchArguments.montagePreset?.orbit ?? .default)
    }

    private var reduceMotion: Bool { LaunchArguments.reduceMotion(system: systemReduceMotion) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            // The view buttons sit beside the title when they fit, below it otherwise (a
            // narrow detail column truncated "Reset").
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Montage").font(Theme.Fonts.sectionHeader).foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: Theme.Space.m)
                    presetButtons.fixedSize()
                }
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("Montage").font(Theme.Fonts.sectionHeader).foregroundStyle(Theme.textPrimary)
                    presetButtons.fixedSize()
                }
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
                Button(preset.title) {
                    withAnimation(reduceMotion ? nil : .smooth(duration: Orbit.transitionDuration(reduceMotion: false))) {
                        orbit = orbit.nearest(preset.orbit)
                    }
                }
                .help(preset.accessibilityLabel)
                .accessibilityLabel(preset.accessibilityLabel)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var stage: some View {
        HeadStage(orbit: orbit, target: Self.target, distance: Self.distance) { camera, size in
            ZStack {
                MontageMarks(layout: layout, camera: camera, size: size, selected: selected, hovered: hovered)
                ElectrodeButtons(layout: layout, camera: camera, size: size, selected: $selected, hovered: $hovered, onChoose: onChoose)
            }
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

/// Study A4's marks: grid, notch, unused sites as tiny rings, the recording's electrodes as
/// cups, and their labels on leader lines. Drawn back to front; decorative to VoiceOver
/// (the buttons carry the electrodes).
private struct MontageMarks: View {
    let layout: MontageLayout
    let camera: HeadCamera
    let size: CGSize
    let selected: String?
    let hovered: String?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let style = HeadStyle(scheme: scheme, contrast: contrast, reduceTransparency: reduceTransparency)
        let placedSites = Set(layout.placed.map(\.site.label))
        let labels = Self.labels(layout: layout, camera: camera, size: size, selected: selected)
        let texts = Dictionary(uniqueKeysWithValues: layout.placed.map { ($0.channelID, $0.label) })
        Canvas { gc, size in
            HeadDrawing.grid(&gc, camera: camera, size: size, style: style)
            HeadDrawing.notch(&gc, camera: camera, size: size, style: style)
            enum Mark { case site(SIMD3<Double>), cup(MontageLayout.Electrode, SIMD3<Double>) }
            var marks: [(Double, Mark)] = StandardPositions.tenTen.filter { !placedSites.contains($0.label) }.map {
                let p = HeadGeometry.surfacePoint($0); return (camera.depth(p), .site(p))
            }
            marks += layout.placed.map { e in let p = HeadGeometry.surfacePoint(e.site); return (camera.depth(p), .cup(e, p)) }
            for (_, mark) in marks.sorted(by: { $0.0 > $1.0 }) {
                switch mark {
                case .site(let p): HeadDrawing.site(&gc, at: p, camera: camera, size: size, style: style)
                case .cup(let e, let p):
                    HeadDrawing.cup(&gc, at: p, camera: camera, size: size, style: style,
                                    selected: selected == e.channelID, hovered: hovered == e.channelID, reference: e.isReference)
                }
            }
            HeadDrawing.labels(&gc, labels, texts: texts, style: style)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    static func labels(layout: MontageLayout, camera: HeadCamera, size: CGSize, selected: String?) -> [LabelLayout.Placed] {
        MontageLabels.place(layout: layout, camera: camera, size: size, selected: selected)
    }
}

/// One label per placed electrode, pushed out from the head centre; back-facing ones dim.
@MainActor
enum MontageLabels {
    static func place(layout: MontageLayout, camera: HeadCamera, size: CGSize, selected: String?) -> [LabelLayout.Placed] {
        let centre = camera.project(HeadGeometry.labelCentre, in: size) ?? CGPoint(x: size.width / 2, y: size.height / 2)
        let items = layout.placed.compactMap { e -> LabelLayout.Item? in
            let p = HeadGeometry.surfacePoint(e.site)
            guard let q = camera.project(p + HeadGeometry.normal(at: p) * 1.2, in: size) else { return nil }
            let strong = selected == e.channelID
            return LabelLayout.Item(id: e.channelID, anchor: q, size: LabelMetrics.size(e.label, strong: strong),
                                    strong: strong, dim: !camera.faces(p))
        }
        return LabelLayout.place(items, centre: centre, bounds: CGRect(origin: .zero, size: size))
    }
}

/// One invisible button per placed electrode, on its projected point: the accessible,
/// hoverable and clickable layer (the Canvas only draws). A back-facing electrode stays a
/// VoiceOver button but takes no clicks.
private struct ElectrodeButtons: View {
    let layout: MontageLayout
    let camera: HeadCamera
    let size: CGSize
    @Binding var selected: String?
    @Binding var hovered: String?
    let onChoose: () -> Void

    var body: some View {
        ZStack {
            ForEach(layout.placed) { e in
                let p = HeadGeometry.surfacePoint(e.site)
                if let pt = camera.project(p, in: size) {
                    let front = camera.faces(p)
                    Button {
                        selected = e.channelID
                        onChoose()
                    } label: {
                        Color.clear.frame(width: 20, height: 20).contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .allowsHitTesting(front)
                    .onHover { inside in
                        if inside { hovered = e.channelID } else if hovered == e.channelID { hovered = nil }
                    }
                    .help(e.isReference ? "\(e.label) (reference)" : e.label)
                    .accessibilityLabel(e.label)
                    .accessibilityValue(e.isReference ? "reference" : "")
                    .accessibilityAddTraits(selected == e.channelID ? [.isSelected] : [])
                    .accessibilityHint("Selects its row in the channel table")
                    .position(pt)
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// The reference mark in the caption: the same dashed ring the head draws around it.
struct ReferenceGlyph: View {
    var body: some View {
        Circle()
            .strokeBorder(Theme.textPrimary, style: StrokeStyle(lineWidth: 1.4, dash: [3, 2.5]))
            .accessibilityHidden(true)
    }
}
