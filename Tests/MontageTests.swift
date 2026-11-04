import simd
import XCTest
@testable import BCIWorkspace

/// Brief 003 part B (test plan §B, items 14–21 and B1): the standard table, the montage
/// recognizer, label lookup, the placed/unplaced split, the reference rule, the strings
/// VoiceOver reads and the orbit/camera maths. Pure logic; no rendering.
@MainActor
final class MontageTests: XCTestCase {
    static let exampleMontage = "international 10-10 (BCI2000 64-ch subset), cropped to 16"
    static let exampleLabels = ["FC3", "FC1", "FC2", "FC4", "C5", "C3", "C1", "Cz", "C2", "C4", "C6", "CP3", "CP1", "CPz", "CP2", "CP4"]

    private func rows(_ labels: [String], kind: String = "eeg") -> [RecordingDetailModel.ChannelRow] {
        labels.enumerated().map { i, l in
            RecordingDetailModel.ChannelRow(id: String(format: "ch%02d", i), label: RecordingDetailModel.declared(l), unit: "uV", kind: kind)
        }
    }

    private func layout(_ montage: String, _ labels: [String], reference: String = "") -> MontageLayout {
        MontageLayout(montage: montage, reference: reference, channels: rows(labels))
    }

    // MARK: Table (criterion 14, 21)

    func testTable_isTheTenTenGridWithUniqueLabels() {
        let labels = StandardPositions.tenTen.map(\.label)
        XCTAssertEqual(labels.count, 86)
        XCTAssertEqual(Set(labels).count, 86)
        XCTAssertEqual(Set(labels.map { $0.lowercased() }).count, 86, "case-insensitive lookup must be unambiguous")
        // Old names are aliases, never rows: one site never has two points (lead default 4).
        for old in ["T3", "T4", "T5", "T6", "A1", "A2", "M1", "M2"] { XCTAssertNil(StandardPositions.byLabel[old], old) }
        XCTAssertTrue(StandardPositions.tenTwentyLabels.isSubset(of: Set(labels)))
        XCTAssertEqual(StandardPositions.tenTwentyLabels.count, 21)
        for target in StandardPositions.tenTwentyAliases.values { XCTAssertNotNil(StandardPositions.byLabel[target]) }
    }

    func testTable_anatomy() throws {
        let p = { (l: String) in StandardPositions.byLabel[l]!.position }
        // Cz is the vertex: the highest site.
        let top = try XCTUnwrap(StandardPositions.tenTen.max { $0.z < $1.z })
        XCTAssertEqual(top.label, "Cz")
        // Left is −x, right is +x, mirrored within a few millimetres.
        XCTAssertLessThan(p("C3").x, 0)
        XCTAssertGreaterThan(p("C4").x, 0)
        XCTAssertEqual(-p("C3").x, p("C4").x, accuracy: 3)
        // Anterior is +y: FC in front of C in front of CP.
        XCTAssertGreaterThan(p("FC3").y, p("C3").y)
        XCTAssertGreaterThan(p("C3").y, p("CP3").y)
        XCTAssertGreaterThan(p("Fpz").y, p("Oz").y)
    }

    func testGeometry_sitesSitOnTheDomeAndFaceOutward() {
        for site in StandardPositions.tenTen {
            let s = HeadGeometry.surfacePoint(site)
            XCTAssertEqual(simd_length_squared((s - HeadGeometry.centre) / HeadGeometry.radii), 1, accuracy: 1e-9, site.label)
            // Moving onto the fitted surface shifts a site by under 6.5 mm (the fit's residual).
            XCTAssertLessThan(simd_distance(s, site.position), 6.5, site.label)
            XCTAssertGreaterThan(simd_dot(HeadGeometry.normal(at: s), s - HeadGeometry.centre), 0, site.label)
        }
    }

    func testGeometry_gridAndNotch() {
        // 10 rows (Fp…I with FT/T/TP folded in) and the z + numbered columns; every point on the dome.
        XCTAssertGreaterThanOrEqual(HeadGeometry.gridLines.count, 20)
        for line in HeadGeometry.gridLines {
            XCTAssertGreaterThan(line.count, 8)
            for p in line {
                XCTAssertEqual(simd_length_squared((p - HeadGeometry.centre) / HeadGeometry.radii), 1, accuracy: 1e-9)
            }
        }
        // The notch is at the front (+y), on the midline.
        XCTAssertGreaterThan(HeadGeometry.notchBase.y, 80)
        XCTAssertEqual(HeadGeometry.notchTip.x, 0.8, accuracy: 1)
    }

    // MARK: Recognizer (B1)

    func testRecognizer_allowList() {
        XCTAssertEqual(MontageRecognizer.recognize(Self.exampleMontage), .tenTen)
        for s in ["10-10", "10/10", "International 10-10 system", "  international   10-10  ", "10-10; Easycap", "10-10: 64 ch"] {
            XCTAssertEqual(MontageRecognizer.recognize(s), .tenTen, s)
        }
        for s in ["10-20", "International 10-20", "10-20 system (Jasper 1958)", "10/20, 19 channels"] {
            XCTAssertEqual(MontageRecognizer.recognize(s), .tenTwenty, s)
        }
    }

    func testRecognizer_rejectsEverythingElse() {
        for s in ["", "   ", "unspecified", "UNSPECIFIED", "  Unspecified ", "undeclared",
                  "custom cap, roughly 10-20 but modified", "not 10-20", "10-20 but modified",
                  "international 10-5", "10-5", "10-10x", "10-100", "10-200", "standard_1020", "1020"] {
            XCTAssertNil(MontageRecognizer.recognize(s), s)
        }
    }

    // MARK: Label lookup (lead defaults 1, 3, 4)

    func testLabelLookup_caseTrailingDotsAndOuterWhitespace() {
        for l in ["FC3", "fc3", "Fc3.", "FC3..", " Fc3 ", "\tfc3.\n"] {
            XCTAssertEqual(ElectrodeLabel.site(for: l, in: .tenTen)?.label, "FC3", l)
        }
        XCTAssertEqual(ElectrodeLabel.site(for: "Cz..", in: .tenTen)?.label, "Cz")
        XCTAssertEqual(ElectrodeLabel.site(for: "FCZ", in: .tenTen)?.label, "FCz")
    }

    func testLabelLookup_neverSnapsOrGuesses() {
        // Interior whitespace, near misses, non-EEG names and lookalikes (Cyrillic С, full-width).
        for l in ["C 3", "C3x", "FC30", "CP", "EOG", "ECG1", "X1", "\u{0421}3", "\u{FF23}3", "", "."] {
            XCTAssertNil(ElectrodeLabel.site(for: l, in: .tenTen), l)
            XCTAssertNil(ElectrodeLabel.site(for: l, in: .tenTwenty), l)
        }
    }

    func testLabelLookup_tenTwentyPlacesOnlyTenTwentyAndOldNames() {
        XCTAssertNil(ElectrodeLabel.site(for: "FC3", in: .tenTwenty))
        XCTAssertNil(ElectrodeLabel.site(for: "C1", in: .tenTwenty))
        XCTAssertEqual(ElectrodeLabel.site(for: "C3", in: .tenTwenty)?.label, "C3")
        // Old names resolve to the same single site, under 10-20 only.
        XCTAssertEqual(ElectrodeLabel.site(for: "T3", in: .tenTwenty), ElectrodeLabel.site(for: "T7", in: .tenTwenty))
        XCTAssertEqual(ElectrodeLabel.site(for: "t6.", in: .tenTwenty)?.label, "P8")
        XCTAssertNil(ElectrodeLabel.site(for: "T3", in: .tenTen))
        XCTAssertEqual(ElectrodeLabel.site(for: "FC3", in: .tenTen)?.label, "FC3")
    }

    // MARK: Layout (criteria 14, 15, 18)

    func testExample_allSixteenPlaced() {
        let l = layout(Self.exampleMontage, Self.exampleLabels, reference: "per dataset documentation")
        XCTAssertEqual(l.standard, .tenTen)
        XCTAssertEqual(l.placedCount, 16)
        XCTAssertEqual(l.eegCount, 16)
        XCTAssertTrue(l.unplaced.isEmpty)
        XCTAssertNil(l.undeclaredTitle)
        XCTAssertEqual(l.accessibilityLabel, "Montage: 16 of 16 channels placed, international 10-10 system")
        // Free-text reference marks nothing and is shown as written.
        XCTAssertNil(l.referenceElectrode)
        XCTAssertTrue(l.referenceCaption.contains("per dataset documentation"), l.referenceCaption)
        // Buttons read the stored label verbatim.
        XCTAssertEqual(l.placed.map(\.label), Self.exampleLabels)
    }

    func testBundledExampleManifest_placesEveryChannel() throws {
        let project = try XCTUnwrap(BundledExample.locate(), "the example ships in the app bundle")
        let recordings = project.appendingPathComponent("recordings")
        let dir = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: recordings, includingPropertiesForKeys: nil).first)
        let manifest = try ContractJSON.decoder().decode(RecordingManifest.self, from: Data(contentsOf: dir.appendingPathComponent("recording.json")))
        let l = MontageLayout(RecordingDetailModel(manifest: manifest, events: []))
        XCTAssertEqual(l.placedCount, manifest.channels.count)
        XCTAssertEqual(l.accessibilityLabel, "Montage: 16 of 16 channels placed, international 10-10 system")
    }

    func testUnspecifiedMontage_placesNothingEvenWithAFullTenTwentySet() {
        let full = Array(StandardPositions.tenTwentyLabels).sorted()
        for montage in ["unspecified", "", "Unspecified "] {
            let l = layout(montage, full)
            XCTAssertNil(l.standard)
            XCTAssertEqual(l.placedCount, 0, "never inferred from labels or channel count")
            XCTAssertEqual(l.unplaced.count, full.count)
            XCTAssertTrue(l.unplaced.allSatisfy { $0.reason == .montageUndeclared })
            XCTAssertEqual(l.accessibilityLabel.hasPrefix("Montage: 0 of 21 channels placed, "), true, l.accessibilityLabel)
            XCTAssertEqual(l.undeclaredTitle, "Positions undeclared: the recording names no standard montage")
            XCTAssertEqual(l.unplacedList, l.unplaced.map { $0.label! }.joined(separator: ", "))
        }
        XCTAssertTrue(layout("unspecified", ["C3"]).accessibilityLabel.hasSuffix("unspecified (not a recognized standard)"))
        XCTAssertTrue(layout("", ["C3"]).accessibilityLabel.hasSuffix("montage undeclared"))
    }

    func testPartialPlacement_listsUnplacedLabels() {
        let l = layout("10-10", ["C3", "C4", "EOG", "C 3", "Cz"])
        XCTAssertEqual(l.accessibilityLabel, "Montage: 3 of 5 channels placed, international 10-10 system")
        XCTAssertEqual(l.unplaced.map(\.displayLabel), ["EOG", "C 3"])
        XCTAssertTrue(l.unplaced.allSatisfy { $0.reason == .notInStandard })
        XCTAssertEqual(l.undeclaredTitle, "Positions undeclared for 2 channels (no standard 10-10 site)")
        // FC3 under a 10-20 declaration is unplaced (lead default 3).
        let t = layout("10-20", ["FC3", "C3"])
        XCTAssertEqual(t.placed.map(\.label), ["C3"])
        XCTAssertEqual(t.unplaced.map(\.label), ["FC3"])
    }

    func testDuplicatesAndAliases_onePointPerSite() {
        let l = layout("10-20", ["T3", "T7", "Cz", "cz.", "C3"])
        XCTAssertEqual(l.placed.map(\.label), ["T3", "Cz", "C3"])
        XCTAssertEqual(l.unplaced.map(\.label), ["T7", "cz."])
        XCTAssertTrue(l.unplaced.allSatisfy { $0.reason == .duplicateSite })
        XCTAssertEqual(Set(l.placed.map(\.site.label)).count, l.placed.count)
    }

    /// Property: whatever the labels, placed + unplaced == M and no site has two points.
    func testProperty_placedPlusUnplacedIsM() {
        var rng = SystemRandomNumberGenerator()
        let pool = StandardPositions.tenTen.map(\.label) + ["T3", "T5", "EOG", "X1", "C 3", "", "fc3.", "Cz", "Cz"]
        for _ in 0..<200 {
            let labels = (0..<Int.random(in: 0...40, using: &rng)).map { _ in pool.randomElement(using: &rng)! }
            for montage in ["10-10", "10-20", "unspecified"] {
                let l = layout(montage, labels)
                XCTAssertEqual(l.placedCount + l.unplaced.count, labels.count)
                XCTAssertEqual(l.eegCount, labels.count)
                XCTAssertEqual(Set(l.placed.map(\.site.label)).count, l.placedCount)
            }
        }
    }

    func testZeroChannels() {
        let l = layout("10-10", [])
        XCTAssertEqual(l.accessibilityLabel, "Montage: 0 of 0 channels placed, international 10-10 system")
        XCTAssertNil(l.undeclaredTitle)
    }

    func testUndeclaredLabel_isUnplaced() {
        let l = layout("10-10", ["", "C3"])
        XCTAssertEqual(l.unplaced.first?.reason, .labelUndeclared)
        XCTAssertEqual(l.unplaced.first?.displayLabel, "ch00 (no label)")
    }

    // MARK: Non-EEG channels (lead default 7)

    func testNonEEGChannels_areNotCountedAndAreNamed() {
        let channels = rows(["C3", "C4"]) + [
            RecordingDetailModel.ChannelRow(id: "ch10", label: "EOG", unit: "uV", kind: "eog"),
            RecordingDetailModel.ChannelRow(id: "ch11", label: "Cz", unit: "uV", kind: nil),
        ]
        let l = MontageLayout(montage: "10-10", reference: "", channels: channels)
        XCTAssertEqual(l.eegCount, 2)
        XCTAssertEqual(l.placedCount, 2)
        XCTAssertEqual(l.excluded.map(\.id), ["ch10", "ch11"])
        XCTAssertTrue(l.caption.contains("2 non-EEG channels not counted (EOG, Cz)"), l.caption)
        XCTAssertFalse(layout("10-10", ["C3"]).caption.contains("non-EEG"))
    }

    // MARK: Reference (lead default 5)

    func testReference_marksOnlyARecordedPlacedLabel() {
        XCTAssertEqual(layout("10-10", ["C3", "Cz"], reference: "Cz").referenceElectrode?.label, "Cz")
        XCTAssertEqual(layout("10-10", ["C3", "Cz."], reference: " cz ").referenceElectrode?.channelID, "ch01")
        for ref in ["average", "linked mastoids", "A1+A2", "", "Cz reference", "FCz"] {
            let l = layout("10-10", ["C3", "Cz"], reference: ref)
            XCTAssertNil(l.referenceElectrode, ref)
            XCTAssertTrue(l.placed.allSatisfy { !$0.isReference })
        }
        // Not placed (montage unspecified) → no mark either.
        XCTAssertNil(layout("unspecified", ["Cz"], reference: "Cz").referenceElectrode)
        XCTAssertEqual(layout("10-10", ["C3"], reference: "average").referenceCaption,
                       "Reference: average — not a recorded electrode, so not marked")
        XCTAssertEqual(layout("10-10", ["C3"]).referenceCaption, "Reference: undeclared")
        XCTAssertEqual(layout("10-10", ["Cz"], reference: "Cz").referenceCaption, "Reference: Cz (marked)")
    }

    // MARK: Cross-highlight (criterion 16) and no per-channel value (criterion 19)

    func testCrossHighlight_byChannelIDOnly() {
        // Two channels can't share a site, but the lookup is by id regardless of label.
        let l = layout("10-10", ["C3", "EOG", "C4"])
        XCTAssertEqual(l.electrode(forChannel: "ch00")?.label, "C3")
        XCTAssertEqual(l.electrode(forChannel: "ch02")?.label, "C4")
        XCTAssertNil(l.electrode(forChannel: "ch01"), "an unplaced channel highlights nothing")
        XCTAssertNil(l.electrode(forChannel: nil))
        XCTAssertNil(l.electrode(forChannel: "C3"), "labels are not ids")
    }

    func testElectrode_carriesNoValue() {
        // Decision #17: an electrode is a position, a label and the reference flag, nothing else.
        let e = layout("10-10", ["C3"]).placed[0]
        let fields = Mirror(reflecting: e).children.compactMap(\.label).sorted()
        XCTAssertEqual(fields, ["channelID", "isReference", "label", "site"])
    }

    // MARK: Orbit and camera (criterion 17)

    func testPresets() {
        // The study's conventions (003-glass-studies.html PRESETS).
        XCTAssertEqual(Orbit.Preset.allCases.map(\.title), ["Top", "Left", "Right", "Front", "Reset"])
        XCTAssertEqual(Orbit.Preset.top.orbit, Orbit(yaw: 180, pitch: 89))
        XCTAssertEqual(Orbit.Preset.left.orbit, Orbit(yaw: -90, pitch: 6))
        XCTAssertEqual(Orbit.Preset.right.orbit, Orbit(yaw: 90, pitch: 6))
        XCTAssertEqual(Orbit.Preset.front.orbit, Orbit(yaw: 0, pitch: 6))
        XCTAssertEqual(Orbit.Preset.reset.orbit, Orbit(yaw: -38, pitch: 26))
        XCTAssertEqual(Orbit.default, Orbit.Preset.reset.orbit)
        XCTAssertTrue(Orbit.Preset.allCases.allSatisfy { !$0.accessibilityLabel.isEmpty })
        XCTAssertEqual(Orbit.transitionDuration(reduceMotion: true), 0)
        XCTAssertGreaterThan(Orbit.transitionDuration(reduceMotion: false), 0)
    }

    func testDrag_wrapsYawAndClampsPitch() {
        let dragged = Orbit(yaw: 170, pitch: 80).dragged(by: CGSize(width: -100, height: 100))
        XCTAssertEqual(dragged.pitch, 89)
        XCTAssertEqual(dragged.yaw, -145, accuracy: 1e-9)
        XCTAssertEqual(Orbit(yaw: 0, pitch: -10).dragged(by: CGSize(width: 0, height: -500)).pitch, Orbit.pitchRange.lowerBound)
        XCTAssertEqual(Orbit.wrap(540), 180)
        XCTAssertEqual(Orbit.wrap(-180), 180)
        // The short way round: from yaw 170 to −170 is +20, not −340.
        XCTAssertEqual(Orbit(yaw: 170, pitch: 0).nearest(Orbit(yaw: -170, pitch: 0)).yaw, 190, accuracy: 1e-9)
    }

    func testCamera_viewsLookWhereTheyShould() throws {
        let size = CGSize(width: 400, height: 300)
        let site = { (l: String) in HeadGeometry.surfacePoint(StandardPositions.byLabel[l]!) }
        // Top: nose up, subject's right on the right, every scalp-top site visible.
        let top = HeadCamera(orbit: Orbit.Preset.top.orbit)
        let fz = try XCTUnwrap(top.project(site("Fz"), in: size)), pz = try XCTUnwrap(top.project(site("Pz"), in: size))
        XCTAssertLessThan(fz.y, pz.y)
        let c3 = try XCTUnwrap(top.project(site("C3"), in: size)), c4 = try XCTUnwrap(top.project(site("C4"), in: size))
        XCTAssertLessThan(c3.x, c4.x)
        let cz = try XCTUnwrap(top.project(site("Cz"), in: size))
        XCTAssertEqual(cz.x, size.width / 2, accuracy: 4)
        XCTAssertTrue(top.faces(site("Cz")))
        XCTAssertFalse(top.faces(site("Iz")))
        // Front faces the subject: their left on the viewer's right; the occiput is hidden.
        let front = HeadCamera(orbit: Orbit.Preset.front.orbit)
        XCTAssertGreaterThan(try XCTUnwrap(front.project(site("Fp1"), in: size)).x, try XCTUnwrap(front.project(site("Fp2"), in: size)).x)
        XCTAssertTrue(front.faces(site("Fpz")))
        XCTAssertFalse(front.faces(site("Oz")))
        // Left shows the left hemisphere, hides the right.
        let left = HeadCamera(orbit: Orbit.Preset.left.orbit)
        XCTAssertTrue(left.faces(site("T7")))
        XCTAssertFalse(left.faces(site("T8")))
    }

    // MARK: Labels (decision #20: leader lines that don't overlap)

    /// The example's 16 labels, laid out in every preset at the Recording stage's size.
    func testLabels_exampleNeverOverlapsInAnyPreset() {
        let l = layout(Self.exampleMontage, Self.exampleLabels)
        for width in [520.0, 700.0] {
            let size = CGSize(width: width, height: 340)
            for preset in Orbit.Preset.allCases {
                let camera = HeadCamera(orbit: preset.orbit)
                let centre = camera.project(HeadGeometry.labelCentre, in: size)!
                let items = l.placed.map { e -> LabelLayout.Item in
                    let p = HeadGeometry.surfacePoint(e.site)
                    return LabelLayout.Item(id: e.channelID, anchor: camera.project(p, in: size)!,
                                            size: LabelMetrics.size(e.label, strong: false), dim: !camera.faces(p))
                }
                let placed = LabelLayout.place(items, centre: centre)
                XCTAssertEqual(placed.count, 16)
                XCTAssertEqual(LabelLayout.overlaps(placed), 0, "\(preset) at \(width)")
            }
        }
    }

    func testLabels_pushedOutwardFromCentre() {
        let centre = CGPoint(x: 100, y: 100)
        let placed = LabelLayout.place([LabelLayout.Item(id: "a", anchor: CGPoint(x: 150, y: 100), size: CGSize(width: 30, height: 17))], centre: centre)
        XCTAssertGreaterThan(placed[0].frame.midX, 150)
        XCTAssertEqual(placed[0].frame.midY, 100, accuracy: 0.5)
    }

    func testDisc_projectsAPolygonOnTheDome() throws {
        let camera = HeadCamera(orbit: .default)
        let cz = HeadGeometry.surfacePoint(StandardPositions.byLabel["Cz"]!)
        let disc = try XCTUnwrap(camera.disc(at: cz, radius: 5.8, in: CGSize(width: 600, height: 340)))
        XCTAssertEqual(disc.count, 22)
        let centre = try XCTUnwrap(camera.project(cz, in: CGSize(width: 600, height: 340)))
        for p in disc { XCTAssertLessThan(hypot(p.x - centre.x, p.y - centre.y), 20) }
    }
}
