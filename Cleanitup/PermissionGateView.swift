import SwiftUI

// MARK: - Preference keys

/// UserDefaults keys. Convention (first use in the app — sets precedent):
/// lowerCamelCase, named for the fact they record, declared here once and
/// referenced via the constant, never a string literal at a call site.
enum PrefKey {
    /// True once the one-time permission moment has been shown and dismissed —
    /// by Continue OR Skip, regardless of grant outcomes. "Ask once" means the
    /// MOMENT happens once, not that it must end in a grant.
    static let permissionFlowCompleted = "permissionFlowCompleted"
}

// MARK: - Permission probe

/// Per-folder outcome of the one-time consent moment.
struct FolderPermission: Identifiable {
    enum State { case undetermined, asking, granted, denied }
    let id: String        // matches StatsEngine category ids
    let name: String
    let systemImage: String
    let url: URL
    var state: State = .undetermined
}

/// The deliberate up-front permission touch. There is no TCC request API —
/// a read attempt IS the request — so "asking" means listing each gated folder
/// once so macOS shows its consent dialog NOW instead of mid-scan.
enum PermissionProbe {
    /// The TCC-gated folders both the dashboard sizing and the Large Files
    /// quick scan read (ids/symbols mirror StatsEngine.categories).
    static func gatedFolders() -> [FolderPermission] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            ("desktop", "Desktop", "menubar.dock.rectangle"),
            ("documents", "Documents", "doc"),
            ("downloads", "Downloads", "arrow.down.circle"),
        ].map {
            FolderPermission(id: $0.0, name: $0.1, systemImage: $0.2,
                             url: home.appendingPathComponent($0.1))
        }
    }

    /// Touch one folder so its TCC dialog fires now. BLOCKS until the user
    /// answers, so callers run it off the main thread, one folder at a time
    /// (sequential dialogs, never stacked). Idempotent: an already-answered
    /// folder returns instantly with the remembered verdict. A missing folder
    /// counts as granted — nothing to deny; sizing honestly reports 0.
    static func probe(_ url: URL) -> Bool {
        do {
            _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            return true
        } catch {
            return !SafeDeleteEngine.isPermissionError(error)
        }
    }

    /// Full Disk Access has no dialog at all — denial is a silent EPERM — so
    /// probing is side-effect free. Tri-state on purpose (honesty contract):
    /// `granted`/`notGranted` are real observations against known-FDA-gated
    /// sentinels; a Mac with no decisive sentinel reads `unknown` and renders
    /// "—", never a guess.
    enum FDAState { case granted, notGranted, unknown }

    static func fullDiskAccessState() -> FDAState {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        for sentinel in ["Library/Mail", "Library/Messages", "Library/Safari"] {
            let url = home.appendingPathComponent(sentinel)
            var isDir: ObjCBool = false
            // stat is allowed without FDA; LISTING is what TCC gates.
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            do {
                _ = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                return .granted
            } catch {
                if SafeDeleteEngine.isPermissionError(error) { return .notGranted }
            }
        }
        return .unknown
    }
}

// MARK: - Permission gate sheet

/// The one-time permission moment, shown by ContentView before the first scan.
/// Same honesty contract as the dashboard: explain exactly what is read and
/// why, show real per-folder verdicts, no fearmongering, and whatever the user
/// decides here the app never proactively asks again — denied folders keep the
/// quiet "—" / "Needs permission" affordances downstream.
struct PermissionGateView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var folders = PermissionProbe.gatedFolders()
    @State private var fdaState: PermissionProbe.FDAState?
    @State private var askTask: Task<Void, Never>?

    private var isAsking: Bool {
        folders.contains { $0.state == .asking }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            folderCard
            fdaCard
            footer
        }
        .padding(28)
        .frame(width: 520)
        .background(Theme.bgPrimary)
        .animation(motionSafeSpring(reduceMotion), value: folders.map(\.state))
        .task {
            // Silent + side-effect free, so safe to check before any consent.
            fdaState = await Task.detached(priority: .utility) {
                PermissionProbe.fullDiskAccessState()
            }.value
        }
        .onDisappear { askTask?.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Theme.primary)
                Text("Before the first scan")
                    .font(Typo.h3)
                    .foregroundStyle(Theme.textPrimary)
            }
            Text("Cleanitup asks for everything once, up front — never mid-scan, and never again after this.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var folderCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Folder access").typoLabel()
            Text("macOS protects Desktop, Documents and Downloads. Cleanitup only reads folder sizes — nothing is opened, changed, or sent anywhere. You'll see one system dialog per folder.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
            ForEach(folders) { folder in
                HStack(spacing: 10) {
                    Image(systemName: folder.systemImage)
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 20)
                    Text(folder.name)
                        .font(Typo.cardHeading)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    switch folder.state {
                    case .undetermined: EmptyView()
                    case .asking: ProgressView().controlSize(.small)
                    case .granted: PillBadge(text: "Granted", tint: Theme.success)
                    case .denied: PillBadge(text: "No — shows \"—\"", tint: Theme.neutral)
                    }
                }
            }
            Button(isAsking ? "Asking…" : "Ask for folder access", action: askForFolderAccess)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isAsking)
            Text("Anything you decline simply shows \"—\" in the breakdown. You can change it anytime in System Settings.")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(20)
        .glassCard(cornerRadius: Theme.radiusXl)
    }

    private var fdaCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Full Disk Access — optional").typoLabel()
                Spacer()
                switch fdaState {
                case .granted: PillBadge(text: "Granted", tint: Theme.success)
                case .notGranted: PillBadge(text: "Not granted", tint: Theme.neutral)
                case .unknown, nil: PillBadge(text: "—", tint: Theme.neutral)
                }
            }
            Text("Exact numbers for some ~/Library folders (Mail, Messages, Safari) need Full Disk Access. macOS has no dialog for this — it's a toggle in System Settings. Without it those folders honestly read \"≥\" or \"—\". After granting, relaunch Cleanitup.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
            Button("Open System Settings", action: PermissionBadgeButton.openFullDiskAccessSettings)
                .buttonStyle(GlassButtonStyle())
        }
        .padding(20)
        .glassCard(cornerRadius: Theme.radiusXl)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Continue") { dismiss() }
                    .buttonStyle(PrimaryButtonStyle())
                Spacer()
                Button("Skip — scan without asking now") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textTertiary)
                    .help("Skipping starts the scan as-is — macOS may then ask per folder near the end of the first measurement.")
            }
            Text("This is the only time Cleanitup asks. Whatever you decide here, the app won't prompt you again.")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    /// Fire the three TCC dialogs back-to-back. Sequential on purpose: each
    /// probe blocks on its dialog, so awaiting one at a time means the user
    /// never sees stacked prompts, and each row flips the moment it's answered.
    private func askForFolderAccess() {
        askTask = Task { @MainActor in
            for index in folders.indices {
                guard !Task.isCancelled else { return }
                folders[index].state = .asking
                let url = folders[index].url
                let granted = await Task.detached(priority: .userInitiated) {
                    PermissionProbe.probe(url)
                }.value
                folders[index].state = granted ? .granted : .denied
            }
        }
    }
}

#Preview {
    PermissionGateView()
}
