import AppKit
import QuartzCore

/// The participant's full-screen cue window (brief 005 PR 5). A borderless panel that never
/// becomes key or main, so on a two-display setup the operator's window keeps focus and the
/// keyboard shortcuts keep working; with one display it covers everything and the operator
/// uses the keyboard (decision #36).
@MainActor
final class CueWindowController {
    static let identifier = NSUserInterfaceItemIdentifier("BCICueWindow")

    let scheduler: CueFrameScheduler
    private let panel: CuePanel
    private let view: CueView

    init(scheduler: CueFrameScheduler, screen: NSScreen) {
        self.scheduler = scheduler
        panel = CuePanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        view = CueView(scheduler: scheduler)
        panel.identifier = Self.identifier
        panel.title = "Participant"
        panel.contentView = view
        panel.setFrame(screen.frame, display: false)
        // Above the menu bar of its display; the operator's alerts stay reachable on a second display.
        panel.level = .statusBar
        panel.isOpaque = true
        panel.backgroundColor = CueView.backgroundColor
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
    }

    /// Shows the window without activating the app or taking focus.
    func show() { panel.orderFrontRegardless() }

    var isVisible: Bool { panel.isVisible }

    /// Stops the display link and drops frames not yet drawn (never reported).
    func close() {
        view.stop()
        scheduler.clear()
        panel.orderOut(nil)
        panel.close()
    }

    // MARK: Displays

    static func displays(operatorScreen: NSScreen?) -> [CueDisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let id = displayID(screen) else { return nil }
            return CueDisplayInfo(id: id, name: screen.localizedName, width: CGDisplayPixelsWide(id), height: CGDisplayPixelsHigh(id),
                                  isOperator: operatorScreen.map { displayID($0) == id } ?? (screen == NSScreen.main))
        }
    }

    static func screen(for display: CueDisplayInfo) -> NSScreen? {
        NSScreen.screens.first { displayID($0) == display.id } ?? NSScreen.screens.first { $0.localizedName == display.name }
    }

    private static func displayID(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

private final class CuePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Draws one `CueFrame` with layers and reports presentation from its display link: each
/// refresh takes the newest due frame for that refresh's target presentation time, sets it,
/// and reports that target time (converted to `HostMonotonicClock` by an offset sampled in
/// the same callback). That is the app's own callback, not light leaving the screen.
/// Nothing ever animates (implicit layer actions are off), so Reduce Motion holds as is.
private final class CueView: NSView {
    static let backgroundColor = NSColor(srgbRed: CueWindowModel.background.r, green: CueWindowModel.background.g,
                                         blue: CueWindowModel.background.b, alpha: 1)
    private static let inkColor = NSColor(srgbRed: CueWindowModel.ink.r, green: CueWindowModel.ink.g, blue: CueWindowModel.ink.b, alpha: 1)
    private static let hiddenCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    private let scheduler: CueFrameScheduler
    private let cross = CAShapeLayer()
    private let arrow = CAShapeLayer()
    private let instructions = NSTextField(wrappingLabelWithString: "")
    private var link: CADisplayLink?
    private var frameShown: CueFrame = .blank

    init(scheduler: CueFrameScheduler) {
        self.scheduler = scheduler
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Self.backgroundColor.cgColor
        for shape in [cross, arrow] {
            shape.fillColor = Self.inkColor.cgColor
            shape.actions = ["path": NSNull(), "hidden": NSNull(), "position": NSNull(), "bounds": NSNull()]
            shape.isHidden = true
            layer?.addSublayer(shape)
        }
        instructions.textColor = Self.inkColor
        instructions.alignment = .center
        instructions.isSelectable = false
        instructions.isHidden = true
        addSubview(instructions)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, link == nil else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let media = CACurrentMediaTime()
        let mono = HostMonotonicClock.nowNanos()
        let target = PresentationClock.monotonicNanos(mediaTime: link.targetTimestamp, sampledMonotonicNanos: mono, sampledMediaTime: media)
        guard let next = scheduler.take(forRefreshAt: target) else { return }
        apply(next.frame)
        next.sink.presented(next.token, atMonotonicNanos: target)
    }

    private func apply(_ frame: CueFrame) {
        frameShown = frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch frame {
        case .instructions(let text):
            instructions.stringValue = text
            layoutInstructions()
            instructions.isHidden = false
            cross.isHidden = true
            arrow.isHidden = true
        case .fixation:
            instructions.isHidden = true
            cross.isHidden = false
            arrow.isHidden = true
        case .cue(let symbol):
            instructions.isHidden = true
            cross.isHidden = false
            arrow.path = Self.arrowPath(in: bounds, angle: CueWindowModel.symbolAngle(symbol))
            arrow.isHidden = false
        case .blank:
            instructions.isHidden = true
            cross.isHidden = true
            arrow.isHidden = true
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cross.frame = bounds
        arrow.frame = bounds
        cross.path = Self.crossPath(in: bounds)
        if case .cue(let symbol) = frameShown { arrow.path = Self.arrowPath(in: bounds, angle: CueWindowModel.symbolAngle(symbol)) }
        CATransaction.commit()
        layoutInstructions()
    }

    private func layoutInstructions() {
        instructions.font = .systemFont(ofSize: max(14, Self.unit(bounds) * CueWindowModel.instructionsSize), weight: .regular)
        let width = bounds.width * CueWindowModel.instructionsWidth
        instructions.preferredMaxLayoutWidth = width
        let size = instructions.sizeThatFits(NSSize(width: width, height: bounds.height))
        instructions.frame = NSRect(x: bounds.midX - width / 2, y: bounds.midY - size.height / 2, width: width, height: size.height)
    }

    /// Sizes scale with the display's shorter side, so a portrait display looks the same.
    private static func unit(_ b: CGRect) -> CGFloat { min(b.width, b.height) }

    private static func crossPath(in b: CGRect) -> CGPath {
        let arm = unit(b) * CueWindowModel.crossArm, t = unit(b) * CueWindowModel.crossStroke
        let path = CGMutablePath()
        path.addRect(CGRect(x: b.midX - arm, y: b.midY - t / 2, width: 2 * arm, height: t))
        path.addRect(CGRect(x: b.midX - t / 2, y: b.midY - arm, width: t, height: 2 * arm))
        return path
    }

    /// An arrow pointing right through the centre, rotated to `angle` (y up).
    private static func arrowPath(in b: CGRect, angle: Double) -> CGPath {
        let h = unit(b)
        let length = h * CueWindowModel.arrowLength, shaft = h * CueWindowModel.arrowShaft
        let head = h * CueWindowModel.arrowHead, headLength = h * CueWindowModel.arrowHeadLength
        let tail = -length / 2, tip = length / 2, neck = tip - headLength
        let points: [CGPoint] = [
            .init(x: tail, y: -shaft / 2), .init(x: neck, y: -shaft / 2), .init(x: neck, y: -head / 2), .init(x: tip, y: 0),
            .init(x: neck, y: head / 2), .init(x: neck, y: shaft / 2), .init(x: tail, y: shaft / 2),
        ]
        let transform = CGAffineTransform(translationX: b.midX, y: b.midY).rotated(by: angle)
        let path = CGMutablePath()
        path.addLines(between: points, transform: transform)
        path.closeSubpath()
        return path
    }

    // The cursor is hidden over the participant window only, even while it isn't key.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { Self.hiddenCursor.set() }
}
