import AppKit
import SwiftUI

/// The live preview's plot (brief 004), drawn by an AppKit view that repaints itself.
///
/// Brief 009: the plot used to be a SwiftUI `Canvas` inside a `TimelineView`. Every tick was
/// a SwiftUI update transaction, and with the inspector's split view in the window each one
/// ran a layout pass over the whole window. That cost ~30% of the main thread while
/// streaming, kept the sidebar and list from ever populating, and during the inspector's
/// collapse animation became the layout storm that corrupted the main actor and crashed the
/// app. `needsDisplay` repaints this view only: no layout, no SwiftUI graph update.
struct LivePlotView: NSViewRepresentable {
    let buffer: PreviewBuffer?
    let labels: [String]
    let lanes: Int
    let scale: LivePreviewModel.Scale
    let streaming: Bool
    /// The last auto lane height drawn (for the card's accessibility label).
    let onHeight: (Double) -> Void

    func makeNSView(context: Context) -> PlotNSView { PlotNSView() }

    func updateNSView(_ view: PlotNSView, context: Context) {
        view.configure(buffer: buffer, labels: labels, lanes: lanes, scale: scale, streaming: streaming, onHeight: onHeight)
    }

    static func dismantleNSView(_ view: PlotNSView, coordinator: ()) { view.stop() }
}

@MainActor
final class PlotNSView: NSView {
    static let laneHeight: CGFloat = 21
    static let labelWidth: CGFloat = 52
    static let gap: CGFloat = 8
    /// At most 15 repaints a second, and none while no new frame has arrived.
    static let interval: TimeInterval = 1.0 / 15

    private var buffer: PreviewBuffer?
    private var labels: [String] = []
    private var lanes = 1
    private var scale: LivePreviewModel.Scale = .auto
    private var onHeight: (Double) -> Void = { _ in }
    private var timer: Timer?
    private var drawnFrame = -2
    private var autoHeight: Double?
    private var autoMeasured = Date.distantPast

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    // The plot is a picture: hit tests and accessibility belong to the card around it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    func configure(buffer: PreviewBuffer?, labels: [String], lanes: Int, scale: LivePreviewModel.Scale, streaming: Bool,
                   onHeight: @escaping (Double) -> Void) {
        let changed = buffer !== self.buffer || labels != self.labels || lanes != self.lanes || scale != self.scale
        self.buffer = buffer; self.labels = labels; self.lanes = lanes; self.scale = scale; self.onHeight = onHeight
        if changed { drawnFrame = -2; needsDisplay = true }
        if streaming { start() } else { stop() }
    }

    private func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let frame = buffer?.framesIngested ?? -1
        if frame != drawnFrame { needsDisplay = true }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// The theme's asset colours as AppKit colours (same names as `Theme`; App/Assets.xcassets),
    /// resolved for this view's appearance by `performAsCurrentDrawingAppearance`.
    private func asset(_ name: String) -> NSColor {
        // Resolved to concrete components in the current (drawing) appearance before any
        // CGColor is taken from it; a catalog colour's cgColor otherwise came out white.
        let c = NSColor(named: name) ?? .labelColor
        return c.usingColorSpace(.sRGB) ?? c
    }

    private func text(_ s: String, size: CGFloat = NSFont.smallSystemFontSize, weight: NSFont.Weight = .regular,
                      color c: NSColor) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: c])
    }

    override func draw(_ dirtyRect: NSRect) {
        drawnFrame = buffer?.framesIngested ?? -1
        // Resolve the asset colours for this view's appearance (light/dark, increased contrast).
        effectiveAppearance.performAsCurrentDrawingAppearance { self.drawPlot() }
    }

    private func drawPlot() {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let size = bounds.size
        let plotX = Self.labelWidth, plotW = max(1, size.width - plotX - Self.gap)
        let plotH = Self.laneHeight * CGFloat(lanes)
        let secondary = asset("textSecondary")

        ctx.setFillColor(asset("surface2").withAlphaComponent(0.55).cgColor)
        for i in 0..<lanes where i % 2 == 1 {
            ctx.fill(CGRect(x: 0, y: Self.laneHeight * CGFloat(i), width: size.width, height: Self.laneHeight))
        }

        // The lane-height caption sits at the bottom-left; a tick label that would collide
        // with it is left out (it used to overprint, e.g. "auto8 s").
        let height = currentHeight()
        let caption = text(LivePreviewModel.heightText(height, auto: scale == .auto), color: secondary)
        caption.draw(at: CGPoint(x: 0, y: plotH + 3))
        let captionEnd = caption.size().width + Self.gap

        // Text drawing (NSAttributedString) changes the context's colours, so every stroke
        // sets its own colour right before it.
        let hairline = asset("hairline").cgColor
        for t in LivePreviewModel.ticks {
            let x = plotX + plotW * CGFloat(t + 10) / 10
            ctx.setStrokeColor(hairline); ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: plotH)); ctx.strokePath()
            guard t > LivePreviewModel.ticks[0] else { continue }
            let label = text(LivePreviewModel.tickLabel(t), color: secondary)
            let w = label.size().width
            let left = t == 0 ? x - w : x - w / 2
            guard left > captionEnd else { continue }
            label.draw(at: CGPoint(x: left, y: plotH + 3))
        }

        guard let buffer else {
            let waiting = text(LivePreviewModel.waiting, size: NSFont.systemFontSize, color: secondary)
            let s = waiting.size()
            waiting.draw(at: CGPoint(x: plotX + (plotW - s.width) / 2, y: (plotH - s.height) / 2))
            return
        }
        let window = buffer.window()
        let model = LivePreviewModel(window: window, labels: labels, columns: Int(plotW), height: height)
        let colW = plotW / CGFloat(max(1, Int(plotW)))

        ctx.saveGState()
        let warning = asset("warning").cgColor
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        for b in model.breakColumns.sorted() {
            let x = plotX + CGFloat(b) * colW
            ctx.setStrokeColor(warning); ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: plotH)); ctx.strokePath()
            text(LivePreviewModel.segmentTag, color: secondary).draw(at: CGPoint(x: x + 4, y: 2))
        }
        ctx.restoreGState()

        let unit = Self.laneHeight / CGFloat(max(height, 1e-9))
        let limit = Float(height / 2)
        let primary = asset("textPrimary")
        let ink = asset("accentInk").cgColor
        for (i, lane) in model.lanes.enumerated() {
            let mid = Self.laneHeight * (CGFloat(i) + 0.5)
            let name = text(lane.label, weight: .medium, color: primary)
            name.draw(at: CGPoint(x: Self.gap, y: mid - name.size().height / 2))
            ctx.setStrokeColor(ink); ctx.setLineWidth(1)
            func y(_ v: Float) -> CGFloat { mid - CGFloat(min(max(v, -limit), limit)) * unit }
            var open = false
            for (c, e) in lane.columns.enumerated() {
                guard let e else { open = false; continue }
                let x = plotX + (CGFloat(c) + 0.5) * colW
                // Nothing is drawn across the start of a new segment.
                if !open || model.breakColumns.contains(c) { ctx.move(to: CGPoint(x: x, y: y(e.lo))) } else { ctx.addLine(to: CGPoint(x: x, y: y(e.lo))) }
                ctx.addLine(to: CGPoint(x: x, y: y(e.hi)))
                open = true
            }
            ctx.strokePath()
        }
    }

    /// The fixed height, or the auto height re-measured every 2 s so it doesn't flicker.
    private func currentHeight() -> Double {
        switch scale {
        case .fixed(let h): return h
        case .auto:
            if let buffer, autoHeight == nil || Date().timeIntervalSince(autoMeasured) >= 2 {
                let w = buffer.window()
                if w.count > 0 {
                    autoHeight = LivePreviewModel.autoHeight(w)
                    autoMeasured = Date()
                    onHeight(autoHeight!)
                }
            }
            return autoHeight ?? 100
        }
    }
}
