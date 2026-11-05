import CoreGraphics
import Foundation
import simd

/// The head both the Recording screen's montage view and the intro's scalp map draw
/// (decision #20, study A4 "glass over a ghost head", docs/product/briefs/003-glass-studies.html).
/// Everything is in the position table's own frame: millimetres, +x the subject's right,
/// +y anterior (nose), +z up. That is the sketch's frame too, so `HeadGlass.metal` ports its
/// shader maths one to one.
enum HeadGeometry {
    /// Least-squares axis-aligned ellipsoid through the 86 table sites. Largest residual
    /// 5.5 % of the radius, so a site moved onto the surface shifts under 6 mm.
    static let centre = SIMD3<Double>(0.8, -16.5, -16.4)
    static let radii = SIMD3<Double>(89.3, 105.9, 120.5)
    /// The dome is cut at this height (the sketch's ZC); the polished rim sits on it.
    static let cutZ = -58.0

    /// A point moved along its direction from the centre onto the dome surface.
    static func surface(_ p: SIMD3<Double>) -> SIMD3<Double> {
        let d = p - centre
        return centre + d / sqrt(simd_length_squared(d / radii))
    }

    static func surfacePoint(_ site: StandardPositions.Site) -> SIMD3<Double> { surface(site.position) }

    /// Outward surface normal at a dome point.
    static func normal(at p: SIMD3<Double>) -> SIMD3<Double> {
        simd_normalize((p - centre) / (radii * radii))
    }

    /// The faint 10-10 grid on the dome: one polyline per row (Fp, AF, F, FC, C, CP, P, PO,
    /// O, I; FT/T/TP join FC/C/CP) and per column (z and each number across AF…PO), sampled
    /// eight times per segment and laid on the surface (the sketch's LINES/POLYS).
    static let gridLines: [[SIMD3<Double>]] = {
        var rows: [String: [StandardPositions.Site]] = [:]
        var cols: [String: [StandardPositions.Site]] = [:]
        var rowOrder: [String] = [], colOrder: [String] = []
        for site in StandardPositions.tenTen {
            guard let m = site.label.wholeMatch(of: /([A-Za-z]+?)(z|\d+)/) else { continue }
            var row = String(m.1)
            let col = String(m.2)
            switch row { case "FT": row = "FC"; case "T": row = "C"; case "TP": row = "CP"; default: break }
            if rows[row] == nil { rowOrder.append(row) }
            rows[row, default: []].append(site)
            if col == "z" || ["AF", "F", "FC", "C", "CP", "P", "PO"].contains(row) {
                if cols[col] == nil { colOrder.append(col) }
                cols[col, default: []].append(site)
            }
        }
        var lines: [[StandardPositions.Site]] = []
        for r in rowOrder { if let l = rows[r], l.count > 1 { lines.append(l.sorted { $0.x < $1.x }) } }
        for c in colOrder { if let l = cols[c], l.count > 1 { lines.append(l.sorted { $0.y > $1.y }) } }
        return lines.map { line in
            var pts: [SIMD3<Double>] = []
            for i in 0..<(line.count - 1) {
                for k in 0..<8 {
                    pts.append(surface(simd_mix(line[i].position, line[i + 1].position, SIMD3(repeating: Double(k) / 8))))
                }
            }
            pts.append(surface(line[line.count - 1].position))
            return pts
        }
    }()

    /// The small front notch: a short stroke from just above the nasion out past the brow.
    static let notchBase = surface(SIMD3(0.8, 86, -22))
    static let notchTip: SIMD3<Double> = {
        let tip = surface(SIMD3(0.8, 92, -44))
        return tip + normal(at: tip) * 10
    }()

    /// Where labels are pushed out from: a point above the centre, projected.
    static let labelCentre = centre + SIMD3(0, 0, 40)
}

/// An orbit around the head, in the sketch's convention: yaw 0 looks at the face, yaw −90
/// from the subject's left, +90 from the right; pitch raises the camera (degrees). Yaw 180 /
/// pitch 89 is the top view with the nose up and the subject's right on the right (the
/// topoplot convention).
struct Orbit: Equatable, Sendable {
    var yaw: Double
    var pitch: Double

    static let pitchRange: ClosedRange<Double> = -20...89

    enum Preset: String, CaseIterable, Identifiable, Sendable {
        case top, left, right, front, reset
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        /// VoiceOver label for the button.
        var accessibilityLabel: String {
            switch self {
            case .top: return "View from the top"
            case .left: return "View from the left"
            case .right: return "View from the right"
            case .front: return "View from the front"
            case .reset: return "Reset view"
            }
        }
        var orbit: Orbit {
            switch self {
            case .top: return Orbit(yaw: 180, pitch: 89)
            case .left: return Orbit(yaw: -90, pitch: 6)
            case .right: return Orbit(yaw: 90, pitch: 6)
            case .front: return Orbit(yaw: 0, pitch: 6)
            case .reset: return Orbit(yaw: -38, pitch: 26)
            }
        }
    }

    static let `default` = Preset.reset.orbit

    /// A drag of (dx, dy) points: yaw wraps to (−180, 180], pitch clamps to `pitchRange`.
    func dragged(by translation: CGSize) -> Orbit {
        Orbit(yaw: Self.wrap(yaw - translation.width * 0.45),
              pitch: min(max(pitch + translation.height * 0.35, Self.pitchRange.lowerBound), Self.pitchRange.upperBound))
    }

    static func wrap(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d <= -180 { d += 360 }
        if d > 180 { d -= 360 }
        return d
    }

    /// `target` with its yaw moved by whole turns so an animation takes the short way round.
    func nearest(_ target: Orbit) -> Orbit {
        Orbit(yaw: yaw + Self.wrap(target.yaw - yaw), pitch: target.pitch)
    }

    /// How long a change of view animates: 0 under Reduce Motion (decision #18: snap).
    static func transitionDuration(reduceMotion: Bool) -> Double { reduceMotion ? 0 : 0.52 }
}

/// A perspective camera on an orbit (the sketch's `camera()` / `project()`), shared by the
/// Metal shader (which raymarches through it) and the Canvas overlay (which projects with it),
/// so the two always agree.
struct HeadCamera: Equatable, Sendable {
    var orbit: Orbit
    /// Study A4's framing: room for the ghost head's neck below the dome.
    var target = SIMD3<Double>(0, -6, -26)
    var distance = 740.0
    /// Half the vertical field of view (degrees).
    var halfFOV = 13.0

    var position: SIMD3<Double> {
        let y = orbit.yaw * .pi / 180, p = min(orbit.pitch, 89.4) * .pi / 180
        return target + SIMD3(sin(y) * cos(p), cos(y) * cos(p), sin(p)) * distance
    }
    var forward: SIMD3<Double> { simd_normalize(target - position) }
    var right: SIMD3<Double> { simd_normalize(simd_cross(forward, SIMD3(0, 0, 1))) }
    var up: SIMD3<Double> { simd_cross(right, forward) }
    /// Focal length in half-heights.
    var focal: Double { 1 / tan(halfFOV * .pi / 180) }

    /// A head point → view point (origin top-left), or nil behind the camera.
    func project(_ p: SIMD3<Double>, in size: CGSize) -> CGPoint? {
        let v = p - position, z = simd_dot(v, forward)
        guard z > 1 else { return nil }
        let k = focal * size.height / 2 / z
        return CGPoint(x: size.width / 2 + simd_dot(v, right) * k, y: size.height / 2 - simd_dot(v, up) * k)
    }

    /// Depth along the view direction (larger is farther).
    func depth(_ p: SIMD3<Double>) -> Double { simd_dot(p - position, forward) }

    /// Whether a dome point faces the camera (the dome is convex, so this is its occlusion).
    func faces(_ p: SIMD3<Double>) -> Bool {
        simd_dot(HeadGeometry.normal(at: p), position - p) > 0
    }

    /// How squarely a dome point faces the camera, 0…1.
    func facing(_ p: SIMD3<Double>) -> Double {
        max(0, simd_dot(HeadGeometry.normal(at: p), simd_normalize(position - p)))
    }

    /// A disc of `radius` mm lying on the dome at `p`, lifted `lift` mm along the normal, as a
    /// projected polygon (the sketch's `disc()`): electrodes foreshorten with the surface.
    func disc(at p: SIMD3<Double>, radius: Double, lift: Double = 0.8, in size: CGSize, segments: Int = 22) -> [CGPoint]? {
        let n = HeadGeometry.normal(at: p)
        var t1 = simd_cross(n, SIMD3(0, 0, 1))
        if simd_length(t1) < 0.1 { t1 = SIMD3(1, 0, 0) }
        t1 = simd_normalize(t1)
        let t2 = simd_cross(n, t1), c = p + n * lift
        var out: [CGPoint] = []
        out.reserveCapacity(segments)
        for i in 0..<segments {
            let a = Double(i) / Double(segments) * 2 * .pi
            guard let q = project(c + t1 * (cos(a) * radius) + t2 * (sin(a) * radius), in: size) else { return nil }
            out.append(q)
        }
        return out
    }
}

/// Leader-line labels (the sketch's `drawLabels`): each label is pushed outward from the
/// projected head centre and nudged (farther out, then a little round) until its box overlaps
/// no label placed before it. Selected labels place first, back-facing ones last.
enum LabelLayout {
    struct Item: Equatable {
        let id: String
        let anchor: CGPoint
        let size: CGSize
        var strong = false
        var dim = false
    }

    struct Placed: Equatable {
        let id: String
        let anchor: CGPoint
        let frame: CGRect
        let strong: Bool
        let dim: Bool
        /// Where the leader line starts (just off the electrode) and ends (the box edge).
        let lineStart: CGPoint
        let lineEnd: CGPoint
    }

    static let distances: [CGFloat] = [20, 30, 42, 56, 72, 90, 110, 130, 150]
    static let angles: [CGFloat] = [0, 0.26, -0.26, 0.52, -0.52, 0.8, -0.8, 1.1, -1.1]
    static let gap: CGFloat = 2

    /// `bounds`, when given, keeps every box inside it (inset 4 pt), so labels never clip at
    /// the stage edge.
    /// `obstacles` (e.g. the front-facing electrodes) are avoided like placed labels.
    static func place(_ items: [Item], centre: CGPoint, bounds: CGRect? = nil, obstacles: [CGRect] = []) -> [Placed] {
        let inner = bounds?.insetBy(dx: 4, dy: 4)
        let order = items.sorted { ($0.dim ? 1 : 0, $0.strong ? 0 : 1, $0.id) < ($1.dim ? 1 : 0, $1.strong ? 0 : 1, $1.id) }
        var placed: [Placed] = []
        for item in order {
            var dx = item.anchor.x - centre.x, dy = item.anchor.y - centre.y
            let len = max(hypot(dx, dy), 1)
            dx /= len; dy /= len
            var best: (CGRect, CGFloat, CGFloat, Int)?
            search: for k in distances {
                for a in angles {
                    let ux: CGFloat = dx * cos(a) - dy * sin(a), uy: CGFloat = dx * sin(a) + dy * cos(a)
                    let c = CGPoint(x: item.anchor.x + ux * k, y: item.anchor.y + uy * k)
                    var box = CGRect(x: c.x - item.size.width / 2, y: c.y - item.size.height / 2, width: item.size.width, height: item.size.height)
                    if let inner {
                        box.origin.x = min(max(box.minX, inner.minX), inner.maxX - box.width)
                        box.origin.y = min(max(box.minY, inner.minY), inner.maxY - box.height)
                    }
                    let hits = placed.filter { $0.frame.insetBy(dx: -gap, dy: -gap).intersects(box) }.count
                        + obstacles.filter { $0.intersects(box) }.count
                    if best == nil || hits < best!.3 { best = (box, ux, uy, hits) }
                    if hits == 0 { break search }
                }
            }
            let (box, ux, uy, _) = best!
            let start = CGPoint(x: item.anchor.x + ux * 8, y: item.anchor.y + uy * 8)
            let end = CGPoint(x: box.midX - ux * (box.width / 2 - 2) * abs(ux), y: box.midY - uy * (box.height / 2) * abs(uy))
            placed.append(Placed(id: item.id, anchor: item.anchor, frame: box, strong: item.strong, dim: item.dim, lineStart: start, lineEnd: end))
        }
        return placed
    }

    /// The box a front-facing electrode occupies on screen, for `obstacles` (a cup of
    /// radius 6.6 mm with its hover ring is under 8 pt at the stage's scale).
    static func cupBox(at p: CGPoint) -> CGRect { CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16) }

    /// Pairs of placed labels whose boxes overlap (for tests and the debug log).
    static func overlaps(_ placed: [Placed]) -> Int {
        var n = 0
        for i in placed.indices { for j in placed.indices where j > i && placed[i].frame.intersects(placed[j].frame) { n += 1 } }
        return n
    }
}
