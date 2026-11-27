#if DEBUG
import AppKit
import SwiftUI

/// Debug only (`-BCIOffscreenSnapshotDir <dir>`): renders the brief 003 surfaces with
/// `ImageRenderer`, so snapshots work with the display asleep or the session locked, where
/// window captures come back blank. Writes, per appearance (light, dark):
/// `intro-<step>-<appearance>.png` (with `-BCIReduceMotion YES` the still frames) and
/// `montage-<preset>-<appearance>.png` for the bundled example recording.
@MainActor
enum OffscreenSnapshots {
    static func run(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suffix = UserDefaults.standard.bool(forKey: "BCIReduceMotion") ? "-reducemotion" : ""
        for scheme in [ColorScheme.light, .dark] {
            let name = scheme == .dark ? "dark" : "light"
            NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            for step in IntroModel.steps.indices {
                let workspace = Workspace(recents: InMemoryRecentDocuments(), launch: nil)
                workspace.welcomeFlow.start(at: step)
                write(IntroView().environment(workspace), scheme: scheme, to: dir.appendingPathComponent("intro-\(step)-\(name)\(suffix).png"))
            }
            if let model = exampleModel() {
                for preset in Orbit.Preset.allCases {
                    let view = MontageView(layout: MontageLayout(model), selected: .constant("ch05"), hovered: .constant("ch09"), initialOrbit: preset.orbit)
                        .padding(Theme.Space.pageMargin)
                        .frame(width: 720)
                        .background(AmbientBackdrop())
                    write(view, scheme: scheme, to: dir.appendingPathComponent("montage-\(preset.rawValue)-\(name)\(suffix).png"))
                    if preset == .reset {
                        UserDefaults.standard.set(true, forKey: "BCIReduceTransparency")
                        write(view, scheme: scheme, to: dir.appendingPathComponent("montage-reset-\(name)-reducetransparency.png"))
                        UserDefaults.standard.removeObject(forKey: "BCIReduceTransparency")
                        write(view.environment(\._colorSchemeContrast, .increased), scheme: scheme,
                              to: dir.appendingPathComponent("montage-reset-\(name)-increasecontrast.png"))
                    }
                }
            }
        }
    }

    /// Brief 010: every participant card as the second display would show it (1440 × 900),
    /// `participant-<kind>.png`. The window itself steps aside between runs on one display,
    /// so a window capture can't show the break card there.
    static func participantCards(_ p: ProtocolRecord, runsPerSession: Int, into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let context = ParticipantRunContext(runIndex: 1, runsPerSession: runsPerSession, protocolRecord: p)
        let cases: [(String, String?, ParticipantScreen)] = [
            ("instructions", p.instructions, .instructions), ("paused", nil, .paused),
            ("between-runs", nil, .betweenRuns(completed: 2, endedEarly: false)), ("session-done", nil, .sessionDone),
        ]
        let bg = Color(.sRGB, red: CueWindowModel.background.r, green: CueWindowModel.background.g, blue: CueWindowModel.background.b)
        for (name, text, screen) in cases {
            let state = ParticipantCardState()
            state.card = ParticipantCardModel.make(instructionsText: text, screen: screen, context: context)
            let view = ParticipantCardStage(state: state).frame(width: 1440, height: 900).background(bg)
            write(view, scheme: .dark, to: dir.appendingPathComponent("participant-\(name).png"))
        }
    }

    private static func write(_ view: some View, scheme: ColorScheme, to url: URL) {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    /// The bundled example's recording detail model, read straight from the app bundle.
    private static func exampleModel() -> RecordingDetailModel? {
        guard let project = BundledExample.locate(),
              let dir = try? FileManager.default.contentsOfDirectory(at: project.appendingPathComponent("recordings"), includingPropertiesForKeys: nil).first,
              let data = try? Data(contentsOf: dir.appendingPathComponent("recording.json")),
              let manifest = try? ContractJSON.decoder().decode(RecordingManifest.self, from: data) else { return nil }
        return RecordingDetailModel(manifest: manifest, events: [])
    }
}
#endif
