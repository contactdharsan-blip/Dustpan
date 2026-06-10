import SwiftUI

// Phase 4.2 UI — login items & launch agents, REPORT-ONLY. This surface
// deliberately offers no disable/remove button (launchd actions are a later,
// separately-consented release): it answers "what starts itself on my Mac,
// and is its app even still installed?" — comprehension first.

struct LoginItemsView: View {
    @State private var items: [LoginItem] = []
    @State private var loaded = false

    private var grouped: [(domain: LoginItem.Domain, items: [LoginItem])] {
        LoginItem.Domain.allCases
            .map { d in (domain: d, items: items.filter { $0.domain == d }) }
            .filter { !$0.items.isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                explainer
                if !loaded {
                    SkeletonView(width: 320, height: 14)
                } else if items.isEmpty {
                    EmptyStateView(
                        title: "No third-party launch items",
                        message: "Nothing non-Apple was found in the readable launchd folders. That's healthy.",
                        systemImage: "checkmark.seal")
                    .frame(maxWidth: .infinity)
                } else {
                    ForEach(grouped, id: \.domain) { group in
                        Text(group.domain.rawValue)
                            .font(Typo.cardHeading).foregroundStyle(Theme.textPrimary)
                            .padding(.top, 6)
                        VStack(spacing: 10) {
                            ForEach(group.items) { LoginItemRow(item: $0) }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task {
            guard !loaded else { return }
            items = await Task.detached(priority: .userInitiated) { LoginItemsEngine.scan() }.value
            loaded = true
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "power")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Theme.primary)
                .frame(width: 54, height: 54)
                .background(Theme.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).strokeBorder(Theme.primary.opacity(0.25), lineWidth: 1))
            VStack(alignment: .leading, spacing: 6) {
                Text("Login Items & Background Agents").font(Typo.h3).foregroundStyle(Theme.textPrimary)
                Text("What starts itself on this Mac — explained, not touched.")
                    .font(.callout).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            PillBadge(text: "report-only", tint: Theme.success)
        }
        .padding(20)
        .glassCard()
    }

    private var explainer: some View {
        Text("These are the third-party launchd jobs readable without admin rights (~/Library/LaunchAgents, /Library/LaunchAgents, /Library/LaunchDaemons). The full System Settings “Login Items” list lives in a database macOS only opens for administrators, so this view is honest about being a subset. Removing launch items can break the apps that own them — this release explains; it doesn't touch.")
            .font(.caption).foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct LoginItemRow: View {
    let item: LoginItem

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: item.readable ? "gearshape.2" : "questionmark.square.dashed")
                .font(.system(size: 18))
                .foregroundStyle(item.programExists || !item.readable ? Theme.textSecondary : Theme.warning)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.vendorTitle).font(Typo.cardHeading).foregroundStyle(Theme.textPrimary)
                    if item.readable && !item.programExists {
                        PillBadge(text: "binary missing", tint: Theme.warning)
                    }
                    if item.readable && !item.vendorInstalled {
                        PillBadge(text: "no matching app installed", tint: Theme.warning)
                    }
                    if !item.readable {
                        PillBadge(text: "unreadable", tint: Theme.warning)
                    }
                }
                Text(item.label).font(Typo.mono).foregroundStyle(Theme.textTertiary)
                Text(item.schedule + item.provenance)
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let program = item.programPath {
                    Text(program).font(Typo.mono).foregroundStyle(Theme.textTertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            Button("Reveal") {
                NSWorkspace.shared.activateFileViewerSelecting([item.plistURL])
            }
            .buttonStyle(GlassButtonStyle())
        }
        .padding(14)
        .glassCard(cornerRadius: Theme.radiusLg)
    }
}
