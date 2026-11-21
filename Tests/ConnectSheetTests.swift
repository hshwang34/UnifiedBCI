import CryptoKit
import XCTest
@testable import BCIWorkspace

/// Brief 004 PR 5: the Connect sheet's controller and copy, and the Demo source's file and
/// provenance. Synthetic and playback boards only (decision #26).
@MainActor
final class ConnectSheetTests: XCTestCase {
    private var scratch: URL!
    private let daisy = try! BrainFlowBoard.describe(boardID: KnownBoard.cytonDaisy)

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bci-connect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    private func store() throws -> ProjectStore {
        try ProjectStore.create(at: scratch.appendingPathComponent("p.bciproj"), name: "p")
    }

    private func sha(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Copy

    func testChannelMapStatusAndEditedMap() {
        XCTAssertEqual(ChannelMapModel.status(.none), "Confirm a channel map, or choose Record without positions.")
        XCTAssertEqual(ChannelMapModel.status(.withoutPositions),
                       "Recording without positions: BrainFlow's names, montage stored as \"undeclared\".")
        var labels = ChannelMapRecord.defaults(for: daisy).channels.map(\.label)
        labels[0] = "  C3 "
        let map = ChannelMapModel.edited(board: daisy, labels: labels, reference: " earclips ", montage: "10-20")
        XCTAssertEqual(map.channels[0].label, "C3")
        XCTAssertEqual(map.reference, "earclips")
        XCTAssertEqual(ChannelMapModel.status(.confirmed(map)), "Map confirmed: 10-20 · 16 channels · reference earclips.")
        XCTAssertEqual(map.channels.map(\.sourceRow), daisy.eegChannelRows, "rows are the board's, never edited")
        XCTAssertEqual(ChannelMapModel.labelField(3), "Label for channel 3")
        XCTAssertEqual(ChannelMapModel.invalid("x"), "This map can't be used: x.")
    }

    func testConfigurationAlert_dangerBeforeWarning() {
        var acked = DefaultChannelSettings.requested
        for n in 1...16 { acked[DefaultChannelSettings.key(n) + ".acknowledged"] = "yes" }
        let port = ConnectSource.serial(SerialPort(path: "/dev/cu.x"))
        let rawOnly = RecordingManifest.BoardConfiguration(requested: acked, readback: ["raw": "?"])
        XCTAssertEqual(ConnectSheetModel.configurationAlert(rawOnly, source: port)?.danger, false)
        XCTAssertEqual(ConnectSheetModel.configurationAlert(rawOnly, source: port)?.text, ConfigurationModel.gainNotConfirmed)
        XCTAssertNil(ConnectSheetModel.configurationAlert(rawOnly, source: .synthetic))
        let gain = RecordingManifest.BoardConfiguration(requested: acked, readback: ["ch02.gain": "8"])
        XCTAssertEqual(ConnectSheetModel.configurationAlert(gain, source: port)?.danger, true)
        XCTAssertEqual(ConnectSheetModel.configurationAlert(gain, source: port)?.text,
                       "Channel 2 reports gain 8; µV scaling assumes 24. Reconnect to reset.")
    }

    // MARK: Controller

    func testSourcesListUSBFirstThenNoHardware_andAGonePortIsNamed() async throws {
        let usb = SerialPort(path: "/dev/cu.usbserial-DM01", vendorName: "FTDI", productName: "FT231X USB UART", isUSB: true)
        let bt = SerialPort(path: "/dev/cu.Bluetooth-Incoming-Port")
        let present = Flag()
        let model = ConnectController(store: try store(), projectDirectory: scratch, demoFile: nil,
                                      scan: { SerialPortScanner.ordered(present.on ? [bt, usb] : [bt]) })
        await model.refresh()
        XCTAssertEqual(model.sources.map(\.id), [usb.path, bt.path, "synthetic", "demo"])
        XCTAssertFalse(model.isAvailable(.demo), "no Demo file in this controller")
        model.selectedID = usb.path
        present.on = false
        await model.refresh()
        XCTAssertNil(model.selectedID)
        XCTAssertEqual(model.gonePort.map(ConnectSource.gone), "/dev/cu.usbserial-DM01 is gone. Plug the dongle back in or pick another port.")
        present.on = true
        await model.refresh()
        XCTAssertNil(model.gonePort, "back again")
    }

    func testSyntheticConnect_readyWithDefaults_mapChoices_saveAndPick_thenClose() async throws {
        let store = try store()
        let model = ConnectController(store: store, projectDirectory: scratch, demoFile: nil, scan: { [] })
        model.selectedID = ConnectSource.synthetic.id
        XCTAssertEqual(model.actions, [.connect])
        await model.perform(.connect)
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.actions, [.startPreview, .disconnect])
        XCTAssertFalse(model.canPickSource)
        let board = try XCTUnwrap(model.snapshot.board)
        XCTAssertEqual(model.labels, ChannelMapRecord.defaults(for: board).channels.map(\.label))
        XCTAssertEqual(model.reference, "SRB2")
        XCTAssertEqual(model.montage, "undeclared")
        XCTAssertEqual(model.choice, .none)

        model.recordWithoutPositions()
        XCTAssertEqual(model.choice, .withoutPositions)
        model.labels[0] = "C3"
        XCTAssertEqual(model.choice, .none, "an edit undoes the choice")
        XCTAssertEqual(model.mapMessage, ChannelMapModel.edited)
        model.labels[1] = "\u{202E}zC"
        model.confirmMap()
        XCTAssertEqual(model.choice, .none)
        XCTAssertTrue(model.mapMessage?.hasPrefix("This map can't be used:") == true, model.mapMessage ?? "")
        model.labels[1] = "Cz"
        model.montage = "10-20"
        model.confirmMap()
        guard case .confirmed(let map) = model.choice else { return XCTFail("confirmed") }
        XCTAssertEqual(Array(map.channels.prefix(2).map(\.label)), ["C3", "Cz"])
        XCTAssertTrue(map.fits(board))

        await model.saveMap()
        XCTAssertEqual(model.mapMessage, ChannelMapModel.saved)
        XCTAssertEqual(model.savedMaps.count, 1)
        model.recordWithoutPositions()
        XCTAssertEqual(model.labels[0], ChannelMapRecord.defaults(for: board).channels[0].label)
        model.pick(savedMap: model.savedMaps[0].mapID)
        XCTAssertEqual(model.labels[0], "C3")
        XCTAssertEqual(model.montage, "10-20")
        XCTAssertEqual(model.choice, .none, "picking a saved map still needs a confirm")

        await model.perform(.startPreview)
        XCTAssertEqual(model.state, .streaming)
        XCTAssertEqual(model.actions, [.disconnect], "Record lives on the acquisition screen (PR 6)")
        await model.close()
        XCTAssertEqual(model.session?.snapshot.state, .disconnected)
        let ids = try await store.recordingIDs()
        XCTAssertEqual(ids, [], "the sheet never records")
    }

    func testCancelWhileConnecting_endsDisconnected() async throws {
        let model = ConnectController(store: try store(), projectDirectory: scratch, demoFile: nil, scan: { [] })
        model.selectedID = ConnectSource.synthetic.id
        let connect = Task { await model.perform(.connect) }
        let deadline = ContinuousClock.now + .seconds(10)
        while model.session == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        await model.perform(.cancel)
        await connect.value
        XCTAssertEqual(model.session?.snapshot.state, .disconnected)
        XCTAssertTrue(model.canPickSource)
    }

    // MARK: Demo source

    func testBundledDemo_isBuiltIntoTheApp_andItsSidecarNamesIt() throws {
        let csv = try XCTUnwrap(AcquisitionSource.bundledDemo(), "the build phase copies build/demo into Resources/Demo")
        let side = csv.deletingPathExtension().appendingPathExtension("json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: side)) as? [String: Any])
        XCTAssertEqual(json["kind"] as? String, "derived_playback")
        XCTAssertEqual((json["file"] as? [String: Any])?["sha256"] as? String, try sha(csv))
    }

    func testDemoRecordingSource_isPlayback_withFileHashAndDerivedProvenance() throws {
        let csv = try XCTUnwrap(AcquisitionSource.bundledDemo())
        let s = AcquisitionSource.playback(file: csv, loop: true).recordingSource(daisy, appVersion: "t")
        XCTAssertEqual(s.kind, "playback")
        XCTAssertNil(s.dataPath)
        XCTAssertEqual(s.sourceFiles?.map(\.name), ["S001R04-demo-cyton-daisy-125hz.csv", "S001R04-demo-cyton-daisy-125hz.json"])
        XCTAssertEqual(s.sourceFiles?.first?.sha256, try sha(csv))
        XCTAssertTrue(s.warning?.hasPrefix("Derived demo input") == true, s.warning ?? "")
        XCTAssertEqual(s.dataset, "PhysioNet EEG Motor Movement/Imagery v1.0.0")
        XCTAssertEqual(s.attribution?.first?.doi, "10.13026/C28G6P")
        XCTAssertEqual(s.derivations?.count, 3)
        XCTAssertTrue(s.derivations?[1].hasPrefix("resampled 160 Hz to 125 Hz: scipy.signal.resample_poly") == true, "\(s.derivations ?? [])")
    }

    func testSidecarForAnotherFile_isIgnored() throws {
        let csv = scratch.appendingPathComponent("x.csv")
        try Data("0\t1\n".utf8).write(to: csv)
        let side: [String: Any] = [
            "kind": "derived_playback", "warning": "W", "generator": "g", "method": "m", "originalRateHz": 160, "resampledRateHz": 125,
            "file": ["name": "x.csv", "sha256": String(repeating: "0", count: 64)], "source": ["dataset": "D"],
        ]
        try JSONSerialization.data(withJSONObject: side).write(to: scratch.appendingPathComponent("x.json"))
        let s = AcquisitionSource.playback(file: csv, loop: false).recordingSource(daisy, appVersion: "t")
        XCTAssertEqual(s.warning, "Played back from a file, not a device")
        XCTAssertNil(s.dataset)
        XCTAssertNil(s.derivations)
        XCTAssertEqual(s.sourceFiles?.count, 1)
    }
}

/// Whether the fake scanner still finds the USB port (set on the main actor between scans).
private final class Flag: @unchecked Sendable { var on = true }
