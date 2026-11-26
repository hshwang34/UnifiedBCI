import SwiftUI

/// Above a project's detail column while a coding agent works in it (brief 008): what the
/// agent is running, and any step waiting for the person. Decision #48: only the person
/// answers these. Confirm / Decline for `operator.request`; for runs, the step itself
/// (Space, Resume) is the answer.
struct AgentBanner: View {
    let project: URL
    @State private var activity = AgentActivity.shared

    var body: some View {
        let prompts = activity.prompts(for: project)
        let running = activity.running[project]
        if running != nil || !prompts.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let running {
                    Label("A coding agent is running \(running) in this project", systemImage: "terminal")
                        .font(.callout.weight(.medium))
                }
                ForEach(prompts) { p in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                        Image(systemName: p.asks ? "person.crop.circle.badge.questionmark" : "hand.raised")
                            .foregroundStyle(Theme.warning)
                        Text(p.message)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if p.asks {
                            Button("Decline") { activity.answer(p.id, false) }
                            Button("Confirm") { activity.answer(p.id, true) }
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Waiting for you: \(p.message)")
                }
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: 680, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.warning.opacity(prompts.isEmpty ? 0 : 0.8)))
            .padding(.horizontal, Theme.Space.l)
            .padding(.bottom, Theme.Space.l)
        }
    }
}
