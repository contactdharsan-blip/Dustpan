import SwiftUI

/// The planned cleaning surfaces. v1.0 ships the trust-first core (uninstall,
/// orphans, large files); developer caches are the v1.1 differentiation bet.
enum CleanupCategory: String, CaseIterable, Identifiable {
    case appUninstaller = "App Uninstaller"
    case orphanScan = "Orphaned Files"
    case largeFiles = "Large Files"
    case developerCaches = "Developer Caches"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .appUninstaller: return "trash"
        case .orphanScan: return "doc.badge.gearshape"
        case .largeFiles: return "externaldrive.badge.minus"
        case .developerCaches: return "hammer"
        }
    }

    var milestone: String {
        switch self {
        case .appUninstaller, .orphanScan, .largeFiles: return "v1.0"
        case .developerCaches: return "v1.1"
        }
    }

    var summary: String {
        switch self {
        case .appUninstaller:
            return "Remove an app and every leftover file it left in ~/Library. Safe because you chose to uninstall."
        case .orphanScan:
            return "Find support files, caches, and preferences left behind by apps you already deleted."
        case .largeFiles:
            return "Surface your biggest files and folders. Read-only analysis — you decide what moves to Trash."
        case .developerCaches:
            return "Reclaim Xcode DerivedData, old simulator runtimes, node_modules, and Docker images over known-safe paths."
        }
    }
}

struct ContentView: View {
    @State private var selection: CleanupCategory? = .appUninstaller

    var body: some View {
        NavigationSplitView {
            List(CleanupCategory.allCases, selection: $selection) { category in
                Label(category.rawValue, systemImage: category.systemImage)
                    .badge(category.milestone)
                    .tag(category)
            }
            .navigationTitle("Cleanitup")
            .scrollContentBackground(.hidden)
            .background(Theme.bgSecondary.opacity(0.5))
            .frame(minWidth: 230)
        } detail: {
            ZStack {
                AmbientBackground()
                if let selection {
                    CategoryDetail(category: selection)
                        .id(selection)                       // re-trigger entry motion per selection
                        .transition(.opacity.combined(with: .offset(y: 12)))
                } else {
                    ContentUnavailableView("Select a category", systemImage: "sidebar.left")
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .animation(Theme.spring, value: selection)        // §5 spring on detail change
        }
    }
}

struct CategoryDetail: View {
    let category: CleanupCategory

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Header card
            HStack(spacing: 16) {
                Image(systemName: category.systemImage)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Theme.primary)
                    .frame(width: 56, height: 56)
                    .background(Theme.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous)
                            .strokeBorder(Theme.primary.opacity(0.25), lineWidth: 1)
                    )
                    .shadow(color: Theme.primary.opacity(0.3), radius: 18)  // §4.3 glow

                VStack(alignment: .leading, spacing: 6) {
                    Text(category.rawValue)
                        .font(.system(.title, design: .default).weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    PillBadge(text: "Planned · \(category.milestone)")
                }
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()

            // Summary
            Text(category.summary)
                .font(.body)
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .glassCard(cornerRadius: Theme.radiusXl)

            SafetyBanner()

            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The promise that makes a cleaner trustworthy enough to grant Full Disk Access.
struct SafetyBanner: View {
    private struct Promise: Identifiable {
        let id = UUID()
        let icon: String
        let text: String
        let tint: Color
    }

    private let promises = [
        Promise(icon: "eye", text: "Preview every file and its size before anything is deleted", tint: Theme.primary),
        Promise(icon: "arrow.uturn.backward", text: "Moves to Trash — never a permanent delete", tint: Theme.success),
        Promise(icon: "lock.shield", text: "Never touches SIP-protected system files", tint: Theme.success),
        Promise(icon: "wifi.slash", text: "Zero network calls, zero telemetry — auditable in the source", tint: Theme.primary),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Safe by default", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .labelStyle(.titleAndIcon)
                .imageScale(.large)
                .foregroundStyle(Theme.success)

            ForEach(promises) { promise in
                HStack(spacing: 10) {
                    Image(systemName: promise.icon)
                        .foregroundStyle(promise.tint)
                        .frame(width: 20)
                    Text(promise.text)
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: Theme.radiusXl)
    }
}

#Preview {
    ContentView()
        .frame(width: 820, height: 560)
        .preferredColorScheme(.dark)
}
