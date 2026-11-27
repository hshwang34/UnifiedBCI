import XCTest
@testable import BCIWorkspace

/// Decision #69: the Quick check session is a stored, derived protocol version, and its
/// results are labelled as a setup check.
final class QuickCheckTests: XCTestCase {
    private func record(_ draft: ProtocolDraft, version: Int = 1) -> ProtocolRecord {
        ProtocolRecord(draft: draft, parent: nil, version: version, createdAt: Date(timeIntervalSince1970: 0))
    }

    func testDraftKeepsWhatTheParticipantSeesAndShortensTheSession() {
        let full = record(.grazDefault)
        let q = QuickCheck.draft(from: full)
        XCTAssertEqual(q.classes, full.classes)
        XCTAssertEqual(q.timing, full.timing)
        XCTAssertEqual(q.instructions, full.instructions)
        XCTAssertEqual(q.trialsPerClass, 8)
        XCTAssertEqual(q.runsPerSession, 3)
        XCTAssertTrue(q.name.hasSuffix(QuickCheck.nameSuffix))
        XCTAssertEqual(QuickCheck.draft(from: record(q)).name, q.name, "a quick check of a quick check is itself")
    }

    func testRecognisesAndReusesTheStoredVersion() {
        let full = record(.grazDefault)
        let q = QuickCheck.draft(from: full)
        let v1 = record(q, version: 1), v2 = record(q, version: 2)
        XCTAssertTrue(QuickCheck.isQuickCheck(v1))
        XCTAssertFalse(QuickCheck.isQuickCheck(full))
        XCTAssertEqual(QuickCheck.existing(for: q, in: [full, v1, v2])?.version, 2)
        var other = q; other.timing.cueMs += 500
        XCTAssertNil(QuickCheck.existing(for: other, in: [full, v1, v2]), "a different timing is a different protocol")
    }

    func testFormTogglesRunsAndRestoresTheProtocolsOwnCount() {
        let full = record(.grazDefault)
        var form = StartRunForm(protocols: [full], displays: [], remembered: nil, seed: 1)
        XCTAssertEqual(form.runsPerSession, 4)
        form.setQuickCheck(true)
        XCTAssertEqual(form.runsPerSession, 3)
        form.setQuickCheck(false)
        XCTAssertEqual(form.runsPerSession, 4)
    }
}
