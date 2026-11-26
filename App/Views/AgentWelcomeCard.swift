import SwiftUI

/// Brief 008: the one-time welcome-screen card for people who saw the intro before agent
/// control existed. Set Up… opens Settings ▸ Agent Control; either button retires it.
struct AgentWelcomeCard: View {
    let dismiss: () -> Void
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: 2) {
                Label(AgentIntroCopy.cardBadge.uppercased(), systemImage: AgentIntroCopy.symbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.accentInk)
                Text(AgentIntroCopy.cardTitle)
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(AgentIntroCopy.cardDetail)
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: Theme.Space.xs) {
                Button(AgentIntroCopy.cardAction) {
                    dismiss()
                    openSettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button(AgentIntroCopy.cardClose, action: dismiss)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .frame(maxWidth: 380)
        .glassSurface(cornerRadius: 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(AgentIntroCopy.cardBadge): \(AgentIntroCopy.cardTitle). \(AgentIntroCopy.cardDetail)")
    }
}
