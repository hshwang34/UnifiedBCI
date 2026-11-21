import SwiftUI

/// Brief 005: the Protocols section's list (content column): one section per lineage,
/// versions newest first, with use and a mislinked flag.
struct ProtocolsList: View {
    @Bindable var session: ProjectSession

    var body: some View {
        if let list = session.protocolList {
            let model = ProtocolListModel(list: list, usage: session.protocolUsage)
            if model.isEmpty {
                ContentUnavailableView {
                    Label(ProtocolCopy.emptyTitle, systemImage: SidebarSection.protocols.symbol)
                } description: {
                    Text(session.protocolsError ?? model.footnote ?? ProtocolCopy.emptyDescription).foregroundStyle(Theme.textSecondary)
                }
            } else {
                List(selection: $session.selectedProtocolID) {
                    ForEach(model.groups) { group in
                        Section(group.title) {
                            ForEach(group.rows) { row in
                                ProtocolRow(row: row)
                                    .tag(row.id)
                                    .contextMenu {
                                        Button(ProtocolCopy.newVersion) {
                                            if let r = list.protocols.first(where: { $0.protocolID == row.id }) { session.newProtocolVersion(of: r) }
                                        }
                                        .disabled(row.mislinked)
                                    }
                            }
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if let note = session.protocolsError ?? model.footnote {
                        Text(note).font(.caption).foregroundStyle(Theme.textSecondary)
                            .padding(Theme.Space.m).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        } else if let error = session.protocolsError {
            ContentUnavailableView {
                Label(ProtocolCopy.emptyTitle, systemImage: "exclamationmark.triangle")
            } description: {
                Text(error).foregroundStyle(Theme.textSecondary)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ProtocolRow: View {
    let row: ProtocolListModel.Row

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Text(row.version).font(.callout.weight(.semibold)).monospacedDigit()
                .frame(minWidth: 28, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).lineLimit(1)
                Text(row.usedIn).font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: Theme.Space.xs)
            if row.mislinked {
                // Symbol and word: never colour alone.
                Label(ProtocolCopy.mislinkedRow, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).labelStyle(.titleAndIcon)
                    .foregroundStyle(Theme.textPrimary)
                    .symbolRenderingMode(.multicolor)
            }
        }
        .padding(.vertical, 2)
        .help(row.mislinked ? ProtocolCopy.mislinked : row.usedIn)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibility)
    }
}

/// One version: what the participant sees and when, its classes, instructions and identity.
struct ProtocolDetailView: View {
    let model: ProtocolDetailModel
    let newVersion: () -> Void

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    header
                    ForEach(model.warnings, id: \.self) { StatusChip(kind: .warning, text: $0) }
                    card("Timing") { fields(model.timing) }
                    card("Classes") { classes }
                    card("Participant instructions") {
                        Text(model.instructions).font(.body).foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    card("Identity") { fields(model.identity) }
                    Text(ProtocolCopy.timingCaveat).font(.caption).foregroundStyle(Theme.textSecondary)
                }
                .padding(Theme.Space.pageMargin)
                .frame(width: geo.size.width, alignment: .leading)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text(model.title).font(Theme.Fonts.title).foregroundStyle(Theme.textPrimary)
                    Text(model.badge)
                        .font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.xxs)
                        .background(Theme.surface2, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.hairline))
                        .accessibilityLabel("Version \(model.badge.dropFirst())")
                }
                Text("\(model.lineage) · \(model.usedIn)").font(.callout).foregroundStyle(Theme.textSecondary)
                Text(ProtocolCopy.immutable).font(.caption).foregroundStyle(Theme.textSecondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: Theme.Space.m)
            Button(ProtocolCopy.newVersion, action: newVersion)
                .buttonStyle(.bordered)
                .disabled(!model.canCreateVersion)
                .help(model.canCreateVersion ? ProtocolCopy.newVersionHelp : ProtocolCopy.mislinked)
        }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(title).font(Theme.Fonts.sectionHeader).foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func fields(_ fields: [ProtocolDetailModel.Field]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Space.l, verticalSpacing: Theme.Space.s) {
            ForEach(fields) { f in
                GridRow {
                    Text(f.label).foregroundStyle(Theme.textSecondary).gridColumnAlignment(.leading)
                    Text(f.value)
                        .font(f.mono ? Theme.Fonts.mono : .body).monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var classes: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            ForEach(model.classes) { c in
                HStack(spacing: Theme.Space.m) {
                    Image(systemName: c.symbol)
                        .font(.title3.weight(.semibold)).foregroundStyle(Theme.accentInk)
                        .frame(width: 36, height: 36)
                        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.displayName).foregroundStyle(Theme.textPrimary)
                        Text("\(c.cue) · stored as ").foregroundStyle(Theme.textSecondary)
                            + Text(c.label).font(Theme.Fonts.monoCaption).foregroundStyle(Theme.textSecondary)
                    }
                    .font(.callout)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(c.displayName): \(c.cue), stored as \(c.label)")
            }
        }
    }
}

/// "New version…": a sheet with the version's values; Save stays disabled while any rule
/// is broken, and each broken rule is named under the form.
struct ProtocolEditorSheet: View {
    @Bindable var editor: ProtocolEditor
    let save: () async -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(editor.title).font(Theme.Fonts.title)
                Text(editor.subtitle).font(.callout).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top], Theme.Space.xl)
            .accessibilityElement(children: .combine)
            Form {
                Section {
                    TextField("Name", text: $editor.name)
                }
                ForEach(editor.classes.indices, id: \.self) { i in
                    Section("Class \(i + 1)") {
                        TextField("Display name", text: $editor.classes[i].displayName)
                        LabeledContent("Stored label") {
                            TextField("Stored label", text: $editor.classes[i].label)
                                .labelsHidden().multilineTextAlignment(.trailing).font(Theme.Fonts.mono)
                        }
                        .help("Written on every cue event and used by the evaluation: a–z, 0–9 and _.")
                        Picker("Cue", selection: $editor.classes[i].cue) {
                            ForEach(CueSymbol.allCases, id: \.self) { s in Label(s.title, systemImage: s.symbol).tag(s) }
                        }
                    }
                }
                Section {
                    seconds("Fixation", $editor.fixation)
                    seconds("Cue", $editor.cue)
                    seconds("Shortest rest", $editor.restMin)
                    seconds("Longest rest", $editor.restMax)
                } header: {
                    Text("Timing")
                } footer: {
                    Text("In seconds, to the millisecond. Rest is drawn per trial between the two.").foregroundStyle(Theme.textSecondary)
                }
                Section("Trials") {
                    count("Trials per class", $editor.trialsPerClass, ProtocolRecord.trialsPerClassRange)
                    count("Runs per session", $editor.runsPerSession, 1...ProtocolRecord.maxRunsPerSession)
                }
                Section("Participant instructions") {
                    TextEditor(text: $editor.instructions)
                        .font(.body)
                        .frame(minHeight: 72)
                        .accessibilityLabel("Participant instructions")
                }
            }
            .formStyle(.grouped)
            issues
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                    .disabled(editor.isSaving)
                Button(editor.saveTitle) { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!editor.canSave)
            }
            .padding(Theme.Space.xl)
        }
        .frame(width: 560, height: 720)
    }

    @ViewBuilder private var issues: some View {
        let list = editor.issues
        if !list.isEmpty || editor.saveError != nil {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    if let error = editor.saveError { StatusChip(kind: .danger, text: error) }
                    ForEach(list) { StatusChip(kind: $0.kind == .error ? .danger : .warning, text: $0.text) }
                }
                .padding(.horizontal, Theme.Space.xl)
                .padding(.top, Theme.Space.s)
            }
            .frame(maxHeight: 150)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func seconds(_ title: String, _ value: Binding<String>) -> some View {
        LabeledContent(title) {
            HStack(spacing: Theme.Space.xs) {
                TextField(title, text: value)
                    .labelsHidden().multilineTextAlignment(.trailing).monospacedDigit()
                    .accessibilityHint("Seconds, up to 3 decimal places")
                Text("s").foregroundStyle(Theme.textSecondary).accessibilityHidden(true)
            }
        }
    }

    /// A whole-number field: typed text (an invalid entry stays visible and is named under
    /// the form) with a stepper that works from the last valid value.
    private func count(_ title: String, _ text: Binding<String>, _ range: ClosedRange<Int>) -> some View {
        let number = Binding<Int>(get: { Int(text.wrappedValue.trimmingCharacters(in: .whitespaces)) ?? range.lowerBound },
                                  set: { text.wrappedValue = String($0) })
        return LabeledContent(title) {
            HStack(spacing: Theme.Space.s) {
                TextField(title, text: text)
                    .labelsHidden().multilineTextAlignment(.trailing).monospacedDigit().frame(width: 64)
                Stepper(title, value: number, in: range).labelsHidden()
            }
        }
    }
}
