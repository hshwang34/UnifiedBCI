import Foundation

// The live montage view's logic (brief 003, decisions #16–#18). An electrode is placed only
// when the recording declares a named standard montage AND its label is a site of that
// standard. Nothing is ever inferred from the channel count (docs/data-contracts.md).

/// A named electrode system the app can place labels in.
enum MontageStandard: String, Equatable, Sendable {
    case tenTwenty, tenTen

    /// How the view names the system ("Montage: 16 of 16 channels placed, <name>").
    var displayName: String {
        switch self {
        case .tenTwenty: return "international 10-20 system"
        case .tenTen: return "international 10-10 system"
        }
    }
}

/// Recognizes a declared montage string as a named standard (lead default 2). An explicit
/// allow-list of names, matched at the start of the string; what follows the name must be
/// nothing or a descriptive suffix opening with "(", ",", ";" or ":", e.g.
/// "international 10-10 (BCI2000 64-ch subset), cropped to 16". No substring match: "not
/// 10-20" or "roughly 10-20 but modified" stay undeclared, and so does "10-10x" or "10-5".
enum MontageRecognizer {
    /// Lower-case names, longest first so "international 10-10 system" wins over "…10-10".
    static let names: [(String, MontageStandard)] = {
        var out: [(String, MontageStandard)] = []
        for (number, standard) in [("10-20", MontageStandard.tenTwenty), ("10-10", .tenTen)] {
            for spelling in [number, number.replacingOccurrences(of: "-", with: "/")] {
                out += [("international \(spelling) system", standard), ("international \(spelling)", standard),
                        ("\(spelling) system", standard), (spelling, standard)]
            }
        }
        return out.sorted { $0.0.count > $1.0.count }
    }()

    static let suffixOpeners: Set<Character> = ["(", ",", ";", ":"]

    static func recognize(_ montage: String) -> MontageStandard? {
        // Collapse runs of whitespace so "international  10-10" still reads as the name.
        let text = montage.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for (name, standard) in names where text.hasPrefix(name) {
            let rest = text.dropFirst(name.count).drop { $0 == " " }
            if rest.isEmpty || suffixOpeners.contains(rest.first!) { return standard }
        }
        return nil
    }
}

/// Label → standard site (lead defaults 1, 3, 4).
enum ElectrodeLabel {
    /// Trims outer whitespace and trailing dots (EDF exports write "Fc3."), nothing else:
    /// interior whitespace and lookalike characters stay as they are, so they don't match.
    static func lookupKey(_ label: String) -> String {
        var s = label.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix(".") { s.removeLast() }
        return s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The canonical 10-10 site a label names under `standard`, or nil. Under 10-20 only the
    /// 10-20 sites place, plus the old names T3/T4/T5/T6 (which resolve to T7/T8/P7/P8); under
    /// 10-10 every 10-10 site places (10-20 is a subset) and the old names don't.
    static func site(for label: String, in standard: MontageStandard) -> StandardPositions.Site? {
        let key = lookupKey(label)
        switch standard {
        case .tenTen:
            return StandardPositions.canonical[key].flatMap { StandardPositions.byLabel[$0] }
        case .tenTwenty:
            if let alias = StandardPositions.tenTwentyAliases.first(where: { $0.key.lowercased() == key })?.value {
                return StandardPositions.byLabel[alias]
            }
            guard let canonical = StandardPositions.canonical[key], StandardPositions.tenTwentyLabels.contains(canonical) else { return nil }
            return StandardPositions.byLabel[canonical]
        }
    }
}

/// Where each channel of one recording goes on the head, and what the view says about it.
struct MontageLayout: Equatable {
    struct Electrode: Identifiable, Equatable {
        /// The channel's stable id; cross-highlighting goes by id, never by label.
        let channelID: String
        /// The stored label, verbatim (the button reads this).
        let label: String
        let site: StandardPositions.Site
        let isReference: Bool
        var id: String { channelID }
    }

    struct Unplaced: Identifiable, Equatable {
        enum Reason: Equatable { case montageUndeclared, labelUndeclared, notInStandard, duplicateSite }
        let channelID: String
        /// The stored label, or nil when the manifest declares none.
        let label: String?
        let reason: Reason
        var id: String { channelID }
        var displayLabel: String { label ?? "\(channelID) (no label)" }
    }

    let standard: MontageStandard?
    /// The declared montage string, or nil when it declares nothing.
    let declaredMontage: String?
    let declaredReference: String?
    let placed: [Electrode]
    let unplaced: [Unplaced]
    /// Channels of a kind other than EEG (or of undeclared kind): not counted in M (lead default 7).
    let excluded: [RecordingDetailModel.ChannelRow]

    /// N and M of "N of M channels placed".
    var placedCount: Int { placed.count }
    var eegCount: Int { placed.count + unplaced.count }
    var referenceElectrode: Electrode? { placed.first(where: \.isReference) }

    init(montage: String, reference: String, channels: [RecordingDetailModel.ChannelRow]) {
        declaredMontage = RecordingDetailModel.declared(montage)
        declaredReference = RecordingDetailModel.declared(reference)
        standard = MontageRecognizer.recognize(montage)
        excluded = channels.filter { $0.kind?.trimmingCharacters(in: .whitespaces).lowercased() != "eeg" }
        let eeg = channels.filter { $0.kind?.trimmingCharacters(in: .whitespaces).lowercased() == "eeg" }

        var placed: [Electrode] = []
        var unplaced: [Unplaced] = []
        var taken = Set<String>()
        for ch in eeg {
            guard let label = ch.label else {
                unplaced.append(Unplaced(channelID: ch.id, label: nil, reason: .labelUndeclared)); continue
            }
            guard let standard else {
                unplaced.append(Unplaced(channelID: ch.id, label: label, reason: .montageUndeclared)); continue
            }
            guard let site = ElectrodeLabel.site(for: label, in: standard) else {
                unplaced.append(Unplaced(channelID: ch.id, label: label, reason: .notInStandard)); continue
            }
            // One point per site: a second channel naming the same site (a repeated label, or
            // T3 beside T7 under 10-20) is listed, not stacked.
            guard taken.insert(site.label).inserted else {
                unplaced.append(Unplaced(channelID: ch.id, label: label, reason: .duplicateSite)); continue
            }
            placed.append(Electrode(channelID: ch.id, label: label, site: site, isReference: false))
        }
        // Lead default 5: the reference is marked only when its declared text, under the same
        // lookup rule, equals a recorded and placed label. "average", "A1+A2" mark nothing.
        if let ref = declaredReference.map(ElectrodeLabel.lookupKey),
           let i = placed.firstIndex(where: { ElectrodeLabel.lookupKey($0.label) == ref }) {
            let e = placed[i]
            placed[i] = Electrode(channelID: e.channelID, label: e.label, site: e.site, isReference: true)
        }
        self.placed = placed
        self.unplaced = unplaced
    }

    init(_ model: RecordingDetailModel) {
        self.init(montage: model.montageRaw, reference: model.referenceRaw, channels: model.channels)
    }

    // MARK: Strings

    /// "international 10-10 system", else the declared text, else "montage undeclared".
    var montageName: String {
        standard?.displayName ?? declaredMontage.map { "\($0) (not a recognized standard)" } ?? "montage undeclared"
    }

    /// decision #18 / brief 003: what VoiceOver reads for the whole view.
    var accessibilityLabel: String {
        "Montage: \(placedCount) of \(eegCount) channel\(eegCount == 1 ? "" : "s") placed, \(montageName)"
    }

    /// The caption under the head.
    var caption: String {
        var parts = ["\(placedCount) of \(eegCount) EEG channel\(eegCount == 1 ? "" : "s") placed · \(standard?.displayName ?? "no named standard montage declared")"]
        if !excluded.isEmpty {
            let names = excluded.map { $0.label ?? $0.id }.joined(separator: ", ")
            parts.append("\(excluded.count) non-EEG channel\(excluded.count == 1 ? "" : "s") not counted (\(names))")
        }
        return parts.joined(separator: "\n")
    }

    /// Reference line: the marked electrode, or the declared text as a caption.
    var referenceCaption: String {
        if let e = referenceElectrode { return "Reference: \(e.label) (marked)" }
        if let ref = declaredReference { return "Reference: \(ref) — not a recorded electrode, so not marked" }
        return "Reference: undeclared"
    }

    /// "Positions undeclared" heading and the labels it lists; nil when everything placed.
    var undeclaredTitle: String? {
        guard !unplaced.isEmpty else { return nil }
        return standard == nil
            ? "Positions undeclared: the recording names no standard montage"
            : "Positions undeclared for \(unplaced.count) channel\(unplaced.count == 1 ? "" : "s") (no standard \(standard == .tenTwenty ? "10-20" : "10-10") site)"
    }

    var unplacedList: String { unplaced.map(\.displayLabel).joined(separator: ", ") }

    func electrode(forChannel id: String?) -> Electrode? {
        guard let id else { return nil }
        return placed.first { $0.channelID == id }
    }
}
