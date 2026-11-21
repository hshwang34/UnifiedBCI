import XCTest
@testable import BCIWorkspace

/// Brief 005 PR 4: the Protocols section's list, detail and "New version…" editor models.
@MainActor
final class ProtocolScreenTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bci-pscreen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    private func store() throws -> ProjectStore {
        try ProjectStore.create(at: scratch.appendingPathComponent("p.bciproj"), name: "p")
    }

    func testSeconds_onTheMillisecondGrid_withoutFloatRounding() {
        XCTAssertEqual([2000, 1500, 2250, 1, 30000, 1001].map(Fmt.seconds(ms:)), ["2 s", "1.5 s", "2.25 s", "0.001 s", "30 s", "1.001 s"])
        XCTAssertEqual([0, 1, 2, 7].map(Fmt.usedIn), ["Not used yet", "Used in 1 run", "Used in 2 runs", "Used in 7 runs"])
        XCTAssertEqual(Fmt.duration(ms: 320_000), "5 min 20 s")
        XCTAssertEqual(Fmt.duration(ms: 48_000), "48 s")
    }

    func testParseMilliseconds_namesWhatIsWrong_neverOverflows() {
        let ok: [(String, Int)] = [("2", 2000), ("1.5", 1500), (" 0.250 ", 250), (".5", 500), ("3.", 3000), ("2.5000", 2500), ("0.001", 1)]
        for (text, ms) in ok { XCTAssertEqual(ProtocolEditor.parseMilliseconds(text), .success(ms), text) }
        XCTAssertEqual(ProtocolEditor.parseMilliseconds(""), .failure(.empty))
        for text in ["-1", "1e3", "1,5", "two", ".", "1.2.3", "+2", "9999999999999999999"] {
            XCTAssertEqual(ProtocolEditor.parseMilliseconds(text), .failure(.notANumber), text)
        }
        XCTAssertEqual(ProtocolEditor.parseMilliseconds("2.0005"), .failure(.tooPrecise))
    }

    func testListGroupsLineages_newestFirst_withUseAndUnreadableNote() async throws {
        let s = try store()
        _ = try await s.ensureDefaultProtocol()          // a new project already has it
        let v1 = try await s.protocols().protocols[0]
        var d = ProtocolDraft.grazDefault
        d.timing.cueMs = 3000
        let v2 = try await s.createProtocolVersion(d, basedOn: v1)
        var other = ProtocolDraft.grazDefault
        other.name = "Feet vs hands"
        _ = try await s.createProtocolVersion(other, basedOn: nil)
        let bad = s.directory.appendingPathComponent("protocols/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: bad.appendingPathComponent("protocol.json"))
        let list = try await s.protocols()
        let model = ProtocolListModel(list: list, usage: [v1.protocolID: 3])
        XCTAssertEqual(model.groups.map(\.title), ["Feet vs hands", "Left vs right hand (Graz-style)"])
        XCTAssertEqual(model.groups[1].rows.map(\.version), ["v2", "v1"])
        XCTAssertEqual(model.groups[1].rows.map(\.id), [v2.protocolID, v1.protocolID])
        XCTAssertEqual(model.groups[1].rows.map(\.usedIn), ["Not used yet", "Used in 3 runs"])
        XCTAssertEqual(model.footnote, "1 protocol file couldn't be read and isn't listed.")
        XCTAssertTrue(model.groups.allSatisfy { $0.rows.allSatisfy { !$0.mislinked } })
        XCTAssertEqual(model.groups[1].rows[1].accessibility, "Left vs right hand (Graz-style), version 1, used in 3 runs")
    }

    func testDetail_showsTimingClassesHashAndTheWindowWarning() throws {
        let r = ProtocolRecord(draft: .grazDefault, parent: nil)
        let list = ProtocolList(protocols: [r], unreadable: 0, mislinked: [], lineages: [:])
        let m = ProtocolDetailModel(r, list: list, usage: [:], windowEndMs: 4000)
        XCTAssertEqual(m.badge, "v1")
        XCTAssertEqual(m.lineage, "Version 1")
        XCTAssertEqual(m.timing.map(\.value).prefix(6), ["2 s", "4 s", "1.5–2.5 s, drawn per trial", "20 (40 per run)", "4", "about 5 min 20 s of trials"])
        XCTAssertEqual(m.classes.map(\.label), ["cue_left_hand", "cue_right_hand"])
        XCTAssertEqual(m.classes.map(\.cue), ["Left arrow", "Right arrow"])
        XCTAssertEqual(m.identity.first, .init(label: "Content hash", value: r.contentHash, mono: true))
        XCTAssertTrue(m.warnings.isEmpty, "a 4 s cue holds the 0.5 + 3.5 s window")
        XCTAssertTrue(m.canCreateVersion)
        let longer = ProtocolDetailModel(r, list: list, usage: [:], windowEndMs: 4500)
        XCTAssertEqual(longer.warnings, ["The cue (4 s) ends before the default evaluation window does (4.5 s), so that window won't fit inside the cue."])
        let mislinked = ProtocolDetailModel(r, list: .init(protocols: [r], unreadable: 0, mislinked: [r.protocolID], lineages: [:]), usage: [:], windowEndMs: 4000)
        XCTAssertFalse(mislinked.canCreateVersion)
        XCTAssertEqual(mislinked.warnings, [ProtocolCopy.mislinked])
    }

    func testEditor_refusesIdenticalDraft_reservedLabels_offGridAndOutOfRange() {
        let v1 = ProtocolRecord(draft: .grazDefault, parent: nil)
        let e = ProtocolEditor(base: v1, lineage: [v1], windowEndMs: 4000)
        XCTAssertEqual(e.subtitle, "Saves as v2, based on v1. v1 stays as it is.")
        XCTAssertEqual(e.fixation, "2")
        XCTAssertEqual(e.issues.map(\.text), ["Nothing changed from v1. Change a value to save a new version."])
        XCTAssertFalse(e.canSave)

        e.cue = "4.0005"
        e.fixation = "0"
        e.classes[1].label = "rest"
        e.trialsPerClass = "101"
        let texts = e.issues.map(\.text)
        XCTAssertTrue(texts.contains("Cue can have at most 3 decimal places: durations are kept to the millisecond."), "\(texts)")
        XCTAssertTrue(texts.contains("Fixation must be more than 0 s and at most 30 s."), "\(texts)")
        XCTAssertTrue(texts.contains("“rest” is the name of a protocol event. Choose another label."), "\(texts)")
        XCTAssertTrue(texts.contains("Trials per class must be 1–100."), "\(texts)")
        XCTAssertNil(e.draft)
        XCTAssertFalse(e.canSave)

        e.cue = "4"; e.fixation = "2"; e.trialsPerClass = "20"
        e.classes[1].label = "Cue-Right"
        XCTAssertEqual(e.issues.map(\.text), ["Label “Cue-Right” may only use a–z, 0–9 and _, 1–48 characters."])
        e.classes[1].label = "cue_left_hand"
        XCTAssertEqual(e.issues.map(\.text), ["Both classes use the label “cue_left_hand”. Labels must differ."])
        e.classes[1].label = "cue_right_hand"
        e.restMin = "3"
        XCTAssertEqual(e.issues.map(\.text), ["Shortest rest must not be longer than longest rest."])
        e.restMin = "1.5"
        e.cue = "3.25"
        XCTAssertEqual(e.issues.map(\.kind), [.warning], "a short cue warns but saves")
        XCTAssertTrue(e.canSave)
        XCTAssertEqual(e.draft?.timing.cueMs, 3250)
    }

    func testDefaultIsWrittenOnlyOnEnteringTheSection_neverOverAnUnreadableFile() async throws {
        let s = try store()
        let dir = s.directory.appendingPathComponent("protocols")
        try FileManager.default.removeItem(at: dir)                  // an older project: no protocols
        let session = await ProjectSession.adopt(s, url: s.directory, launch: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "opening a project never writes")
        session.section = .protocols
        await session.awaitProtocols()
        XCTAssertEqual(session.protocolList?.protocols.count, 1)
        await session.shutdown()

        try FileManager.default.removeItem(at: dir)
        let bad = dir.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: bad.appendingPathComponent("protocol.json"))
        let made = try await s.ensureDefaultProtocol()
        XCTAssertNil(made, "an unreadable protocol is still a protocol: no default over it")
    }

    func testStoreErrors_inPlainWords_readOnlyNamed() {
        XCTAssertEqual(ProtocolCopy.notSaved(ProjectStoreError.io("write", EROFS)), "Not saved: the project can't be written to.")
        XCTAssertEqual(ProtocolCopy.notSaved(ProjectStoreError.invalidProtocol("nothing changed from version 1")),
                       "Not saved: nothing changed from version 1.")
        XCTAssertEqual(ProtocolCopy.notSaved(ProjectStoreError.io("write", ENOSPC)), "Not saved: the disk is full.")
        XCTAssertFalse(ProtocolCopy.unreadableList(ProjectStoreError.invalidManifest("x")).contains("invalidManifest"))
        XCTAssertEqual(ProtocolCopy.defaultNotSaved(ProjectStoreError.io("mkdir", EACCES), writable: false),
                       "This project can't be written to, so the default protocol couldn't be added. Open a copy in a folder you can write to.")
    }

    func testWholeNumberFields_nameEmptyOrInvalidInput_andTheCreatedTimeIsUTC() {
        let v1 = ProtocolRecord(draft: .grazDefault, parent: nil, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let e = ProtocolEditor(base: v1, lineage: [v1], windowEndMs: 4000)
        e.trialsPerClass = ""
        e.runsPerSession = "4x"
        XCTAssertTrue(e.issues.map(\.text).contains("Trials per class must be a whole number."))
        XCTAssertTrue(e.issues.map(\.text).contains("Runs per session must be a whole number."))
        XCTAssertFalse(e.canSave)
        XCTAssertEqual(ProtocolDetailModel.created(v1.createdAt), "2027-01-15 08:00 UTC")
    }

    func testSession_listsTheDefault_savesANewVersionAndSelectsIt() async throws {
        let s = try store()
        let session = await ProjectSession.adopt(s, url: s.directory, launch: nil)
        session.section = .protocols
        await session.awaitProtocols()
        let v1 = try XCTUnwrap(session.selectedProtocol)
        XCTAssertEqual(v1.name, ProtocolDraft.grazDefault.name)
        session.newProtocolVersion(of: v1)
        let editor = try XCTUnwrap(session.protocolEditor)
        editor.runsPerSession = "6"
        await session.saveProtocolEditor()
        XCTAssertNil(session.protocolEditor)
        XCTAssertEqual(session.selectedProtocol?.version, 2)
        XCTAssertEqual(session.selectedProtocol?.basedOn, v1.protocolID)
        XCTAssertEqual(session.protocolList?.protocols.count, 2, "v1 stays listed")
        await session.shutdown()
    }
}
