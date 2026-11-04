import AppKit
import SwiftUI

/// The head (decision #20, study A4): a Metal shader raymarches the thick-glass dome over a
/// faint ghost head (`HeadGlass.metal`), and Canvas layers draw the grid, the sites, the
/// electrodes and their labels with the same camera (`HeadCamera`). No model files, no
/// RealityKit. `overlay` adds the caller's own layer (electrode buttons, the neural field).
///
/// Animatable on the orbit: SwiftUI interpolates yaw and pitch, so the shader and every
/// overlay move together frame by frame. With no animation (Reduce Motion) it snaps.
struct HeadStage<Overlay: View>: View, @preconcurrency Animatable {
    var orbit: Orbit
    var target = SIMD3<Double>(0, -6, -26)
    var distance = 740.0
    @ViewBuilder var overlay: (HeadCamera, CGSize) -> Overlay

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(orbit.yaw, orbit.pitch) }
        set { orbit = Orbit(yaw: newValue.first, pitch: newValue.second) }
    }

    var body: some View {
        let camera = HeadCamera(orbit: orbit, target: target, distance: distance)
        GeometryReader { geo in
            ZStack {
                HeadGlassView(camera: camera, size: geo.size)
                    .accessibilityHidden(true)
                overlay(camera, geo.size)
            }
        }
    }
}

/// The colours of the A4 look, from the study's tokens. Accent, aurora and text come from
/// `Theme`; the head's own neutrals (cap, ink, line, ring, label plate) are the study's
/// values per appearance. Increase Contrast strengthens the outline and grid; Reduce
/// Transparency makes the dome frosted-solid.
struct HeadStyle {
    let dark: Bool
    let increasedContrast: Bool
    let solid: Bool

    /// Built in view bodies (main actor); the drawing that reads it runs in Canvas closures.
    @MainActor
    init(scheme: ColorScheme, contrast: ColorSchemeContrast, reduceTransparency: Bool) {
        dark = scheme == .dark
        increasedContrast = contrast == .increased
        solid = LaunchArguments.reduceTransparency(system: reduceTransparency)
    }

    var accent: Color { Theme.accentInk }
    var aurora: Color { Theme.aurora }
    var text: Color { Theme.textPrimary }
    var cap: Color { dark ? Color(hex: 0x2E3542) : Color(hex: 0xEEF2F7) }
    var ink: Color { dark ? Color(hex: 0xC9D3E0) : Color(hex: increasedContrast ? 0x3B4757 : 0x5D697B) }
    var line: Color { dark ? Color(hex: 0xC9D3E0) : Color(hex: 0x3B4757) }
    var ring: Color { dark ? Color(hex: 0xE8EEF6) : .white }
    var labelPlate: Color { dark ? Color(hex: 0x0E1116).opacity(0.80) : Color.white.opacity(0.86) }

    /// Grid line opacity on the front and back of the dome.
    var gridFront: Double { increasedContrast ? 0.45 : 0.22 }
    var gridBack: Double { solid ? 0 : increasedContrast ? 0.14 : 0.07 }
    /// Back-facing marks show through the glass, faintly; a frosted dome hides them.
    var backOpacity: Double { solid ? 0 : 0.32 }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// The dome and ghost head: one full-size rectangle whose every pixel is raymarched.
private struct HeadGlassView: View {
    let camera: HeadCamera
    let size: CGSize
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let style = HeadStyle(scheme: scheme, contrast: contrast, reduceTransparency: reduceTransparency)
        let p = camera.position, f = camera.forward, r = camera.right, u = camera.up
        Rectangle()
            .fill(.white)
            .colorEffect(ShaderLibrary.headGlass(
                .float2(Float(size.width), Float(size.height)),
                .float3(Float(p.x), Float(p.y), Float(p.z)),
                .float3(Float(f.x), Float(f.y), Float(f.z)),
                .float3(Float(r.x), Float(r.y), Float(r.z)),
                .float3(Float(u.x), Float(u.y), Float(u.z)),
                .float(Float(camera.focal)),
                .color(style.ink), .color(style.accent), .color(style.accent), .color(style.cap),
                .float(style.solid ? 1 : 0), .float(style.increasedContrast ? 1 : 0)))
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)
    }
}

/// Canvas drawing shared by the montage view and the intro, ported from the study's
/// overlay (`drawOverlay`, `drawElectrode`, `drawLabels`).
enum HeadDrawing {
    /// The faint 10-10 grid: back lines first and fainter, then front lines.
    static func grid(_ gc: inout GraphicsContext, camera: HeadCamera, size: CGSize, style: HeadStyle) {
        for front in [false, true] {
            let opacity = front ? style.gridFront : style.gridBack
            guard opacity > 0 else { continue }
            var path = Path()
            for line in HeadGeometry.gridLines {
                var pen = false
                for p in line {
                    if camera.faces(p) == front, let q = camera.project(p, in: size) {
                        if pen { path.addLine(to: q) } else { path.move(to: q) }
                        pen = true
                    } else {
                        pen = false
                    }
                }
            }
            gc.stroke(path, with: .color(style.line.opacity(opacity)), lineWidth: 1)
        }
    }

    /// The small front notch: a short accent stroke above the nasion.
    static func notch(_ gc: inout GraphicsContext, camera: HeadCamera, size: CGSize, style: HeadStyle) {
        guard let a = camera.project(HeadGeometry.notchTip, in: size), let b = camera.project(HeadGeometry.notchBase, in: size) else { return }
        var path = Path()
        path.move(to: b); path.addLine(to: a)
        let front = camera.faces(HeadGeometry.notchBase)
        gc.stroke(path, with: .color(style.accent.opacity(front ? 0.9 : max(style.backOpacity, 0.15))),
                  style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
    }

    /// An unused standard site: a tiny ring.
    static func site(_ gc: inout GraphicsContext, at p: SIMD3<Double>, camera: HeadCamera, size: CGSize, style: HeadStyle) {
        let front = camera.faces(p)
        guard front || style.backOpacity > 0, let ring = camera.disc(at: p, radius: 1.9, in: size, segments: 12) else { return }
        gc.stroke(polygon(ring), with: .color(style.line.opacity(front ? (style.increasedContrast ? 0.6 : 0.4) : 0.12)), lineWidth: 1)
    }

    /// A cup electrode: a light ring with an accent core. Selected: filled accent with a
    /// white core. Hovered: an accent ring around it. Every cup looks the same otherwise
    /// (decision #17). The reference gets a dashed outer ring: a shape, not a colour.
    static func cup(_ gc: inout GraphicsContext, at p: SIMD3<Double>, camera: HeadCamera, size: CGSize, style: HeadStyle,
                    selected: Bool = false, hovered: Bool = false, reference: Bool = false) {
        let front = camera.faces(p)
        let opacity = front ? 1 : style.backOpacity
        guard opacity > 0,
              let outer = camera.disc(at: p, radius: selected ? 6.6 : 5.8, lift: 1.2, in: size),
              let inner = camera.disc(at: p, radius: selected ? 3.6 : 3.0, lift: 1.6, in: size) else { return }
        var g = gc
        g.opacity = opacity
        do {
            var shadowed = g
            if front { shadowed.addFilter(.shadow(color: style.accent.opacity(0.55), radius: 4)) }
            shadowed.fill(polygon(outer), with: .color(selected ? style.accent : style.ring))
        }
        g.stroke(polygon(outer), with: .color(style.accent.opacity(0.9)), lineWidth: style.increasedContrast ? 1.8 : 1.2)
        g.fill(polygon(inner), with: .color(selected ? .white : style.accent))
        if hovered && !selected, let ring = camera.disc(at: p, radius: 9, lift: 1.2, in: size) {
            g.stroke(polygon(ring), with: .color(style.accent), lineWidth: 2)
        }
        if reference, let ring = camera.disc(at: p, radius: 10.5, lift: 1.2, in: size) {
            g.stroke(polygon(ring), with: .color(style.text.opacity(0.85)), style: StrokeStyle(lineWidth: 1.4, dash: [3, 2.5]))
        }
    }

    /// Labels on leader lines, laid out by `LabelLayout` so none overlap.
    static func labels(_ gc: inout GraphicsContext, _ placed: [LabelLayout.Placed], texts: [String: String], style: HeadStyle) {
        for l in placed.reversed() {
            var g = gc
            g.opacity = l.dim ? 0.4 : 1
            var lead = Path()
            lead.move(to: l.lineStart); lead.addLine(to: l.lineEnd)
            g.stroke(lead, with: .color(style.line.opacity(style.increasedContrast ? 0.8 : 0.55)), lineWidth: 1)
            g.fill(Path(roundedRect: l.frame, cornerRadius: 5), with: .color(l.strong ? style.accent : style.labelPlate))
            if style.increasedContrast && !l.strong {
                g.stroke(Path(roundedRect: l.frame, cornerRadius: 5), with: .color(style.line.opacity(0.6)), lineWidth: 1)
            }
            let text = Text(texts[l.id] ?? l.id)
                .font(LabelMetrics.font(strong: l.strong))
                .foregroundStyle(l.strong ? Color.white : style.text)
            g.draw(text, at: CGPoint(x: l.frame.midX, y: l.frame.midY + 0.5))
        }
    }

    static func polygon(_ pts: [CGPoint]) -> Path {
        var path = Path()
        path.addLines(pts)
        path.closeSubpath()
        return path
    }
}

/// Label plate sizes: 11 pt monospaced text plus padding, measured once per string.
@MainActor
enum LabelMetrics {
    nonisolated static func font(strong: Bool) -> Font { .system(size: 11, weight: strong ? .semibold : .medium, design: .monospaced) }

    private static var cache: [String: CGSize] = [:]

    static func size(_ text: String, strong: Bool) -> CGSize {
        let key = "\(strong ? 1 : 0)\(text)"
        if let s = cache[key] { return s }
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: strong ? .semibold : .medium)
        let w = (text as NSString).size(withAttributes: [.font: font]).width
        let s = CGSize(width: ceil(w) + 10, height: 17)
        cache[key] = s
        return s
    }
}

/// Compiles the head shader and measures the example's label plates at launch, before the
/// Welcome window's first frame, so the intro's first frames and the step-3 labels don't
/// stall on first use (brief 003, 60 fps criterion).
@MainActor
enum HeadGlassWarmUp {
    static func start() {
        for label in IntroModel.exampleLabels { _ = LabelMetrics.size(label, strong: false); _ = LabelMetrics.size(label, strong: true) }
        _ = HeadGeometry.gridLines
        let shader = ShaderLibrary.headGlass(.float2(1, 1), .float3(0, 0, 1), .float3(0, 0, -1), .float3(1, 0, 0), .float3(0, 1, 0),
                                             .float(1), .color(.white), .color(.white), .color(.white), .color(.white), .float(0), .float(0))
        Task { try? await shader.compile(as: .colorEffect) }
    }
}
