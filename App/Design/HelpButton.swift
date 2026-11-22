import SwiftUI

/// Brief 007 PR 5 (decision #46): the native circled "?" (`HelpLink`) opening a short popover
/// from `HelpTopics`. Esc closes it (popover behaviour); VoiceOver reads "Help: <topic>".
struct HelpButton: View {
    let topic: HelpTopic
    @State private var shown = false

    var body: some View {
        HelpLink { shown.toggle() }
            .controlSize(.small)
            .accessibilityLabel(topic.accessibilityLabel)
            .help(topic.accessibilityLabel)
            .popover(isPresented: $shown, arrowEdge: .bottom) { HelpPopover(topic: topic) }
            // Debug `-BCIHelpTopic <id>`: open this topic's popover for a snapshot.
            // (A popover closes while its app is inactive, so the snapshot run activates it.)
            .task {
                guard LaunchArguments.helpTopic == topic else { return }
                try? await Task.sleep(for: .milliseconds(400))
                NSApp.activate()
                shown = true
            }
    }
}

private struct HelpPopover: View {
    let topic: HelpTopic

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(topic.title).font(.headline).foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            ForEach(topic.sentences, id: \.self) { s in
                Text(s).font(.callout).foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 320, alignment: .leading)
        // Solid, so the text keeps its contrast whatever is behind the popover.
        .presentationBackground(Theme.surface1)
    }
}
