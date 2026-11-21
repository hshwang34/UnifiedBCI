import XCTest
@testable import BCIWorkspace

/// Brief 005 PR 1: protocol records, run plans, `protocols/` storage and the seeded schedule.
final class ProtocolTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bci-proto-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    private func newStore(_ name: String = "p") throws -> ProjectStore {
        try ProjectStore.create(at: scratch.appendingPathComponent("\(name).bciproj"), name: name, now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private func recording(in store: ProjectStore) async throws -> UUID {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let m = RecordingManifest(
            recordingID: UUID(), sessionID: "S", runID: "R", createdAt: t0,
            source: .init(kind: "synthetic", boardID: nil, boardName: "test", dataPath: nil, brainflowVersion: "n/a", appVersion: "test"),
            channels: [ChannelSpec(id: "ch00", label: "C3", kind: "eeg", unit: "uV", sourceRow: 0)],
            reference: "SRB2", montage: "undeclared",
            timing: .init(nominalSampleRateHz: 125, timestampClock: .hostWall, timestampGeneratedBy: "none", sequenceCounterRow: nil, sequenceStep: 1, notes: ""),
            clockMapping: .init(anchorMonotonicNanos: 0, anchorWall: t0), boardConfiguration: .init(requested: [:], readback: [:]),
            chunks: [], segments: [])
        _ = try await store.createRecording(m)
        return m.recordingID
    }

    // MARK: Golden vectors (worker mirror: protocol_schedule.py)

    private struct Golden: Decodable {
        struct Raw: Decodable { let seed: String; let outputs: [String] }
        struct Below: Decodable { let seed: String; let n: String; let outputs: [String] }
        struct Cls: Decodable { let label: String; let cue: CueSymbol }
        struct Case: Decodable {
            let name: String, classes: [Cls], trialsPerClass: Int, timing: PhaseTiming, seed: String, runID: String
            let contentCanonical: String, contentHash: String, trials: [RunPlan.PlannedTrial]
        }
        let order: String
        let splitmix64: [Raw]
        let below: [Below]
        let schedules: [Case]
    }

    private func golden() throws -> Golden {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/protocol_schedule_golden.json")
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    }

    private func hex(_ s: String) throws -> UInt64 { try XCTUnwrap(UInt64(s.dropFirst(2), radix: 16), s) }

    func testGoldenVectors_splitMix64AndBelow() throws {
        let g = try golden()
        XCTAssertEqual(g.order, ProtocolRecord.orderSeededShuffleV1)
        // Published SplitMix64 reference value for seed 0, independent of our generator.
        XCTAssertEqual(g.splitmix64.first?.outputs.first, "0xe220a8397b1dcdaf")
        for raw in g.splitmix64 {
            var rng = SplitMix64(seed: try hex(raw.seed))
            XCTAssertEqual(try raw.outputs.map(hex), raw.outputs.map { _ in rng.next() }, raw.seed)
        }
        for b in g.below {
            var rng = SplitMix64(seed: try hex(b.seed))
            let n = try hex(b.n)
            XCTAssertEqual(try b.outputs.map(hex), b.outputs.map { _ in rng.below(n) }, "\(b.seed) below \(b.n)")
        }
    }

    func testGoldenVectors_schedulesAndContentHashes() throws {
        let g = try golden()
        XCTAssertEqual(g.schedules.count, 7)
        for c in g.schedules {
            let draft = ProtocolDraft(name: c.name, classes: c.classes.map { .init(label: $0.label, displayName: $0.label, cue: $0.cue) },
                                      timing: c.timing, trialsPerClass: c.trialsPerClass, runsPerSession: 4, instructions: "Ready.")
            let p = ProtocolRecord(draft: draft, parent: nil)
            XCTAssertNil(p.problem(directoryID: p.protocolID), c.name)
            XCTAssertEqual(String(decoding: ProtocolRecord.canonicalContent(classes: p.classes, timing: p.timing, trialsPerClass: p.trialsPerClass, order: p.order), as: UTF8.self),
                           c.contentCanonical, c.name)
            XCTAssertEqual(p.contentHash, c.contentHash, c.name)
            XCTAssertEqual(ProtocolSchedule.trials(p, seed: try hex(c.seed), runID: c.runID), c.trials, c.name)
        }
    }

    func testDefaultProtocolMatchesDecisions28And37_andItsGoldenHash() throws {
        let d = ProtocolDraft.grazDefault
        XCTAssertEqual(d.name, "Left vs right hand (Graz-style)")
        XCTAssertEqual(d.classes.map(\.label), ["cue_left_hand", "cue_right_hand"])
        XCTAssertEqual(d.classes.map(\.cue), [.leftArrow, .rightArrow])
        XCTAssertEqual(d.timing, PhaseTiming(fixationMs: 2000, cueMs: 4000, restMinMs: 1500, restMaxMs: 2500))
        XCTAssertEqual(d.trialsPerClass, 20)
        XCTAssertEqual(d.runsPerSession, 4)
        XCTAssertEqual(ProtocolRecord.problems(d), [])
        let p = ProtocolRecord(draft: d, parent: nil)
        XCTAssertEqual(p.contentHash, try golden().schedules[0].contentHash)
        let trials = ProtocolSchedule.trials(p, seed: 9, runID: "RUN")
        XCTAssertEqual(trials.count, 40)
        XCTAssertEqual(trials.filter { $0.label == "cue_left_hand" }.count, 20, "exactly N per class")
        XCTAssertTrue(trials.allSatisfy { (1500...2500).contains($0.restMs) })
        XCTAssertEqual(trials.first?.trialID, "RUN-t01")
        XCTAssertEqual(trials.last?.trialID, "RUN-t40")
        XCTAssertEqual(RunPlan.trialID(runID: "R", index: 99), "R-t100")
    }

    func testRunSeedIsSessionSeedPlusRunIndex_andPlansAreDeterministic() {
        let p = ProtocolRecord(draft: .grazDefault, parent: nil)
        let rec = UUID(), at = Date(timeIntervalSince1970: 1_800_000_000)
        let a = ProtocolSchedule.plan(p, recordingID: rec, sessionID: "S", runID: "R2", runIndex: 2, sessionSeed: 42, createdAt: at)
        let b = ProtocolSchedule.plan(p, recordingID: rec, sessionID: "S", runID: "R2", runIndex: 2, sessionSeed: 42, createdAt: at)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.seed, 44)
        XCTAssertEqual(a.trials, ProtocolSchedule.trials(p, seed: 44, runID: "R2"))
        XCTAssertNotEqual(a.trials, ProtocolSchedule.trials(p, seed: 45, runID: "R2"))
        XCTAssertEqual(a.protocolContentHash, p.contentHash)
        XCTAssertNil(a.problem(recordingID: rec, fileRunID: "R2"))
        XCTAssertLessThan(ProtocolSchedule.drawSessionSeed(), RunPlan.sessionSeedLimit)
    }

    // MARK: Validation

    func testValidationNamesEveryRule() {
        var d = ProtocolDraft.grazDefault
        d.classes.append(.init(label: "cue_right_hand", displayName: "", cue: .upArrow))
        d.classes[0].label = "Left Hand"
        d.timing = .init(fixationMs: 0, cueMs: 30_001, restMinMs: 2000, restMaxMs: 1000)
        d.trialsPerClass = 101
        d.runsPerSession = 0
        d.instructions = "  "
        d.name = "x\u{202E}"
        XCTAssertEqual(ProtocolRecord.problems(d), [
            .text("name"), .classCount(3), .label("Left Hand"), .duplicateLabel("cue_right_hand"), .text("display name"),
            .duration("fixation"), .duration("cue"), .restRange, .trialsPerClass(101), .runsPerSession(0), .text("instructions"),
        ])
        var reserved = ProtocolDraft.grazDefault
        reserved.classes[1].label = "trial_abort"
        XCTAssertEqual(ProtocolRecord.problems(reserved), [.reservedLabel("trial_abort")])
        XCTAssertEqual(ProtocolProblem.classCount(3).description, "this recipe needs exactly two classes, not 3")
        XCTAssertEqual(ProtocolProblem.duration("cue").description, "cue must be more than 0 s and at most 30 s")
        var ok = ProtocolDraft.grazDefault
        ok.timing = .init(fixationMs: 1, cueMs: 30_000, restMinMs: 700, restMaxMs: 700)
        ok.trialsPerClass = 1
        ok.instructions = "Line one.\n\nLine two."
        XCTAssertEqual(ProtocolRecord.problems(ok), [], "bounds are inclusive; equal rest bounds and line breaks are fine")
    }

    func testStoredRecordChecks_tamperedHashOrVersionChainIsRefused() {
        let v1 = ProtocolRecord(draft: .grazDefault, parent: nil)
        XCTAssertNil(v1.problem(directoryID: v1.protocolID))
        XCTAssertEqual(v1.problem(directoryID: UUID()), .directoryMismatch)
        var tampered = v1
        tampered.timing.cueMs = 3000
        XCTAssertEqual(tampered.problem(directoryID: v1.protocolID), .contentHash)
        var renamed = v1
        renamed.name = "Renamed"
        XCTAssertNil(renamed.problem(directoryID: v1.protocolID), "the name is not part of the content hash")
        var orphanV2 = v1
        orphanV2.version = 2
        XCTAssertEqual(orphanV2.problem(directoryID: v1.protocolID), .version)
        var order = v1
        order.order = "block_v9"
        XCTAssertEqual(order.problem(directoryID: v1.protocolID), .order("block_v9"))
        var future = v1
        future.formatVersion = 2
        XCTAssertEqual(future.problem(directoryID: v1.protocolID), .format(2))
    }

    // MARK: Store

    func testNewProjectHasTheDefaultV1_andEditsMakeNewVersions() async throws {
        let store = try newStore()
        let (initial, unreadable) = try await store.protocols()
        XCTAssertEqual(unreadable, 0)
        let v1 = try XCTUnwrap(initial.first)
        XCTAssertEqual(initial.count, 1)
        XCTAssertEqual(v1.draft, .grazDefault)
        XCTAssertEqual(v1.version, 1)
        XCTAssertNil(v1.basedOn)
        let ensured = try await store.ensureDefaultProtocol()
        XCTAssertNil(ensured, "a project that has a protocol gets no second default")

        var edit = v1.draft
        edit.timing.cueMs = 5000
        let v2 = try await store.createProtocolVersion(edit, basedOn: v1)
        XCTAssertEqual(v2.version, 2)
        XCTAssertEqual(v2.basedOn, v1.protocolID)
        XCTAssertEqual(v2.lineageID, v1.lineageID)
        XCTAssertNotEqual(v2.contentHash, v1.contentHash)
        // Editing v1 again still continues the lineage after the newest version.
        edit.trialsPerClass = 10
        let v3 = try await store.createProtocolVersion(edit, basedOn: v1)
        XCTAssertEqual(v3.version, 3)
        XCTAssertEqual(v3.basedOn, v1.protocolID)

        let reopened = try ProjectStore.open(at: store.directory)
        let listed = try await reopened.protocols().protocols
        XCTAssertEqual(listed.map(\.version), [1, 2, 3], "older versions stay listed")
        XCTAssertEqual(listed[0], v1, "v1 is untouched")

        do {
            _ = try await store.createProtocolVersion(v2.draft, basedOn: v2)
            XCTFail("an unchanged draft is not a new version")
        } catch ProjectStoreError.invalidProtocol(let why) { XCTAssertEqual(why, "nothing changed from version 2") }
        var bad = v1.draft
        bad.trialsPerClass = 0
        do {
            _ = try await store.createProtocolVersion(bad, basedOn: v1)
            XCTFail("invalid drafts are refused")
        } catch ProjectStoreError.invalidProtocol(let why) { XCTAssertEqual(why, "trials per class must be 1–100, not 0") }
        do {
            try ProjectStore.writeProtocol(v1, in: store.directory)
            XCTFail("a stored version is never overwritten")
        } catch ProjectStoreError.alreadyExists {}
    }

    func testOlderProjectWithoutProtocolsGetsTheDefaultOnRequest() async throws {
        let store = try newStore()
        try FileManager.default.removeItem(at: store.directory.appendingPathComponent("protocols"))
        let none = try await store.protocols()
        XCTAssertEqual(none.protocols, [])
        let made = try await store.ensureDefaultProtocol()
        XCTAssertEqual(made?.draft, .grazDefault)
        let count = try await store.protocols().protocols.count
        XCTAssertEqual(count, 1)
    }

    func testHostileProtocolFilesAreSkippedAndCounted() async throws {
        let store = try newStore()
        let fm = FileManager.default
        func file(_ id: UUID) throws -> URL {
            let d = store.directory.appendingPathComponent("protocols").appendingPathComponent(id.uuidString)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            return d.appendingPathComponent(ProjectStore.protocolFileName)
        }
        let enc = ContractJSON.encoder()
        var tampered = ProtocolRecord(draft: .grazDefault, parent: nil)
        tampered.trialsPerClass = 100_000                                  // also fails the hash
        try enc.encode(tampered).write(to: try file(tampered.protocolID))
        let moved = ProtocolRecord(draft: .grazDefault, parent: nil)       // id ≠ directory
        try enc.encode(moved).write(to: try file(UUID()))
        try Data("{not json".utf8).write(to: try file(UUID()))
        var padded = try enc.encode(ProtocolRecord(draft: .grazDefault, parent: nil))
        padded.append(Data(repeating: 0x20, count: ProtocolRecord.maxFileBytes))
        let paddedID = UUID()
        try padded.write(to: try file(paddedID))
        let outside = scratch.appendingPathComponent("outside.json")
        let linked = ProtocolRecord(draft: .grazDefault, parent: nil)
        try enc.encode(linked).write(to: outside)
        try fm.createSymbolicLink(at: try file(linked.protocolID), withDestinationURL: outside)
        XCTAssertEqual(mkfifo(try file(UUID()).path, 0o600), 0)
        let (listed, unreadable) = try await store.protocols()             // a FIFO open would block here
        XCTAssertEqual(listed.count, 1, "only the project's own default")
        XCTAssertEqual(unreadable, 6)
        let usage = try await store.protocolUsage()
        XCTAssertEqual(usage, [:])
    }

    func testRunPlansAreWrittenOnce_readBack_andCountedPerProtocol() async throws {
        let store = try newStore()
        let rec = try await recording(in: store)
        let v1 = try await store.protocols().protocols[0]
        var edit = v1.draft
        edit.trialsPerClass = 2
        let v2 = try await store.createProtocolVersion(edit, basedOn: v1)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let plans = [ProtocolSchedule.plan(v1, recordingID: rec, sessionID: "S", runID: "run-0", runIndex: 0, sessionSeed: 7, createdAt: at),
                     ProtocolSchedule.plan(v1, recordingID: rec, sessionID: "S", runID: "run-1", runIndex: 1, sessionSeed: 7, createdAt: at),
                     ProtocolSchedule.plan(v2, recordingID: rec, sessionID: "S", runID: "run-2", runIndex: 2, sessionSeed: 7, createdAt: at)]
        for plan in plans { try await store.writeRunPlan(plan) }
        let back = try await store.runPlans(recording: rec)
        XCTAssertEqual(back.plans, plans)
        XCTAssertEqual(back.unreadable, 0)
        let usage = try await store.protocolUsage()
        XCTAssertEqual(usage, [v1.protocolID: 2, v2.protocolID: 1])
        do {
            try await store.writeRunPlan(plans[0])
            XCTFail("a plan is never replaced")
        } catch ProjectStoreError.alreadyExists {}
        var unsafe = plans[0]
        unsafe.runID = "../escape"
        do {
            try await store.writeRunPlan(unsafe)
            XCTFail("a run id that is not a plain file name is refused")
        } catch ProjectStoreError.invalidRunPlan {}
        let nowhere = ProtocolSchedule.plan(v1, recordingID: UUID(), sessionID: nil, runID: "x", runIndex: 0, sessionSeed: 1)
        do {
            try await store.writeRunPlan(nowhere)
            XCTFail("a plan needs its recording")
        } catch ProjectStoreError.missingRecording {}
        let none = try await store.runPlans(recording: UUID())
        XCTAssertEqual(none.plans, [], "a recording without runs/ has no plans")
    }

    func testHostileRunPlansAreSkippedWithoutCrashing() async throws {
        let store = try newStore()
        let rec = try await recording(in: store)
        let v1 = try await store.protocols().protocols[0]
        let good = ProtocolSchedule.plan(v1, recordingID: rec, sessionID: nil, runID: "good", runIndex: 0, sessionSeed: 1,
                                         createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        try await store.writeRunPlan(good)
        let runs = store.directory.appendingPathComponent("recordings/\(rec.uuidString)/runs")
        let enc = ContractJSON.encoder()
        func plant(_ p: RunPlan, as runID: String) throws {
            try enc.encode(p).write(to: runs.appendingPathComponent(runID + ProjectStore.runPlanSuffix))
        }
        var wrongName = good; wrongName.runID = "other"
        try plant(wrongName, as: "named-differently")
        var overflow = good; overflow.runID = "overflow"
        overflow.trials[1].cueOffsetMs = Int.min                            // would trap if subtracted unchecked
        overflow.trials[2].endOffsetMs = Int.max
        try plant(overflow, as: "overflow")
        var gap = good; gap.runID = "gap"
        gap.trials[3].fixationOffsetMs += 1
        try plant(gap, as: "gap")
        var seed = good; seed.runID = "seed"
        seed.seed = seed.sessionSeed + 5
        try plant(seed, as: "seed")
        var big = good; big.runID = "big"; big.sessionSeed = UInt64.max; big.runIndex = 3
        try plant(big, as: "big")
        var label = good; label.runID = "label"
        label.trials[0].label = "Left"
        try plant(label, as: "label")
        try Data("[]".utf8).write(to: runs.appendingPathComponent("junk" + ProjectStore.runPlanSuffix))
        let (plans, unreadable) = try await store.runPlans(recording: rec)
        XCTAssertEqual(plans, [good])
        XCTAssertEqual(unreadable, 7)
        // A `runs` symlink planted in a hostile project is neither read nor written through.
        let rec2 = try await recording(in: store)
        let outside = scratch.appendingPathComponent("outside-runs", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: store.directory.appendingPathComponent("recordings/\(rec2.uuidString)/runs"), withDestinationURL: outside)
        do {
            try await store.writeRunPlan(ProtocolSchedule.plan(v1, recordingID: rec2, sessionID: nil, runID: "r", runIndex: 0, sessionSeed: 1))
            XCTFail("writes never follow a planted link")
        } catch ProjectStoreError.invalidManifest {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
        let linked = try await store.runPlans(recording: rec2)
        XCTAssertEqual(linked.plans, [])
    }

    func testOpenSweepsAnOrphanedTempPlan() async throws {
        let store = try newStore()
        let rec = try await recording(in: store)
        let runs = store.directory.appendingPathComponent("recordings/\(rec.uuidString)/runs", isDirectory: true)
        try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: runs.appendingPathComponent(".tmp-R.plan.json"))
        let reopened = try ProjectStore.open(at: store.directory)
        let removed = await reopened.removedOrphans
        XCTAssertEqual(removed, ["runs/.tmp-R.plan.json"])
    }

    // MARK: Marker row

    func testMarkerRowIsOptional_roundTrips_andMustBeAChunkRow() throws {
        let old = #"{"nominalSampleRateHz":125,"notes":"","sequenceStep":1,"timestampClock":"host_wall","timestampGeneratedBy":"none"}"#
        XCTAssertNil(try ContractJSON.decoder().decode(TimingSemantics.self, from: Data(old.utf8)).markerRow, "recordings before brief 005")
        let t = TimingSemantics(nominalSampleRateHz: 125, timestampClock: .brainflowReceipt, timestampGeneratedBy: "host",
                                sequenceCounterRow: 0, sequenceStep: 2, notes: "", markerRow: 31)
        XCTAssertEqual(try ContractJSON.decoder().decode(TimingSemantics.self, from: ContractJSON.encoder().encode(t)), t)
        let daisy = try BrainFlowBoard.describe(boardID: KnownBoard.cytonDaisy)
        XCTAssertTrue((0..<daisy.numRows).contains(daisy.markerRow))

        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var m = RecordingManifest(
            recordingID: UUID(), sessionID: nil, runID: "r", createdAt: t0,
            source: .init(kind: "synthetic", boardID: nil, boardName: "t", dataPath: nil, brainflowVersion: "n/a", appVersion: "t"),
            channels: [ChannelSpec(id: "ch00", label: "C3", kind: "eeg", unit: "uV", sourceRow: 0)], reference: "SRB2", montage: "undeclared",
            timing: t, clockMapping: .init(anchorMonotonicNanos: 0, anchorWall: t0), boardConfiguration: .init(requested: [:], readback: [:]),
            chunks: [.init(index: 0, fileName: "chunks/000000.f64", segment: 0, firstSampleIndex: 0, sampleCount: 1, rowCount: 32, sha256: "",
                           drainedAtMonotonicNanos: 0, firstBrainflowTimestamp: nil, lastBrainflowTimestamp: nil, firstPackageNumber: nil, lastPackageNumber: nil)],
            segments: [])
        XCTAssertNoThrow(try RecordingHandle.validate(m))
        m.timing.markerRow = 32
        XCTAssertThrowsError(try RecordingHandle.validate(m))
    }
}
