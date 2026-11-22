import SwiftUI

// Brief 007 PR 3: the goal picker sheet and the sidebar Guide card. Copy and rules live in
// GuideModels.swift; these views only lay them out.

/// "What do you want to do?": the four goals and "Not now" (decision #43).
struct GuidePickerSheet: View {
    let current: GuideGoal?
    let choose: (GuideGoal) -> Void
    let notNow: () -> Void
    /// The first goal has focus when the sheet opens, and Return chooses the focused goal.
    @FocusState private var focused: GuideGoal?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(GuideCopy.pickerTitle).font(Theme.Fonts.title).foregroundStyle(Theme.textPrimary)
                Text(GuideCopy.pickerMessage).font(.callout).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: Theme.Space.s) {
                ForEach(GuideGoal.allCases) { goal in
                    GoalRow(goal: goal, isCurrent: goal == current) { choose(goal) }
                        .focused($focused, equals: goal)
                        .keyboardShortcut(goal == (focused ?? GuideGoal.allCases[0]) ? .defaultAction : nil)
                }
            }
            .defaultFocus($focused, GuideGoal.allCases[0])
            HStack {
                Spacer()
                Button(GuideCopy.notNow, action: notNow).keyboardShortcut(.cancelAction)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 460)
    }
}

private struct GoalRow: View {
    let goal: GuideGoal
    let isCurrent: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: goal.symbol)
                    .font(.title2).symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.accentInk)
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(goal.title).font(.body.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                    Text(goal.summary).font(.callout).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if isCurrent {
                    Image(systemName: "checkmark").foregroundStyle(Theme.accentInk).accessibilityHidden(true)
                }
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovered ? Theme.surface2 : Theme.surface1, in: .rect(cornerRadius: Theme.Radius.cell))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.cell).strokeBorder(isCurrent ? Theme.accentInk : Theme.hairline))
            .contentShape(.rect(cornerRadius: Theme.Radius.cell))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(goal.title)
        .accessibilityHint(goal.summary)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// The sidebar's Guide card (decision #44): goal, "Step k of n", the steps (done ones folded
/// into one line, then the current step and the next two; all on "Show all steps"), the
/// current step's instruction with Show me and Skip step, or the all-done state.
struct GuideCard: View {
    let progress: GuideProgress
    let collapsed: Bool
    /// The step Skip step last skipped: the card offers "Undo skip" for it.
    var lastSkipped: GuideStep.ID? = nil
    let toggleCollapsed: () -> Void
    let hide: () -> Void
    let changeGoal: () -> Void
    let skip: (GuideStep.ID) -> Void
    let unskip: (GuideStep.ID) -> Void
    let showMe: (GuideStep) -> Void
    @State private var showsAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs + 2) {
            header
            if !collapsed {
                steps
                if let current = progress.current {
                    Text(current.step.instruction)
                        .font(.caption).foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: Theme.Space.s) {
                        Button(GuideCopy.showMe) { showMe(current.step) }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            .help(GuideCopy.showMeHelp)
                        if let undo = undoable {
                            Button(GuideCopy.undoSkip) { unskip(undo) }
                                .buttonStyle(.borderless).controlSize(.small)
                        } else {
                            Button(GuideCopy.skipStep) { skip(current.id) }
                                .buttonStyle(.borderless).controlSize(.small)
                                .help(GuideCopy.skipHelp)
                        }
                    }
                } else {
                    Text(progress.finishedMessage)
                        .font(.caption).foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: Theme.Space.s) {
                        Button(GuideCopy.chooseAnother, action: changeGoal).controlSize(.small)
                        if let undo = undoable {
                            Button(GuideCopy.undoSkip) { unskip(undo) }.buttonStyle(.borderless).controlSize(.small)
                        } else {
                            Button(GuideCopy.hideGuide, action: hide).buttonStyle(.borderless).controlSize(.small)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s + 2)
        // No fixedSize anywhere in the card: in a safe-area inset a text measured at its
        // ideal width pushes the window content past the window (see StatusArea).
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        // Solid on the sidebar: no glass on glass.
        .background(Theme.surface1, in: .rect(cornerRadius: Theme.Radius.cell))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.cell).strokeBorder(Theme.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(GuideCopy.cardAccessibility(progress))
    }

    /// The last skipped step while it is still skipped.
    private var undoable: GuideStep.ID? {
        guard let lastSkipped, progress.rows.contains(where: { $0.id == lastSkipped && $0.state == .skipped }) else { return nil }
        return lastSkipped
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
            VStack(alignment: .leading, spacing: 1) {
                Text(progress.goal.shortTitle).font(.caption.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(progress.isFinished ? GuideCopy.finishedLine(done: progress.doneCount, of: progress.rows.count) : progress.stepLine)
                    .font(.caption2).foregroundStyle(Theme.textSecondary).monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Menu {
                Button(GuideCopy.changeGoal, action: changeGoal)
                Button(GuideCopy.hideGuide, action: hide).help(GuideCopy.hideHelp)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
            .accessibilityLabel("Guide options")
            Button(action: toggleCollapsed) {
                Image(systemName: collapsed ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(GuideCopy.cardTitle)
            .accessibilityValue(collapsed ? GuideCopy.collapsedValue : GuideCopy.expandedValue)
            .accessibilityHint(collapsed ? GuideCopy.expand : GuideCopy.collapse)
            .help(collapsed ? GuideCopy.expand : GuideCopy.collapse)
        }
    }

    private var steps: some View {
        let window = progress.window(showsAll: showsAll)
        return VStack(alignment: .leading, spacing: 1) {
            if window.hasFold {
                Button { showsAll = true } label: {
                    line(symbol: GuideProgress.StepState.done.symbol, tint: Theme.positive,
                         text: GuideCopy.folded(done: window.foldedDone, skipped: window.foldedSkipped.count), primary: false)
                }
                .buttonStyle(.plain)
                .help(GuideCopy.showAllSteps)
                .contextMenu {
                    ForEach(window.foldedSkipped, id: \.self) { id in
                        Button("\(GuideCopy.undoSkip): \(GuideStep.step(id).title)") { unskip(id) }
                    }
                }
            }
            ForEach(window.rows) { row in
                line(symbol: row.state.symbol, tint: tint(row.state), text: row.step.title,
                     primary: row.state == .done || row.state == .current, bold: row.state == .current, struck: row.state == .skipped)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(row.accessibilityLabel)
                    .contextMenu {
                        if row.state == .skipped { Button(GuideCopy.undoSkip) { unskip(row.id) } }
                    }
            }
            if window.more > 0 || showsAll {
                Button(showsAll ? GuideCopy.showFewerSteps : GuideCopy.more(window.more)) { showsAll.toggle() }
                    .buttonStyle(.link).font(.caption2)
                    .padding(.leading, 18)
            }
        }
    }

    private func line(symbol: String, tint: Color, text: String, primary: Bool, bold: Bool = false, struck: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 14).accessibilityHidden(true)
            Text(text)
                .fontWeight(bold ? .semibold : .regular)
                .foregroundStyle(primary ? Theme.textPrimary : Theme.textSecondary)
                .strikethrough(struck, color: Theme.textSecondary)
                .lineLimit(2)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    private func tint(_ s: GuideProgress.StepState) -> Color {
        switch s {
        case .done: return Theme.positive
        case .current: return Theme.accentInk
        case .skipped, .todo: return Theme.textSecondary
        }
    }
}
