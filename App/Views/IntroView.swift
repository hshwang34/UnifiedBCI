import SwiftUI

/// The first-run intro (brief 003, decisions #13 and #14): a mode of the 760×460 Welcome
/// window. Left, the shared head with the neural field and a self-drawing trace; right,
/// one glass panel per step that morphs into the next. Skip is always visible and first for
/// VoiceOver; ←/→ and Return move, Esc skips.
struct IntroView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var glass
    @FocusState private var focused: Bool
    @State private var visible = true
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var start = Date()
    @State private var clock = FrameClock()

    private var step: Int { workspace.welcomeFlow.step ?? 0 }
    private var kind: IntroStep.Kind { IntroModel.steps[step].kind }

    private var policy: MotionPolicy {
        MotionPolicy(reduceMotion: LaunchArguments.reduceMotion(system: systemReduceMotion),
                     reduceTransparency: reduceTransparency, lowPower: lowPower,
                     // Debug: a frame log measures even when the window is on another Space.
                     occluded: !visible && LaunchArguments.frameLogURL == nil)
    }

    /// Step changes: a smooth morph, or instant under Reduce Motion (brief 003).
    private var stepAnimation: Animation? { policy.animates ? .smooth(duration: 0.55) : nil }

    var body: some View {
        HStack(spacing: 0) {
            stage
                .frame(width: 360)
            panelColumn
                .padding(.leading, Theme.Space.s)
                .padding(.trailing, Theme.Space.xxl)
                .padding(.vertical, Theme.Space.xl)
        }
        .frame(width: 760, height: 460)
        .background { AmbientBackdrop() }
        .background { WindowVisibilityReader(visible: $visible) }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            perform(WelcomeFlow.command(for: press.key == .leftArrow ? .leftArrow : .rightArrow))
            return .handled
        }
        .onAppear {
            focused = true
            announce()
        }
        .onChange(of: workspace.welcomeFlow.generation) { start = Date() }
        .onChange(of: step) { announce() }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onDisappear { clock.flush("intro") }
        .animation(stepAnimation, value: step)
    }

    /// Animated by the `.animation(_:value:)` below, so a step changed from anywhere (keys,
    /// buttons, the Debug tour) moves the same way.
    private func perform(_ command: IntroCommand) {
        workspace.welcomeFlow.apply(command)
    }

    private func announce() {
        AccessibilityNotification.Announcement(IntroModel.announcement(step)).post()
    }

    // MARK: Stage

    private var stage: some View {
        VStack(spacing: 0) {
            HeadStage(orbit: IntroModel.orbit(for: kind), distance: 820) { camera, size in
                IntroMarks(camera: camera, size: size, lit: IntroModel.litLabels(for: kind), labelled: IntroModel.showsLabels(kind))
                NeuralFieldLayer(camera: camera, size: size, lit: IntroModel.litLabels(for: kind),
                                 policy: policy, start: start, clock: clock)
            }
            .padding(.top, Theme.Space.xl)
            TraceStrip(live: kind != .hardwarePhase2, policy: policy, start: start)
                .frame(height: 54)
                .padding(.horizontal, Theme.Space.xxl)
                .padding(.bottom, Theme.Space.xl)
        }
        .accessibilityHidden(true)
    }

    // MARK: Panel

    private var panelColumn: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack {
                StepDots(count: IntroModel.steps.count, current: step)
                Spacer()
                Button { perform(.skip) } label: {
                    Text("Skip").font(.body).foregroundStyle(Theme.textSecondary).padding(.horizontal, 6).padding(.vertical, 3).contentShape(Rectangle())
                }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.plain)
                    .help("Skip the tour (Esc)")
                    .accessibilitySortPriority(3)
                    .accessibilityHint("Goes to the welcome screen")
            }
            Spacer(minLength: 0)
            GlassGroup(spacing: 14) {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    textPanel
                    accessory
                }
            }
            Spacer(minLength: 0)
            HStack {
                Button { perform(.back) } label: { Label("Back", systemImage: "chevron.left") }
                    .disabled(step == 0)
                    .controlSize(.large)
                    .accessibilitySortPriority(1)
                Spacer()
                Button { perform(.next) } label: { Text(IntroModel.nextTitle(at: step)).frame(minWidth: 84) }
                    .keyboardShortcut(.defaultAction)
                    .appProminentButton()
                    .accessibilitySortPriority(1)
            }
        }
    }

    private var textPanel: some View {
        let s = IntroModel.steps[step]
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(IntroModel.position(step).uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.accentInk)
            Text(s.title)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(s.body)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.l + 4)
        .id(s.kind)
        .transition(.opacity)
        .morphingGlass(id: "panel", in: glass, cornerRadius: Theme.Radius.hero, morphs: policy.morphsGlass)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(s.accessibilityLabel)
        .accessibilityValue(IntroModel.position(step))
        .accessibilitySortPriority(2)
    }

    @ViewBuilder private var accessory: some View {
        switch kind {
        case .whatItDoes:
            HStack(spacing: Theme.Space.s) {
                ForEach(Array(Self.verbs.enumerated()), id: \.offset) { i, verb in
                    VStack(spacing: Theme.Space.xs) {
                        Image(systemName: verb.1)
                            .font(.system(size: 17))
                            .foregroundStyle(Theme.accentInk)
                            .accessibilityHidden(true)
                        Text(verb.0)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Space.m)
                    .morphingGlass(id: "chip\(i)", in: glass, cornerRadius: 16, style: GlassStyle(scrim: (0.45, 0.4)), morphs: policy.morphsGlass)
                }
            }
            .accessibilityElement(children: .combine)
        case .honestUncertainty:
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                RangeBar(value: IntroModel.Illustration.value, interval: IntroModel.Illustration.interval,
                         reference: .init(value: IntroModel.Illustration.chance, label: "Chance"),
                         label: IntroModel.Illustration.accessibilityLabel)
                Text(IntroModel.Illustration.caption)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Space.l)
            .morphingGlass(id: "chip0", in: glass, cornerRadius: Theme.Radius.card, morphs: policy.morphsGlass)
        case .tryExample:
            chip(id: "chip0", symbol: "sparkles.rectangle.stack", title: "Explore an example",
                 detail: "Next, on the welcome screen · PhysioNet S001 · 16 channels")
        case .hardwarePhase2:
            chip(id: "chip0", symbol: "cable.connector", title: "Connect hardware",
                 detail: "OpenBCI Cyton + Daisy · phase 2")
        }
    }

    private static let verbs = [("Import", "square.and.arrow.down"), ("Inspect", "waveform"),
                                ("Evaluate", "chart.bar.xaxis"), ("Reproduce", "arrow.triangle.2.circlepath")]

    private func chip(id: String, symbol: String, title: String, detail: String) -> some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 22))
                .foregroundStyle(Theme.accentInk)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(.headline, design: .rounded)).foregroundStyle(Theme.textPrimary)
                Text(detail).font(.callout).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .morphingGlass(id: id, in: glass, cornerRadius: 18, style: GlassStyle(scrim: (0.45, 0.4)), morphs: policy.morphsGlass)
        .accessibilityElement(children: .combine)
    }
}

/// Step position by shape and size, not colour alone: the current step is a wide capsule.
private struct StepDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Theme.accentInk : Theme.textTertiary.opacity(0.5))
                    .frame(width: i == current ? 22 : 7, height: 7)
            }
        }
        .accessibilityHidden(true)
    }
}
