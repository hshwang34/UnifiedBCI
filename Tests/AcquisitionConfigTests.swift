import XCTest
@testable import BCIWorkspace

/// Brief 004 PR 4: board configuration and readback, channel maps, and the acquisition
/// screen models. No hardware (decision #26).
final class AcquisitionConfigTests: XCTestCase {
    private var scratch: URL!
    private let daisy = try! BrainFlowBoard.describe(boardID: KnownBoard.cytonDaisy)

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bci-cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    /// CONSTRUCTED from the firmware source (OpenBCI_Cyton_Library `printAllRegisters` /
    /// `RREGS` line format, power-on defaults), not captured from a board; checklist H2
    /// confirms the real reply. CRLF line ends, as the firmware's println sends.
    private func constructedDump() throws -> String {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "cyton_daisy_register_dump.constructed", withExtension: "txt"))
        return try String(contentsOf: url, encoding: .ascii)
    }

    // MARK: Commands and readback

    func testDefaultCommandsCoverAll16ChannelsWithTheDocumentedFormat() {
        let c = DefaultChannelSettings.commands
        XCTAssertEqual(c.count, 16)
        XCTAssertEqual(c.first, "x1060110X")
        XCTAssertEqual(c[8], "xQ060110X", "Daisy channel 9 is Q")
        XCTAssertEqual(c.last, "xI060110X")
        let r = DefaultChannelSettings.requested
        XCTAssertEqual(r["ch16.gain"], "24")
        XCTAssertEqual(r["ch01.input"], "normal")
        XCTAssertEqual(r["ch09.bias"], "included")
        XCTAssertEqual(r["ch12.srb2"], "connected")
    }

    func testConstructedDumpParsesBothBoards() throws {
        let dump = try constructedDump()
        let rb = CytonRegisterReadback.parse(dump)
        XCTAssertEqual(rb["raw"], dump, "the raw reply is always kept")
        for n in 1...16 {
            let k = String(format: "ch%02d", n)
            XCTAssertEqual(rb[k + ".gain"], "24", k)
            XCTAssertEqual(rb[k + ".input"], "normal", k)
            XCTAssertEqual(rb[k + ".srb2"], "connected", k)
            XCTAssertEqual(rb[k + ".bias"], "included", k)
            XCTAssertEqual(rb[k + ".power"], "on", k)
        }
        XCTAssertNil(CytonRegisterReadback.gainMismatch(rb))
    }

    func testDaisyGainAndSettingsAreReadPerRegister() throws {
        // Daisy CH3SET (channel 11) = 0x41: gain 8, shorted input, SRB2 off; Daisy bias
        // excludes it; board CH2SET = 0xE8: powered down.
        var lines = try constructedDump().components(separatedBy: "\r\n")
        let daisyStart = try XCTUnwrap(lines.firstIndex(of: "Daisy ADS Registers"))
        let ch3 = try XCTUnwrap(lines[daisyStart...].firstIndex { $0.hasPrefix("CH3SET") })
        lines[ch3] = "CH3SET, 07, 41, 0, 1, 0, 0, 0, 0, 0, 1"
        let sensP = try XCTUnwrap(lines[daisyStart...].firstIndex { $0.hasPrefix("BIAS_SENSP") })
        lines[sensP] = "BIAS_SENSP, 0D, FB, 1, 1, 1, 1, 1, 0, 1, 1"
        let ch2 = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("CH2SET") })
        lines[ch2] = "CH2SET, 06, e8, 1, 1, 1, 0, 1, 0, 0, 0"       // lower-case hex accepted
        let rb = CytonRegisterReadback.parse(lines.joined(separator: "\r\n"))
        XCTAssertEqual(rb["ch11.gain"], "8")
        XCTAssertEqual(rb["ch11.input"], "shorted")
        XCTAssertEqual(rb["ch11.srb2"], "disconnected")
        XCTAssertEqual(rb["ch11.bias"], "excluded")
        XCTAssertEqual(rb["ch03.bias"], "included", "the board's own bias register is separate")
        XCTAssertEqual(rb["ch02.power"], "off")
        XCTAssertTrue(CytonRegisterReadback.gainMismatch(rb)! == (11, "8"))
        XCTAssertEqual(ConfigurationModel.gainMismatch(.init(requested: DefaultChannelSettings.requested, readback: rb)),
                       "Channel 11 reports gain 8; µV scaling assumes 24. Reconnect to reset.")
    }

    func testUnrecognisedReplyIsRawOnly_andEmptyReplyIsNoReadback() throws {
        XCTAssertEqual(CytonRegisterReadback.parse("Config:?"), ["raw": "Config:?"])
        XCTAssertEqual(CytonRegisterReadback.parse(" \r\n"), [:])
        // Board block only (no Daisy): never half a guess.
        let boardOnly = try constructedDump().components(separatedBy: "Daisy ADS Registers")[0]
        XCTAssertEqual(CytonRegisterReadback.parse(boardOnly).keys.sorted(), ["raw"])
        // Every command acknowledged: a missing `acknowledged` key would refuse Record (fail closed).
        var acked = DefaultChannelSettings.requested
        for n in 1...DefaultChannelSettings.channelCount { acked[DefaultChannelSettings.key(n) + ".acknowledged"] = "yes" }
        let rawOnly = RecordingManifest.BoardConfiguration(requested: acked, readback: ["raw": "?"])
        XCTAssertEqual(ConfigurationModel.readbackNote(rawOnly), ConfigurationModel.rawOnly)
        let none = RecordingManifest.BoardConfiguration(requested: DefaultChannelSettings.requested, readback: [:])
        XCTAssertEqual(ConfigurationModel.readbackNote(none), "No readback from this board")
        XCTAssertEqual(ConfigurationModel.rows(none)[0], .init(channel: "Channel 1", requested: "gain 24 · normal · bias included · SRB2 connected",
                                                               readback: "—", differs: false))
    }

    // MARK: Session wiring

    func testConnect_sendsDefaults_andReadsBackOnlyFromTheCyton() async throws {
        let link = FakeLink()
        link.set { $0.registerReply = try? self.constructedDump() }
        let serial = AcquisitionSession(source: .serial(port: "/dev/cu.fake"), projectDirectory: nil, makeBoard: link.factory)
        await serial.connect()
        XCTAssertEqual(serial.snapshot.state, .ready)
        XCTAssertEqual(link.value(\.commands), DefaultChannelSettings.commands + ["?"])
        let c = try XCTUnwrap(serial.snapshot.configuration)
        XCTAssertEqual(c.requested.filter { DefaultChannelSettings.requested[$0.key] != nil }, DefaultChannelSettings.requested)
        XCTAssertEqual(c.requested["ch09.command"], "xQ060110X")
        XCTAssertEqual(c.requested["ch16.acknowledged"], "yes")
        XCTAssertEqual(c.readback["ch16.reply"], "Success: Channel set for 1$$$")
        XCTAssertEqual(c.readback["ch16.gain"], "24")
        XCTAssertNil(RecordGate.warning(source: .serial(SerialPort(path: "/dev/cu.fake")), configuration: c))
        await serial.disconnect()
        XCTAssertNil(serial.snapshot.configuration)

        let synthLink = FakeLink()
        let synthetic = AcquisitionSession(source: .synthetic, projectDirectory: nil, makeBoard: synthLink.factory)
        await synthetic.connect()
        XCTAssertEqual(synthLink.value(\.commands), DefaultChannelSettings.commands, "no `?` to a board without registers")
        XCTAssertEqual(synthetic.snapshot.configuration?.readback, [:], "readback is never copied from requested")
        XCTAssertEqual(synthetic.snapshot.configuration?.requested["ch01.acknowledged"], "not applicable", "never a claimed success")
        await synthetic.disconnect()
    }

    func testGainMismatch_refusesRecord_andTheRecordingStoresTheConfiguration() async throws {
        var lines = try constructedDump().components(separatedBy: "\r\n")
        let ch1 = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("CH1SET") })
        lines[ch1] = "CH1SET, 05, 48, 0, 1, 0, 0, 1, 0, 0, 0"
        let link = FakeLink()
        link.set { $0.registerReply = lines.joined(separator: "\r\n") }
        let store = try ProjectStore.create(at: scratch.appendingPathComponent("p.bciproj"), name: "p")
        let session = AcquisitionSession(source: .serial(port: "/dev/cu.fake"), projectDirectory: nil, makeBoard: link.factory)
        await session.connect()
        await session.startStreaming()
        let request = AcquisitionSession.RecordingRequest(map: .defaults(for: daisy))
        do {
            try await session.startRecording(request, in: store)
            XCTFail("gain 8 must refuse Record")
        } catch let e as AcquisitionSession.SessionError {
            XCTAssertEqual(e, .configuration(.gainMismatch(channel: 1, gain: "8")))
        }
        await session.disconnect()

        link.set { $0.registerReply = try? self.constructedDump() }
        await session.connect()
        await session.startStreaming()
        let id = try await session.startRecording(request, in: store)
        await session.disconnect()
        let m = try await store.recording(id: id).manifest
        XCTAssertEqual(m.boardConfiguration.requested["ch01.acknowledged"], "yes")
        XCTAssertEqual(m.boardConfiguration.readback["ch01.gain"], "24")
        XCTAssertEqual(m.montage, "undeclared")
        XCTAssertEqual(m.reference, "SRB2")
    }

    // MARK: Channel maps

    func testChannelMaps_saveListAndPick_defaultsAreUndeclared() async throws {
        let store = try ProjectStore.create(at: scratch.appendingPathComponent("m.bciproj"), name: "m")
        let none = try await store.channelMaps()
        XCTAssertEqual(none.maps, [])
        var d = ChannelMapRecord.defaults(for: daisy)
        d.createdAt = Date(timeIntervalSince1970: 1_800_000_000)     // whole seconds: exact round trip
        XCTAssertEqual(d.montage, "undeclared")
        XCTAssertEqual(d.reference, "SRB2")
        XCTAssertEqual(d.channels.map(\.label), daisy.eegNames, "BrainFlow's names, never 10-20 guesses")
        var declared = d
        declared.mapID = UUID(); declared.createdAt = d.createdAt.addingTimeInterval(60)
        declared.montage = "10-20"; declared.channels[0].label = "C3"
        try await store.saveChannelMap(d)
        try await store.saveChannelMap(declared)
        let (maps, unreadable) = try await store.channelMaps()
        XCTAssertEqual(unreadable, 0)
        XCTAssertEqual(maps.map(\.mapID), [declared.mapID, d.mapID], "newest first")
        XCTAssertEqual(maps[0], declared)
        XCTAssertEqual(ChannelMapModel.pickerTitle(maps[0]), "10-20 · 16 channels · reference SRB2")
        // A reopened project still lists them; the directory is the truth.
        let reopened = try ProjectStore.open(at: store.directory)
        let again = try await reopened.channelMaps()
        XCTAssertEqual(again.maps.count, 2)
        // An older project without montages/ lists none.
        try FileManager.default.removeItem(at: store.directory.appendingPathComponent("montages"))
        let old = try await reopened.channelMaps()
        XCTAssertEqual(old.maps, [])
    }

    // MARK: Screen models

    func testRecordGate_followsStateGainAndMapChoice() {
        let ok = RecordingManifest.BoardConfiguration(requested: DefaultChannelSettings.requested, readback: [:])
        func gate(_ c: RecordingManifest.BoardConfiguration, _ map: ChannelMapChoice, state: AcquisitionSession.State = .streaming,
                  source: ConnectSource = .synthetic) -> String? {
            RecordGate.disabledReason(state: state, source: source, board: daisy, configuration: c, map: map)
        }
        XCTAssertEqual(gate(ok, .withoutPositions, state: .ready), "Start the preview to record.")
        XCTAssertEqual(gate(ok, .none), "Confirm a channel map, or choose Record without positions.")
        XCTAssertNil(gate(ok, .withoutPositions))
        XCTAssertNil(gate(ok, .confirmed(.defaults(for: daisy))))
        var eight = ChannelMapRecord.defaults(for: daisy)
        eight.channels = Array(eight.channels.prefix(8))
        XCTAssertEqual(gate(ok, .confirmed(eight)),
                       "This channel map's 8 channels don't match this board's 16 EEG channels. Pick another map or Record without positions.")
        let bad = RecordingManifest.BoardConfiguration(requested: ok.requested, readback: ["ch05.gain": "12"])
        XCTAssertEqual(gate(bad, .withoutPositions),
                       "Channel 5 reports gain 12; µV scaling assumes 24. Reconnect to reset.")
        XCTAssertEqual(ChannelMapModel.request(for: .withoutPositions, board: daisy)?.montage, "undeclared")
        XCTAssertNil(ChannelMapModel.request(for: .none, board: daisy))
    }

    func testSourcesAndStatusLine_sayDemoAndSyntheticHonestly() {
        let port = SerialPort(path: "/dev/cu.usbserial-DM01", vendorName: "FTDI", productName: "FT231X USB UART", isUSB: true)
        XCTAssertEqual(ConnectSource.demo.title, "Demo")
        XCTAssertEqual(AcquisitionStateModel.statusLine(.streaming, source: .demo, recording: false, reconnects: 0), "Streaming · Demo")
        XCTAssertEqual(ConnectSource.synthetic.title, "Synthetic board (no hardware)")
        XCTAssertEqual(AcquisitionStateModel.statusLine(.ready, source: .synthetic, recording: false, reconnects: 0),
                       "Ready · Synthetic board — generated signal, not a device")
        XCTAssertEqual(AcquisitionStateModel.statusLine(.streaming, source: .serial(port), recording: true, reconnects: 2),
                       "Recording · /dev/cu.usbserial-DM01 · reconnected 2×")
        XCTAssertEqual(ConnectSource.serial(port).title, "FT231X USB UART")
        XCTAssertEqual(ConnectSource.serial(port).caption, "FTDI · /dev/cu.usbserial-DM01")
        XCTAssertEqual(ConnectSource.gone(port), "/dev/cu.usbserial-DM01 is gone. Plug the dongle back in or pick another port.")
        XCTAssertEqual(AcquisitionStateModel.statusLine(.failed(reason: "Port busy"), source: .serial(port), recording: false, reconnects: 0),
                       "Failed: Port busy · /dev/cu.usbserial-DM01")
    }

    func testActionsFollowTheStateTable() {
        typealias M = AcquisitionStateModel
        XCTAssertEqual(M.actions(.disconnected, recording: false), [.connect])
        XCTAssertEqual(M.actions(.connecting, recording: false), [.cancel])
        XCTAssertEqual(M.actions(.ready, recording: false), [.startPreview, .disconnect])
        XCTAssertEqual(M.actions(.streaming, recording: true), [.stopRecording, .disconnect])
        XCTAssertEqual(M.actions(.interrupted(reason: "x"), recording: true), [.reconnectNow, .disconnect])
        XCTAssertEqual(M.actions(.stopping, recording: false), [])
        XCTAssertEqual(M.actions(.failed(reason: "x"), recording: false), [.retry, .disconnect])
        XCTAssertEqual(M.actions(.failed(reason: "x"), recording: false, afterStreaming: true), [.reconnect, .disconnect])
        XCTAssertNil(M.banner(.streaming))
        XCTAssertTrue(M.banner(.interrupted(reason: "No samples for 3 s"))!.contains("nothing is joined"))
    }

    func testIdentityRows() {
        let rows = IdentityModel.rows(board: daisy, source: .serial(SerialPort(path: "/dev/cu.x")), brainflowVersion: "5.12.1", firmware: nil)
        let dict = Dictionary(uniqueKeysWithValues: rows)
        XCTAssertEqual(dict["Board"], "\(daisy.name) (BrainFlow board 2)")
        XCTAssertEqual(dict["Firmware"], "not reported")
        XCTAssertEqual(dict["EEG channels"], "16")
        XCTAssertEqual(dict["Nominal rate"], "125 Hz")
        XCTAssertEqual(dict["Data path"], "radio_125")
        XCTAssertEqual(dict["Unit"], "µV")
        XCTAssertEqual(dict["Sequence step"], "2")
        let demo = Dictionary(uniqueKeysWithValues: IdentityModel.rows(board: daisy, source: .demo, brainflowVersion: "5", firmware: "v3.1.2"))
        XCTAssertEqual(demo["Firmware"], "v3.1.2")
        XCTAssertEqual(demo["Data path"], "none (Demo)")
    }

    func testHealthRows_diskWarningAndEndMessages() {
        var h = StreamHealth()
        h.samplesThisSegment = 1250
        h.effectiveRateHz = 124.84
        h.gaps[.sequenceSkip] = .init(events: 2, estimatedMissingSamples: 6, ambiguous: 2)
        h.arrivalPauses = 1
        h.drainInterval = .init(p50: 0.05, p95: 0.0624, max: 0.14)
        h.freeBytes = 90_000_000
        h.hoursLeft = 0
        var w = RecordingWriter.Status()
        w.lastCommitMonotonicNanos = 1_000_000_000
        h.writer = w
        let rows = Dictionary(uniqueKeysWithValues: HealthModel.rows(h, nowNanos: 1_400_000_000))
        XCTAssertEqual(rows["Effective rate"], "124.8 Hz")
        XCTAssertEqual(rows["Counter skips"], "2 · about 6 samples missing (2 ambiguous)")
        XCTAssertEqual(rows["Stale halves"], "none")
        XCTAssertEqual(rows["Arrival pauses"], "1 · arrival pause, no samples lost by counter")
        XCTAssertEqual(rows["Drain interval"], "p50 50 ms · p95 62 ms · max 140 ms")
        XCTAssertEqual(rows["Writer backlog"], "0 chunks")
        XCTAssertEqual(rows["Last commit"], "0.4 s ago")
        XCTAssertEqual(HealthModel.footer, "Stream health is about delivery, not signal quality.")
        XCTAssertEqual(HealthModel.ambiguousNote(step: 2), "Counter estimates are ambiguous: a loss of 128 samples or more looks like a smaller one.")
        XCTAssertEqual(RecordingEndModel.diskWarning(hoursLeft: 0.5, freeBytes: 150_000_000),
                       "Less than 1 hour of recording space left (150 MB free). Recording stops at 100 MB free.")
        XCTAssertNil(RecordingEndModel.diskWarning(hoursLeft: 2, freeBytes: 400_000_000))

        var full = RecordingWriter.Status()
        full.endReason = .diskFull; full.committedSamples = 125 * 42
        XCTAssertEqual(RecordingEndModel.message(full, rateHz: 125), "Recording stopped: disk full. 42 s recorded and saved.")
        var slow = RecordingWriter.Status()
        slow.endReason = .error; slow.committedSamples = 1250; slow.uncommittedSamples = 250
        slow.failure = "The disk could not keep up: 30 chunks waiting"
        XCTAssertEqual(RecordingEndModel.message(slow, rateHz: 125),
                       "The disk could not keep up. Recording stopped: 10 s recorded and saved, 2 s could not be saved.")
        var stopped = RecordingWriter.Status(); stopped.endReason = .stopped
        XCTAssertNil(RecordingEndModel.message(stopped, rateHz: 125))
    }
}

/// PR #25 review round: hostile maps, unacknowledged commands, reconnect re-check, headers.
final class AcquisitionConfigReviewTests: XCTestCase {
    private var scratch: URL!
    private let daisy = try! BrainFlowBoard.describe(boardID: KnownBoard.cytonDaisy)

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bci-cfg2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    private func dump() throws -> String {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "cyton_daisy_register_dump.constructed", withExtension: "txt"))
        return try String(contentsOf: url, encoding: .ascii)
    }

    private func plant(_ json: Data, as name: String, in store: ProjectStore) throws {
        let dir = store.directory.appendingPathComponent("montages").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.write(to: dir.appendingPathComponent(ProjectStore.channelMapFileName))
    }

    func testHostileSavedMapsAreSkippedAndCounted_andInvalidMapsAreNotSaved() async throws {
        let store = try ProjectStore.create(at: scratch.appendingPathComponent("h.bciproj"), name: "h")
        let good = ChannelMapRecord.defaults(for: daisy)
        try await store.saveChannelMap(good)
        let enc = ContractJSON.encoder()
        var moved = ChannelMapRecord.defaults(for: daisy)                      // id ≠ directory
        try plant(try enc.encode(moved), as: UUID().uuidString, in: store)
        var dupRow = ChannelMapRecord.defaults(for: daisy)
        dupRow.channels[1].sourceRow = dupRow.channels[0].sourceRow
        try plant(try enc.encode(dupRow), as: dupRow.mapID.uuidString, in: store)
        var future = ChannelMapRecord.defaults(for: daisy)
        future.formatVersion = 99
        try plant(try enc.encode(future), as: future.mapID.uuidString, in: store)
        var control = ChannelMapRecord.defaults(for: daisy)
        control.channels[0].label = "C3\u{0}"
        try plant(try enc.encode(control), as: control.mapID.uuidString, in: store)
        let garbage = UUID().uuidString
        try plant(Data("{not json".utf8), as: garbage, in: store)
        let (maps, unreadable) = try await store.channelMaps()
        XCTAssertEqual(maps.map(\.mapID), [good.mapID])
        XCTAssertEqual(unreadable, 5)
        XCTAssertEqual(ChannelMapModel.unreadable(unreadable), "5 saved maps couldn't be read and aren't listed.")
        XCTAssertEqual(ChannelMapModel.unreadable(1), "1 saved map couldn't be read and isn't listed.")
        XCTAssertNil(ChannelMapModel.unreadable(0))
        moved.channels[2].label = "   "
        do {
            try await store.saveChannelMap(moved)
            XCTFail("a blank label is refused")
        } catch ProjectStoreError.invalidChannelMap {}
    }

    func testStartRecording_refusesAMapThatIsNotThisBoardsEEGRows() async throws {
        let link = FakeLink()
        let store = try ProjectStore.create(at: scratch.appendingPathComponent("r.bciproj"), name: "r")
        let session = AcquisitionSession(source: .synthetic, projectDirectory: nil, makeBoard: link.factory)
        await session.connect()
        await session.startStreaming()
        var accel = ChannelMapRecord.defaults(for: daisy)
        accel.channels[15].sourceRow = 20                    // an accelerometer row, not EEG
        var short = ChannelMapRecord.defaults(for: daisy)
        short.channels.removeLast()
        for map in [accel, short] {
            do {
                try await session.startRecording(.init(map: map), in: store)
                XCTFail("map must not fit")
            } catch let e as AcquisitionSession.SessionError {
                XCTAssertEqual(e, .channelMapMismatch(mapChannels: map.channels.count, boardChannels: 16))
                XCTAssertTrue(RecordGate.message(e).hasPrefix("This channel map's"))
            }
        }
        let ids = try await store.recordingIDs()
        XCTAssertEqual(ids, [], "nothing written")
        await session.disconnect()
    }

    func testUnacknowledgedChannelCommand_isMarked_andRefusesRecordOnTheCyton() async throws {
        let link = FakeLink()
        link.set { $0.channelReply = "Failure: 9th char not X$$$"; $0.registerReply = try? self.dump() }
        let store = try ProjectStore.create(at: scratch.appendingPathComponent("a.bciproj"), name: "a")
        let session = AcquisitionSession(source: .serial(port: "/dev/cu.fake"), projectDirectory: nil, makeBoard: link.factory)
        await session.connect()
        let c = try XCTUnwrap(session.snapshot.configuration)
        XCTAssertEqual(c.requested["ch01.acknowledged"], "no")
        XCTAssertEqual(c.readback["ch01.reply"], "Failure: 9th char not X$$$")
        let row = ConfigurationModel.rows(c)[0]
        XCTAssertTrue(row.requested.hasSuffix("· not acknowledged by the board"), row.requested)
        XCTAssertTrue(row.differs)
        await session.startStreaming()
        do {
            try await session.startRecording(.init(map: .defaults(for: daisy)), in: store)
            XCTFail("unacknowledged settings refuse Record")
        } catch let e as AcquisitionSession.SessionError {
            XCTAssertEqual(e, .configuration(.notAcknowledged(channel: 1)))
            XCTAssertEqual(RecordGate.message(e), "Channel 1 did not acknowledge its settings, so µV scaling can't be trusted. Reconnect to retry.")
        }
        XCTAssertEqual(RecordGate.disabledReason(state: .streaming, source: .serial(SerialPort(path: "/dev/cu.fake")), board: daisy,
                                                 configuration: c, map: .withoutPositions),
                       "Channel 1 did not acknowledge its settings, so µV scaling can't be trusted. Reconnect to retry.")
        await session.disconnect()
    }

    func testReconnectWithChangedGain_endsTheRecordingNamed_nothingMisScaled() async throws {
        let link = FakeLink()
        link.set { $0.registerReply = try? self.dump() }
        let store = try ProjectStore.create(at: scratch.appendingPathComponent("g.bciproj"), name: "g")
        var options = AcquisitionSession.Options()
        options.noSampleTimeout = .milliseconds(400); options.retryInterval = .milliseconds(50); options.retryWindow = .seconds(2)
        let session = AcquisitionSession(source: .serial(port: "/dev/cu.fake"), projectDirectory: nil, options: options, makeBoard: link.factory)
        await session.connect()
        await session.startStreaming()
        let id = try await session.startRecording(.init(map: .defaults(for: daisy)), in: store)
        var lines = try dump().components(separatedBy: "\r\n")
        let ch1 = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("CH1SET") })
        lines[ch1] = "CH1SET, 05, 48, 0, 1, 0, 0, 1, 0, 0, 0"
        link.set { $0.registerReply = lines.joined(separator: "\r\n"); $0.readErrors = 1 }
        let deadline = ContinuousClock.now + .seconds(20)
        while session.snapshot.recordingEndedByReconnect == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(session.snapshot.recordingEndedByReconnect, .gainMismatch(channel: 1, gain: "8"))
        XCTAssertNil(session.snapshot.recordingID)
        XCTAssertEqual(session.snapshot.state, .streaming, "preview goes on")
        XCTAssertTrue(RecordingEndModel.endedByReconnect(.gainMismatch(channel: 1, gain: "8")).hasSuffix("Reconnect to reset."))
        while session.snapshot.lastRecordingEnd == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(session.snapshot.lastRecordingEnd?.endReason, .disconnect)
        await session.disconnect()
        let m = try await store.recording(id: id).manifest
        XCTAssertEqual(m.segments.map(\.endReason), [.disconnect], "no segment with the wrong gain")
        XCTAssertEqual(m.boardConfiguration.readback["ch01.gain"], "24")
    }

    func testBlockHeadersMustBeBoardThenDaisy_andWarningsAndIdentity() throws {
        let swapped = try dump().replacingOccurrences(of: "Board ADS Registers", with: "X").replacingOccurrences(of: "Daisy ADS Registers", with: "Board ADS Registers")
            .replacingOccurrences(of: "\r\nX\r\n", with: "\r\nDaisy ADS Registers\r\n")
        XCTAssertEqual(CytonRegisterReadback.parse(swapped).keys.sorted(), ["raw"])
        // Every command acknowledged: a missing `acknowledged` key would refuse Record (fail closed).
        var acked = DefaultChannelSettings.requested
        for n in 1...DefaultChannelSettings.channelCount { acked[DefaultChannelSettings.key(n) + ".acknowledged"] = "yes" }
        let rawOnly = RecordingManifest.BoardConfiguration(requested: acked, readback: ["raw": "?"])
        XCTAssertEqual(RecordGate.warning(source: .serial(SerialPort(path: "/dev/cu.x")), configuration: rawOnly),
                       "Gain not confirmed by the board; µV scaling assumes 24.")
        XCTAssertNil(RecordGate.warning(source: .synthetic, configuration: rawOnly))
        XCTAssertNil(RecordGate.disabledReason(state: .streaming, source: .serial(SerialPort(path: "/dev/cu.x")), board: daisy,
                                               configuration: rawOnly, map: .withoutPositions), "warned, not disabled")
        let demo = Dictionary(uniqueKeysWithValues: IdentityModel.rows(board: daisy, source: .demo, brainflowVersion: "5", firmware: nil))
        XCTAssertEqual(demo["Board"], "Demo")
        var h = StreamHealth()
        h.freeBytes = 5_000_000_000
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: HealthModel.rows(h, nowNanos: 0))["Free disk"], "5000 MB free")
    }
}

/// PR #25 follow-up: every channel field validated, format characters refused, a huge
/// map or file refused before it is trusted, and a missing acknowledgement fails closed.
final class ChannelMapValidationTests: XCTestCase {
    private var scratch: URL!
    private let daisy = try! BrainFlowBoard.describe(boardID: KnownBoard.cytonDaisy)

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bci-cmv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    private func problem(_ edit: (inout ChannelMapRecord) -> Void) -> String? {
        var map = ChannelMapRecord.defaults(for: daisy)
        edit(&map)
        return map.problem(directoryID: map.mapID)
    }

    func testChannelIDKindAndUnit_areValidated() {
        XCTAssertNil(problem { _ in })
        XCTAssertNotNil(problem { $0.channels[0].id = " " })
        XCTAssertNotNil(problem { $0.channels[0].id = String(repeating: "x", count: 33) })
        XCTAssertNotNil(problem { $0.channels[0].id = "ch01\u{7}" })
        XCTAssertNotNil(problem { $0.channels[0].kind = "" })
        XCTAssertNotNil(problem { $0.channels[0].kind = String(repeating: "e", count: 17) })
        XCTAssertNotNil(problem { $0.channels[0].unit = "u\u{200B}V" })
        XCTAssertNotNil(problem { $0.channels[0].unit = "\n" })
    }

    func testFormatCharacters_areRefusedLikeControlCharacters() {
        for scalar in ["\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}", "\u{2066}", "\u{2067}", "\u{2068}",
                       "\u{2069}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}", "\u{200E}", "\u{200F}"] {
            XCTAssertFalse(ChannelMapRecord.isSane("C3" + scalar), "U+\(String(scalar.unicodeScalars.first!.value, radix: 16))")
            XCTAssertNotNil(problem { $0.channels[0].label = "C" + scalar + "3" })
            XCTAssertNotNil(problem { $0.montage = scalar + "10-20" })
            XCTAssertNotNil(problem { $0.reference = "SRB2" + scalar })
        }
        XCTAssertTrue(ChannelMapRecord.isSane("Fp1 (left)"))
        XCTAssertTrue(ChannelMapRecord.isSane("Cz-Ω µ"), "ordinary non-ASCII letters stay allowed")
    }

    func testTooManyChannels_isRefused() {
        let board = ChannelMapRecord.defaults(for: daisy)
        XCTAssertNotNil(problem { map in
            map.channels = (0..<65).map { ChannelSpec(id: "c\($0)", label: "L\($0)", kind: "eeg", unit: "uV", sourceRow: $0) }
        })
        XCTAssertNil(problem { map in
            map.channels = (0..<64).map { ChannelSpec(id: "c\($0)", label: "L\($0)", kind: "eeg", unit: "uV", sourceRow: $0) }
        }, "64 is the cap, not beyond it")
        XCTAssertEqual(board.channels.count, 16)
    }

    func testOversizedSavedMapFile_isSkippedWithoutDecoding() async throws {
        let store = try ProjectStore.create(at: scratch.appendingPathComponent("big.bciproj"), name: "big")
        let good = ChannelMapRecord.defaults(for: daisy)
        try await store.saveChannelMap(good)
        // A valid map padded with whitespace past the cap: decodable, but never read.
        let padded = ChannelMapRecord.defaults(for: daisy)
        var data = try ContractJSON.encoder().encode(padded)
        data.append(Data(repeating: 0x20, count: ChannelMapRecord.maxFileBytes))
        let dir = store.directory.appendingPathComponent("montages").appendingPathComponent(padded.mapID.uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(ProjectStore.channelMapFileName))
        XCTAssertNoThrow(try ContractJSON.decoder().decode(ChannelMapRecord.self, from: data), "only the size refuses it")
        let (maps, unreadable) = try await store.channelMaps()
        XCTAssertEqual(maps.map(\.mapID), [good.mapID])
        XCTAssertEqual(unreadable, 1)
    }

    func testSymlinkedOrNonRegularMapFiles_areSkippedWithoutHanging() async throws {
        let store = try ProjectStore.create(at: scratch.appendingPathComponent("links.bciproj"), name: "links")
        let good = ChannelMapRecord.defaults(for: daisy)
        try await store.saveChannelMap(good)
        let fm = FileManager.default
        func dir(_ id: UUID) throws -> URL {
            let d = store.directory.appendingPathComponent("montages").appendingPathComponent(id.uuidString)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            return d.appendingPathComponent(ProjectStore.channelMapFileName)
        }
        // A valid map outside the project, reached through a symlink: refused, not followed.
        let linked = ChannelMapRecord.defaults(for: daisy)
        let outside = scratch.appendingPathComponent("outside.json")
        try ContractJSON.encoder().encode(linked).write(to: outside)
        try fm.createSymbolicLink(at: try dir(linked.mapID), withDestinationURL: outside)
        try fm.createSymbolicLink(at: try dir(UUID()), withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
        let fifo = try dir(UUID())
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let (maps, unreadable) = try await store.channelMaps()          // a FIFO open would block here
        XCTAssertEqual(maps.map(\.mapID), [good.mapID])
        XCTAssertEqual(unreadable, 3)
        XCTAssertNil(BoundedRead.data(at: outside, maxBytes: 16), "over the cap")
        XCTAssertNotNil(BoundedRead.data(at: outside, maxBytes: ChannelMapRecord.maxFileBytes))
    }

    func testMissingAcknowledgedKey_failsClosedOnADevice_only() {
        var requested = DefaultChannelSettings.requested
        for n in 1...DefaultChannelSettings.channelCount { requested[DefaultChannelSettings.key(n) + ".acknowledged"] = "yes" }
        let acked = RecordingManifest.BoardConfiguration(requested: requested, readback: [:])
        XCTAssertNil(AcquisitionSession.problem(acked, isDevice: true))
        requested[DefaultChannelSettings.key(5) + ".acknowledged"] = nil
        let missing = RecordingManifest.BoardConfiguration(requested: requested, readback: [:])
        XCTAssertEqual(AcquisitionSession.problem(missing, isDevice: true), .notAcknowledged(channel: 5))
        XCTAssertNil(AcquisitionSession.problem(missing, isDevice: false), "synthetic and playback have nothing to acknowledge")
        requested[DefaultChannelSettings.key(2) + ".acknowledged"] = "maybe"
        let odd = RecordingManifest.BoardConfiguration(requested: requested, readback: [:])
        XCTAssertEqual(AcquisitionSession.problem(odd, isDevice: true), .notAcknowledged(channel: 2), "only \"yes\" counts")
    }
}
