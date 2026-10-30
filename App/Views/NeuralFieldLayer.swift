import AppKit
import os
import simd
import SwiftUI

/// The intro's "neural field" (brief 003, decision #14), drawn over the shared head: every
/// 10-10 site as a faint dot, the step's sites lighting up in a wave from the vertex, and
/// particles drifting between lit sites. One `TimelineView` + `Canvas`; every frame is a pure
/// function of time (`NeuralField`), so a still frame (Reduce Motion) is one fixed time and
/// the timeline is paused. Decorative: hidden from accessibility.
struct NeuralFieldLayer: View {
    let camera: HeadCamera
    let size: CGSize
    /// nil lights every site.
    let lit: Set<String>?
    let policy: MotionPolicy
    let start: Date
    let clock: FrameClock

    private static let sites = StandardPositions.tenTen.map { (label: $0.label, point: HeadGeometry.surfacePoint($0)) }
    private static let vertex = HeadGeometry.surfacePoint(StandardPositions.byLabel["Cz"]!)

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: policy.timelinePaused)) { context in
            let t = policy.animates ? context.date.timeIntervalSince(start) : MotionPolicy.stillTime
            let _ = policy.animates ? clock.tick(context.date) : clock.pause()
            Canvas { gc, canvasSize in
                draw(&gc, size: canvasSize, t: t)
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(_ gc: inout GraphicsContext, size: CGSize, t: Double) {
        let state = FrameClock.signposter.beginInterval("IntroDraw")
        defer { FrameClock.signposter.endInterval("IntroDraw", state) }
        var points: [CGPoint?] = []
        var facing: [Double] = []
        points.reserveCapacity(Self.sites.count)
        for s in Self.sites {
            let f = camera.facing(s.point)
            facing.append(f)
            points.append(f > 0.05 ? camera.project(s.point, in: size) : nil)
        }
        // Faint grid of every site.
        for (i, p) in points.enumerated() {
            guard let p else { continue }
            let r = 1.8
            gc.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                    with: .color(Theme.textTertiary.opacity(0.55 * facing[i])))
        }
        let litIndices = Self.sites.indices.filter { lit?.contains(Self.sites[$0].label) ?? true }
        // Lit sites: a halo that swells with the wave, and a solid core.
        for i in litIndices {
            guard let p = points[i] else { continue }
            let g = NeuralField.glow(distance: simd_distance(Self.sites[i].point, Self.vertex), at: t)
            let halo = 3 + 9 * g
            gc.fill(Path(ellipseIn: CGRect(x: p.x - halo, y: p.y - halo, width: 2 * halo, height: 2 * halo)),
                    with: .radialGradient(Gradient(colors: [Theme.aurora.opacity(0.55 * g * facing[i]), Theme.aurora.opacity(0)]),
                                          center: p, startRadius: 0, endRadius: halo))
            let r = 2.6 + 0.8 * g
            gc.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                    with: .color(Theme.accentInk.opacity(0.5 + 0.5 * facing[i])))
        }
        // Particles between lit sites; a trip is drawn only while both ends face the camera.
        for particle in NeuralField.particles(at: t, count: policy.particleCount, nodes: litIndices.count) {
            guard let a = points[litIndices[particle.from]], let b = points[litIndices[particle.to]] else { continue }
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let dx = b.x - a.x, dy = b.y - a.y
            let control = CGPoint(x: mid.x - dy * 0.3 * particle.bow, y: mid.y + dx * 0.3 * particle.bow)
            for (k, lag) in [0.0, 0.035, 0.07].enumerated() {
                let u = max(0, particle.progress - lag)
                let x = (1 - u) * (1 - u) * a.x + 2 * (1 - u) * u * control.x + u * u * b.x
                let y = (1 - u) * (1 - u) * a.y + 2 * (1 - u) * u * control.y + u * u * b.y
                let r = particle.size * (1 - 0.25 * Double(k))
                gc.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                        with: .color(Theme.aurora.opacity(particle.opacity * (0.9 - 0.3 * Double(k)))))
            }
        }
    }
}

/// The self-drawing signal trace under the head. Flat and dashed on the hardware step: no
/// device, no signal. Decorative: hidden from accessibility.
struct TraceStrip: View {
    let live: Bool
    let policy: MotionPolicy
    let start: Date

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: policy.timelinePaused || !live)) { context in
            let progress = policy.animates && live ? NeuralField.traceProgress(at: context.date.timeIntervalSince(start)) : 1
            Canvas { gc, size in
                let mid = size.height / 2
                if !live {
                    var flat = Path()
                    flat.move(to: CGPoint(x: 0, y: mid)); flat.addLine(to: CGPoint(x: size.width, y: mid))
                    gc.stroke(flat, with: .color(Theme.textTertiary), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 5]))
                    return
                }
                let n = 220
                let last = Int(Double(n) * progress)
                guard last > 1 else { return }
                var path = Path()
                for i in 0...last {
                    let x = Double(i) / Double(n)
                    let p = CGPoint(x: x * size.width, y: mid - NeuralField.trace(x) * mid * 0.85)
                    if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                gc.stroke(path, with: .linearGradient(Gradient(colors: [Theme.accentInk.opacity(0.35), Theme.accentInk, Theme.aurora]),
                                                      startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)),
                          style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                if progress < 1 {
                    let x = Double(last) / Double(n)
                    let head = CGPoint(x: x * size.width, y: mid - NeuralField.trace(x) * mid * 0.85)
                    gc.fill(Path(ellipseIn: CGRect(x: head.x - 3.5, y: head.y - 3.5, width: 7, height: 7)), with: .color(Theme.aurora))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Frame intervals of the intro's timeline (brief 003, 60 fps criterion). Each interval is
/// an os_signpost event ("IntroFrame", subsystem com.hshwang34.BCIWorkspace, category
/// IntroFrames) and the draw cost an "IntroDraw" interval, so Instruments' os_signpost and
/// Animation Hitches tracks line up; Debug `-BCIFrameLog <file>` also appends a summary.
@MainActor
final class FrameClock {
    nonisolated static let signposter = OSSignposter(subsystem: "com.hshwang34.BCIWorkspace", category: "IntroFrames")
    private var last: Date?
    private var first: Date?
    private(set) var stats = FrameStats()
    /// "t=12.40 s 41.7 ms" for each interval over 1.5 frames, for the Debug log.
    private var long: [String] = []

    func tick(_ date: Date) {
        if let last {
            let ms = date.timeIntervalSince(last) * 1000
            // A gap over 250 ms is a pause (occlusion, a modal), not a frame.
            if ms > 0, ms < 250 {
                stats.add(ms)
                if ms > FrameStats.budget * 1.5 { long.append("t=\(Fmt.fixed(date.timeIntervalSince(first ?? date))) s \(Fmt.fixed(ms, 1)) ms") }
                Self.signposter.emitEvent("IntroFrame", "\(ms, format: .fixed(precision: 2)) ms")
            }
        }
        last = date
        if first == nil { first = date }
    }

    func pause() { last = nil }

    /// Appends the summary to the Debug frame log, if one was asked for, and starts over.
    func flush(_ label: String) {
        defer { stats = FrameStats(); last = nil; first = nil; long = [] }
        guard stats.count > 0, let url = LaunchArguments.frameLogURL else { return }
        let line = "\(label): \(stats.summary)\n" + (long.isEmpty ? "" : "  long frames: \(long.joined(separator: ", "))\n")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// Reports whether the hosting window is visible (not occluded or minimized), so the intro's
/// timeline pauses when nobody can see it (brief 003 "Engineering decisions").
struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.report = { visible = $0 }
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var report: ((Bool) -> Void)?
        private var token: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if token == nil {
                // Any window's change, matched against the window we are in at that moment:
                // SwiftUI may host the view in one window before moving it to the real one.
                token = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] note in
                    let window = note.object as? NSWindow
                    let visible = window?.occlusionState.contains(.visible) ?? true
                    MainActor.assumeIsolated {
                        guard let self, window === self.window else { return }
                        self.report?(visible)
                    }
                }
            }
            guard let window else { return }
            let visible = window.occlusionState.contains(.visible)
            // Not during the view update that installed us. A window still ordering in reads
            // as occluded here; its occlusion notification follows and corrects it.
            Task { @MainActor [weak self] in self?.report?(visible || !(self?.window?.isVisible ?? false)) }
        }

        isolated deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }
}
