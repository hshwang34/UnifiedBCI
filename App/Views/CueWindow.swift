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
    private let displayID: UInt32?
    private let displayName: String
    private var geometry: CueDisplayGeometry?
    private var observer: NSObjectProtocol?
    /// Called when the participant display's frame, resolution or refresh changes, or it
    /// goes away. A run pauses; `reframe()` fits the window again before Resume.
    var onDisplayChange: (() -> Void)?

    init(scheduler: CueFrameScheduler, screen: NSScreen) {
        self.scheduler = scheduler
        displayID = Self.displayID(screen)
        displayName = screen.localizedName
        geometry = CueDisplayGeometry(screen)
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
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    /// The participant display as it is now; nil when it is gone.
    var screen: NSScreen? {
        NSScreen.screens.first { Self.displayID($0) == displayID } ?? NSScreen.screens.first { $0.localizedName == displayName }
    }

    /// One frame on the participant display now (falls back to 60 Hz when it reports none).
    var framePeriodNanos: Int64 { 1_000_000_000 / Int64(max(1, screen?.maximumFramesPerSecond ?? 60)) }

    private func screensChanged() {
        let now = screen.map(CueDisplayGeometry.init)
        guard now != geometry else { return }
        geometry = now
        onDisplayChange?()
    }

    /// Fits the window to the participant display again. False when that display is gone.
    @discardableResult
    func reframe() -> Bool {
        guard let screen else { return false }
        geometry = CueDisplayGeometry(screen)
        panel.setFrame(screen.frame, display: true)
        return true
    }

    /// Shows the window without activating the app or taking focus.
    func show() {
        view.resetStallClock()      // a hidden window's paused callbacks are not a stall
        panel.orderFrontRegardless()
    }

    /// Steps aside (one display, between runs); `show` brings it back.
    func hide() { panel.orderOut(nil) }

    var isVisible: Bool { panel.isVisible }

    /// Live feedback (brief 006): the bar or its words, drawn under the cross during cues.
    var feedback: FeedbackFeed? {
        get { view.feedback }
        set { view.feedback = newValue }
    }

    /// Stops the display link and drops frames not yet drawn (never reported).
    func close() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        onDisplayChange = nil
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

    fileprivate static func displayID(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// What a run depends on about its display: where it is, its pixels and its refresh.
struct CueDisplayGeometry: Equatable {
    let frame: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshHz: Int

    init(frame: CGRect, pixelWidth: Int, pixelHeight: Int, refreshHz: Int) {
        self.frame = frame; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.refreshHz = refreshHz
    }

    @MainActor init(_ screen: NSScreen) {
        let id = CueWindowController.displayID(screen) ?? 0
        self.init(frame: screen.frame, pixelWidth: CGDisplayPixelsWide(id), pixelHeight: CGDisplayPixelsHigh(id),
                  refreshHz: screen.maximumFramesPerSecond)
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
/// Nothing ever animates (implicit layer actions are off), so Reduce Motion holds as is:
/// the feedback bar jumps to each new length on the refresh that reports it.
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
    private var lastCallback: CFTimeInterval?
    private var frameShown: CueFrame = .blank
    var feedback: FeedbackFeed?
    private let bar = CAShapeLayer()
    private let track = CAShapeLayer()
    private let feedbackWords = NSTextField(labelWithString: "")
    private var feedbackShown: FeedbackPolicy.Display = .hidden(words: nil)

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
        for (shape, alpha) in [(track, CueWindowModel.feedbackTrackAlpha), (bar, 1.0)] {
            shape.fillColor = Self.inkColor.withAlphaComponent(alpha).cgColor
            shape.actions = ["path": NSNull(), "hidden": NSNull(), "position": NSNull(), "bounds": NSNull()]
            shape.isHidden = true
            layer?.addSublayer(shape)
        }
        feedbackWords.textColor = Self.inkColor.withAlphaComponent(CueWindowModel.feedbackWordsAlpha)
        feedbackWords.alignment = .center
        feedbackWords.isHidden = true
        addSubview(feedbackWords)
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

    func resetStallClock() { lastCallback = nil }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let media = CACurrentMediaTime()
        let mono = HostMonotonicClock.nowNanos()
        let target = PresentationClock.monotonicNanos(mediaTime: link.targetTimestamp, sampledMonotonicNanos: mono, sampledMediaTime: media)
        let stall = lastCallback.map { PresentationClock.isStall(sinceLast: link.timestamp - $0, framePeriod: link.targetTimestamp - link.timestamp) } ?? false
        lastCallback = link.timestamp
        // An unknown refresh time still draws what is due now, but reports nothing: the
        // runner stores that phase with no presented time.
        let next = scheduler.take(forRefreshAt: target ?? mono)
        if let next { apply(next.frame) }
        let shown = feedback?.take(cueOnScreen: { if case .cue = frameShown { true } else { false } }())
        if let shown { applyFeedback(shown.display) }
        if let next, let target { next.sink.presented(next.token, atMonotonicNanos: target, afterStall: stall) }
        // Feedback is logged either way; an unknown refresh time is logged as unknown.
        if let shown { feedback?.presented(shown, at: target) }
    }

    private func applyFeedback(_ display: FeedbackPolicy.Display) {
        feedbackShown = display
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutFeedback()
        CATransaction.commit()
    }

    /// The bar grows from the centre line toward its class's side; hidden, its words (if
    /// any) take the same place, so a hidden bar is never mistaken for a short one.
    private func layoutFeedback() {
        let unit = Self.unit(bounds), y = bounds.midY - unit * CueWindowModel.feedbackDrop
        let half = unit * CueWindowModel.feedbackHalfWidth, height = unit * CueWindowModel.feedbackHeight
        switch feedbackShown {
        case .bar(let side, let length):
            let dir = feedback?.directions[side] ?? 1
            let w = max(half * CGFloat(min(max(length, 0), 1)), unit * CueWindowModel.feedbackMinimum)
            // The bar and the centre line in full ink; the track faint behind them.
            let tick = unit * CueWindowModel.feedbackTick, t = unit * CueWindowModel.crossStroke / 2
            let solid = CGMutablePath()
            solid.addRect(CGRect(x: dir < 0 ? bounds.midX - w : bounds.midX, y: y - height / 2, width: w, height: height))
            solid.addRect(CGRect(x: bounds.midX - t / 2, y: y - tick / 2, width: t, height: tick))
            bar.path = solid
            track.path = CGPath(rect: CGRect(x: bounds.midX - half, y: y - height / 2, width: 2 * half, height: height), transform: nil)
            bar.isHidden = false
            track.isHidden = false
            feedbackWords.isHidden = true
        case .hidden(let words):
            bar.isHidden = true
            track.isHidden = true
            feedbackWords.stringValue = words ?? ""
            feedbackWords.font = .systemFont(ofSize: max(13, unit * CueWindowModel.feedbackWordsSize), weight: .medium)
            feedbackWords.sizeToFit()
            let size = feedbackWords.frame.size
            feedbackWords.frame = NSRect(x: bounds.midX - size.width / 2, y: y - size.height / 2, width: size.width, height: size.height)
            feedbackWords.isHidden = words == nil
        }
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
        bar.frame = bounds
        track.frame = bounds
        layoutFeedback()
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
