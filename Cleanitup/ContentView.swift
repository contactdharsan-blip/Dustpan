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
            .frame(minWidth: 220)
        } detail: {
            if let selection {
                CategoryDetail(category: selection)
            } else {
                ContentUnavailableView("Select a category", systemImage: "sidebar.left")
            }
        }
    }
}

struct CategoryDetail: View {
    let category: CleanupCategory

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: category.systemImage)
                    .font(.system(size: 32))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text(category.rawValue).font(.title.bold())
                    Text("Planned for \(category.milestone)").foregroundStyle(.secondary)
                }
            }

            Text(category.summary)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SafetyBanner()

            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The promise that makes a cleaner trustworthy enough to grant Full Disk Access.
struct SafetyBanner: View {
    private let promises = [
        ("eye", "Preview every file and its size before anything is deleted"),
        ("arrow.uturn.backward", "Moves to Trash — never a permanent delete"),
        ("lock.shield", "Never touches SIP-protected system files"),
        ("wifi.slash", "Zero network calls, zero telemetry — auditable in the source"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Safe by default").font(.headline)
            ForEach(promises, id: \.0) { icon, text in
                Label(text, systemImage: icon).font(.callout)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }
}

#Preview {
    ContentView()
}
