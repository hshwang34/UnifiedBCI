import AppKit
import QuartzCore
import SwiftUI

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

    /// Live feedback (brief 006): the bar or its words, drawn under the cue during cues.
    var feedback: FeedbackFeed? {
        get { view.feedback }
        set { view.feedback = newValue }
    }

    /// The card between trials (brief 010): instructions, pause, break, session done. Drawn
    /// only over instructions or blank frames; a fixation or cue hides it on its own refresh.
    func showParticipant(_ screen: ParticipantScreen?, context: ParticipantRunContext?) {
        view.setParticipant(screen, context: context)
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
///
/// Measured phases never animate (brief 010): implicit layer actions are off, the cue glyphs
/// are rendered at layout, and a fixation or cue frame only toggles `isHidden` on finished
/// layers, so the cross, the cue and the bar appear at full contrast on the reported refresh
/// and stay still. The cue *replaces* the cross (decision #57). The feedback bar jumps to each
/// new length on the refresh that reports it (decision #59). Only the cards between trials
/// (`ParticipantCardHost`) fade, and only over the background.
private final class CueView: NSView {
    static let backgroundColor = NSColor(srgbRed: CueWindowModel.background.r, green: CueWindowModel.background.g,
                                         blue: CueWindowModel.background.b, alpha: 1)
    private static let inkColor = NSColor(srgbRed: CueWindowModel.ink.r, green: CueWindowModel.ink.g, blue: CueWindowModel.ink.b, alpha: 1)
    private static let barColor = NSColor(srgbRed: CueWindowModel.feedbackBar.r, green: CueWindowModel.feedbackBar.g,
                                          blue: CueWindowModel.feedbackBar.b, alpha: 1)
    private static let hiddenCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)
    private static let noActions: [String: any CAAction] = ["path": NSNull(), "hidden": NSNull(), "position": NSNull(), "bounds": NSNull(),
                                                           "contents": NSNull(), "frame": NSNull(), "fillColor": NSNull()]

    private let scheduler: CueFrameScheduler
    private let cross = CAShapeLayer()
    /// The cue: a pre-rendered SF Symbol (`glyphs`), or the drawn arrow if a symbol can't render.
    private let glyph = CALayer()
    private let arrow = CAShapeLayer()
    private var glyphs: [CueSymbol: CGImage] = [:]
    private var glyphScale: CGFloat = 2
    private var link: CADisplayLink?
    private var lastCallback: CFTimeInterval?
    private var frameShown: CueFrame = .blank
    var feedback: FeedbackFeed?
    private let bar = CAShapeLayer()
    private let centreLine = CAShapeLayer()
    private let track = CAShapeLayer()
    private let feedbackWords = NSTextField(labelWithString: "")
    private var feedbackShown: FeedbackPolicy.Display = .hidden(words: nil)
    // Cards between trials.
    private let cardState = ParticipantCardState()
    private let cards: ParticipantCardHost
    private var screen: ParticipantScreen? = .instructions
    private var context: ParticipantRunContext?

    init(scheduler: CueFrameScheduler) {
        self.scheduler = scheduler
        cards = ParticipantCardHost(rootView: ParticipantCardStage(state: cardState))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Self.backgroundColor.cgColor
        for shape in [cross, arrow, centreLine] {
            shape.fillColor = Self.inkColor.cgColor
        }
        track.fillColor = Self.inkColor.withAlphaComponent(CueWindowModel.feedbackTrackAlpha).cgColor
        bar.fillColor = Self.barColor.cgColor
        for l in [cross, arrow, glyph, track, bar, centreLine] as [CALayer] {
            l.actions = Self.noActions
            l.isHidden = true
            layer?.addSublayer(l)
        }
        glyph.contentsGravity = .resizeAspect
        cards.appearance = NSAppearance(named: .darkAqua)
        cards.isHidden = true
        addSubview(cards)
        feedbackWords.textColor = Self.inkColor.withAlphaComponent(CueWindowModel.feedbackWordsAlpha)
        feedbackWords.alignment = .center
        feedbackWords.isHidden = true
        addSubview(feedbackWords)
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

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
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
        // The stale rule at presentation: a bar too old for this refresh, or after a stall, hides.
        let shown = feedback?.take(cueOnScreen: { if case .cue = frameShown { true } else { false } }(), targetNanos: target, stall: stall)
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
            // A capsule from the centre line; the line itself in full ink over it.
            let rect = CGRect(x: dir < 0 ? bounds.midX - w : bounds.midX, y: y - height / 2, width: w, height: height)
            bar.path = Self.capsule(rect)
            let tickHeight = unit * CueWindowModel.feedbackTick, t = unit * CueWindowModel.crossStroke / 2
            centreLine.path = Self.capsule(CGRect(x: bounds.midX - t / 2, y: y - tickHeight / 2, width: t, height: tickHeight))
            track.path = Self.capsule(CGRect(x: bounds.midX - half, y: y - height / 2, width: 2 * half, height: height))
            bar.isHidden = false
            centreLine.isHidden = false
            track.isHidden = false
            feedbackWords.isHidden = true
        case .hidden(let words):
            bar.isHidden = true
            centreLine.isHidden = true
            track.isHidden = true
            feedbackWords.stringValue = words ?? ""
            feedbackWords.font = Self.rounded(size: max(13, unit * CueWindowModel.feedbackWordsSize), weight: .medium)
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
        case .instructions, .blank:
            cross.isHidden = true
            hideCue()
            updateCards(animated: true)
        case .fixation:
            hideCards()
            hideCue()
            cross.isHidden = false
        case .cue(let symbol):
            // The cue replaces the cross on the same refresh: one swap, nothing in between.
            hideCards()
            cross.isHidden = true
            showCue(symbol)
        }
        CATransaction.commit()
    }

    private func hideCue() {
        glyph.isHidden = true
        arrow.isHidden = true
    }

    /// Reveals the finished glyph layer (rendered at layout): nothing is drawn at onset.
    private func showCue(_ symbol: CueSymbol) {
        if let image = glyphs[symbol] {
            let size = CGSize(width: CGFloat(image.width) / glyphScale, height: CGFloat(image.height) / glyphScale)
            glyph.contents = image
            glyph.contentsScale = glyphScale
            glyph.frame = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
            glyph.isHidden = false
            arrow.isHidden = true
        } else {
            arrow.path = Self.arrowPath(in: bounds, angle: CueWindowModel.symbolAngle(symbol))
            arrow.isHidden = false
            glyph.isHidden = true
        }
    }

    // MARK: Cards between trials

    func setParticipant(_ screen: ParticipantScreen?, context: ParticipantRunContext?) {
        self.screen = screen
        if let context { self.context = context }
        switch frameShown {
        case .instructions, .blank: updateCards(animated: true)
        case .fixation, .cue: break        // shown at the next instructions or blank frame
        }
    }

    private var reduceMotion: Bool { LaunchArguments.reduceMotion(system: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) }

    private func updateCards(animated: Bool) {
        let text: String? = { if case .instructions(let t) = frameShown { t } else { nil } }()
        let card = ParticipantCardModel.make(instructionsText: text, screen: screen, context: context)
        guard card != cardState.card else { return }
        cardState.increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        if card != nil { cards.isHidden = false }
        if animated, !reduceMotion, !cards.isHidden {
            withAnimation(.smooth(duration: CueWindowModel.cardFadeSeconds)) { cardState.card = card }
        } else {
            cardState.card = card
        }
    }

    /// A measured phase is coming on this refresh: the cards go at once, with no fade left over.
    private func hideCards() {
        cards.isHidden = true
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { cardState.card = nil }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cross.frame = bounds
        arrow.frame = bounds
        bar.frame = bounds
        centreLine.frame = bounds
        track.frame = bounds
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        track.fillColor = Self.inkColor.withAlphaComponent(highContrast ? CueWindowModel.feedbackTrackAlphaHighContrast : CueWindowModel.feedbackTrackAlpha).cgColor
        layoutFeedback()
        cross.path = Self.crossPath(in: bounds)
        renderGlyphs()
        if case .cue(let symbol) = frameShown { showCue(symbol) }
        CATransaction.commit()
        cards.frame = bounds
    }

    /// Renders the four cue glyphs for this size and backing scale, ahead of any cue.
    private func renderGlyphs() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let length = Self.unit(bounds) * CueWindowModel.arrowLength
        guard length >= 1 else { return }
        glyphScale = scale
        glyphs = [:]
        for s in CueSymbol.allCases {
            if let image = Self.glyph(CueWindowModel.cueGlyph(s), length: length, scale: scale) { glyphs[s] = image }
        }
    }

    /// An SF Symbol in ink whose longer side is `length` points.
    private static func glyph(_ name: String, length: CGFloat, scale: CGFloat) -> CGImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let probe = NSImage.SymbolConfiguration(pointSize: 100, weight: .semibold)
        guard let natural = base.withSymbolConfiguration(probe)?.size, natural.width > 0, natural.height > 0 else { return nil }
        let k = length / max(natural.width, natural.height)
        let config = NSImage.SymbolConfiguration(pointSize: 100 * k, weight: .semibold).applying(.init(paletteColors: [inkColor]))
        guard let image = base.withSymbolConfiguration(config) else { return nil }
        let size = image.size
        let w = Int((size.width * scale).rounded(.up)), h = Int((size.height * scale).rounded(.up))
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// Sizes scale with the display's shorter side, so a portrait display looks the same.
    private static func unit(_ b: CGRect) -> CGFloat { min(b.width, b.height) }

    private static func rounded(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }

    private static func capsule(_ r: CGRect) -> CGPath {
        let radius = min(r.width, r.height) / 2
        return CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// Two round-ended bars merged into one outline, so the crossing has no anti-aliased seam.
    private static func crossPath(in b: CGRect) -> CGPath {
        let arm = unit(b) * CueWindowModel.crossArm, t = unit(b) * CueWindowModel.crossStroke
        let across = capsule(CGRect(x: b.midX - arm, y: b.midY - t / 2, width: 2 * arm, height: t))
        let down = capsule(CGRect(x: b.midX - t / 2, y: b.midY - arm, width: t, height: 2 * arm))
        return across.union(down)
    }

    /// The fallback arrow: pointing right through the centre, rotated to `angle` (y up).
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
