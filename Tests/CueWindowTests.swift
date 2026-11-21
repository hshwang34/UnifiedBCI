import Synchronization
import XCTest
@testable import BCIWorkspace

/// Brief 005 PR 5: the participant window's frame queue (what is drawn and reported per
/// refresh), the display-link clock conversion, and the display picker (decision #36).
final class CueWindowTests: XCTestCase {
    private final class Sink: PresentationSink {
        let reports = Mutex<[(UInt64, Int64)]>([])
        func presented(_ token: PresentationToken, atMonotonicNanos at: Int64) { reports.withLock { $0.append((token.value, at)) } }
    }

    private func t(_ v: UInt64) -> PresentationToken { PresentationToken(value: v) }

    // MARK: Frame queue

    func testRefreshDrawsTheFirstFrameAtOrAfterItsTime() {
        let sink = Sink()
        var q = CueFrameQueue()
        q.submit(.fixation, at: 1_000, token: t(1), sink: sink)
        XCTAssertNil(q.take(forRefreshAt: 999), "a refresh before the frame's time draws nothing")
        let drawn = q.take(forRefreshAt: 1_000)
        XCTAssertEqual(drawn?.frame, .fixation)
        XCTAssertEqual(drawn?.token, t(1))
        XCTAssertNil(q.take(forRefreshAt: 2_000), "a frame is drawn once")
    }

    func testANewFrameDropsPendingFramesAtOrAfterIt() {
        let sink = Sink()
        var q = CueFrameQueue()
        q.submit(.fixation, at: 1_000, token: t(1), sink: sink)
        q.submit(.cue(.leftArrow), at: 2_000, token: t(2), sink: sink)
        q.submit(.blank, at: 3_000, token: t(3), sink: sink)
        // Abort: blank now replaces the cue and the planned rest.
        q.submit(.blank, at: 1_500, token: t(4), sink: sink)
        XCTAssertEqual(q.pending.map(\.token), [t(1), t(4)])
    }

    func testARefreshDrawsTheNewestDueFrameAndNeverReportsTheOvertakenOne() {
        let sink = Sink()
        var q = CueFrameQueue()
        q.submit(.fixation, at: 1_000, token: t(1), sink: sink)
        q.submit(.cue(.rightArrow), at: 1_200, token: t(2), sink: sink)
        q.submit(.blank, at: 5_000, token: t(3), sink: sink)
        // A late refresh (main thread busy) covers both the fixation and the cue.
        let drawn = q.take(forRefreshAt: 1_300)
        XCTAssertEqual(drawn?.token, t(2))
        XCTAssertEqual(q.pending.map(\.token), [t(3)])
    }

    func testSchedulerReportsTheRefreshTargetTime() {
        let sink = Sink()
        let scheduler = CueFrameScheduler()
        scheduler.show(.fixation, atMonotonicNanos: 10_000, token: t(7), sink: sink)
        if let p = scheduler.take(forRefreshAt: 16_667) { p.sink.presented(p.token, atMonotonicNanos: 16_667) }
        let reports = sink.reports.withLock { $0 }
        XCTAssertEqual(reports.map(\.0), [7])
        XCTAssertEqual(reports.map(\.1), [16_667], "presented is the refresh's target time, never the intended time")
        scheduler.show(.blank, atMonotonicNanos: 20_000, token: t(8), sink: sink)
        scheduler.clear()
        XCTAssertNil(scheduler.take(forRefreshAt: 30_000), "a closing window reports nothing it didn't draw")
    }

    // MARK: Clock conversion

    func testDisplayLinkTimeConvertsByTheOffsetSampledInTheCallback() {
        // Sampled together: media 100.000 s ↔ monotonic 5_000_000_000 ns. Target 8.3 ms later.
        XCTAssertEqual(PresentationClock.monotonicNanos(mediaTime: 100.0083, sampledMonotonicNanos: 5_000_000_000, sampledMediaTime: 100.0),
                       5_008_300_000, accuracy: 2)
        XCTAssertEqual(PresentationClock.monotonicNanos(mediaTime: .nan, sampledMonotonicNanos: 42, sampledMediaTime: 1), 42)
        XCTAssertEqual(PresentationClock.monotonicNanos(mediaTime: 1e300, sampledMonotonicNanos: 42, sampledMediaTime: 1), 42)
    }

    // MARK: Display picker (decision #36)

    private let laptop = CueDisplayInfo(id: 1, name: "Built-in Retina Display", width: 3024, height: 1964, isOperator: true)
    private let external = CueDisplayInfo(id: 4, name: "DELL U2723QE", width: 3840, height: 2160, isOperator: false)
    private let tv = CueDisplayInfo(id: 9, name: "LG TV", width: 1920, height: 1080, isOperator: false)

    func testASecondDisplayIsChosenWhenConnected() {
        let choice = CueDisplayPicker.choose(from: [laptop, external], remembered: nil)
        XCTAssertEqual(choice?.display, external)
        XCTAssertEqual(choice?.sharesOperatorDisplay, false)
    }

    func testOneDisplayGoesFullScreenOnIt() {
        let choice = CueDisplayPicker.choose(from: [laptop], remembered: nil)
        XCTAssertEqual(choice?.display, laptop)
        XCTAssertEqual(choice?.sharesOperatorDisplay, true)
        XCTAssertNil(CueDisplayPicker.choose(from: [], remembered: nil))
    }

    func testTheRememberedDisplayWinsAndAMissingOneFallsBack() {
        XCTAssertEqual(CueDisplayPicker.choose(from: [laptop, external, tv], remembered: .init(id: 9, name: "LG TV"))?.display, tv)
        // Re-plugged: a new id, the same name.
        let replugged = CueDisplayInfo(id: 12, name: "LG TV", width: 1920, height: 1080, isOperator: false)
        XCTAssertEqual(CueDisplayPicker.choose(from: [laptop, replugged], remembered: .init(id: 9, name: "LG TV"))?.display, replugged)
        // Gone: the default rule again.
        XCTAssertEqual(CueDisplayPicker.choose(from: [laptop, external], remembered: .init(id: 9, name: "LG TV"))?.display, external)
        // The operator's own display can be the remembered choice.
        XCTAssertEqual(CueDisplayPicker.choose(from: [laptop, external], remembered: .init(id: 1, name: laptop.name))?.display, laptop)
    }

    func testMemoryRoundTripsAndToleratesDamage() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "bci-cue-\(UUID().uuidString)"))
        XCTAssertNil(CueDisplayPicker.remembered(in: defaults))
        CueDisplayPicker.remember(tv, in: defaults)
        XCTAssertEqual(CueDisplayPicker.remembered(in: defaults), .init(id: 9, name: "LG TV"))
        defaults.set(Data("{not json".utf8), forKey: CueDisplayPicker.defaultsKey)
        XCTAssertNil(CueDisplayPicker.remembered(in: defaults))
        defaults.set("a string", forKey: CueDisplayPicker.defaultsKey)
        XCTAssertNil(CueDisplayPicker.remembered(in: defaults))
    }

    func testCopyAndGeometry() {
        XCTAssertEqual(CueWindowModel.displayLabel(laptop), "Built-in Retina Display (3024 × 1964) · this window's display")
        XCTAssertEqual(CueWindowModel.displayLabel(external), "DELL U2723QE (3840 × 2160)")
        XCTAssertEqual(CueWindowModel.symbolAngle(.leftArrow), .pi)
        XCTAssertEqual(CueWindowModel.symbolAngle(.rightArrow), 0)
        // The arrow head is wider than the cross stroke and the arrow longer than the cross,
        // so a cue is never mistaken for the fixation cross.
        XCTAssertGreaterThan(CueWindowModel.arrowLength, 2 * CueWindowModel.crossArm)
        XCTAssertGreaterThan(CueWindowModel.arrowHead, CueWindowModel.crossStroke)
    }

    /// The window's ink on its background, WCAG: far above 7:1 (readable at a distance).
    func testContrast() {
        func lum(_ c: (r: Double, g: Double, b: Double)) -> Double {
            func ch(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b)
        }
        let ratio = (lum(CueWindowModel.ink) + 0.05) / (lum(CueWindowModel.background) + 0.05)
        XCTAssertGreaterThan(ratio, 12)
    }
}
