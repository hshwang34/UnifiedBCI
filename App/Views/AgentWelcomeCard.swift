import SwiftUI

/// Brief 008: the one-time welcome-screen card for people who saw the intro before agent
/// control existed. Set Up… opens Settings ▸ Agent Control; either button retires it.
struct AgentWelcomeCard: View {
    let dismiss: () -> Void
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // Brief 011: a slim row under Recent Projects, not a hero card.
        HStack(alignment: .center, spacing: Theme.Space.s) {
            Image(systemName: AgentIntroCopy.symbol)
                .font(.title3)
                .foregroundStyle(Theme.accentInk)
                .accessibilityHidden(true)
            // The title only, wrapping; the detail is the row's tooltip and VoiceOver text.
            Text(AgentIntroCopy.cardTitle)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .help(AgentIntroCopy.cardDetail)
            Spacer(minLength: 0)
            Button(AgentIntroCopy.cardAction) {
                dismiss()
                openSettings()
            }
            .controlSize(.small)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.textSecondary)
                .help(AgentIntroCopy.cardClose)
                .accessibilityLabel(AgentIntroCopy.cardClose)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .frame(maxWidth: .infinity)
        .glassSurface(cornerRadius: 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(AgentIntroCopy.cardBadge): \(AgentIntroCopy.cardTitle). \(AgentIntroCopy.cardDetail)")
    }
}
