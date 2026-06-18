import SwiftUI
import AppKit
import Observation

// Phase 1.1 UI — pick an app, preview EVERYTHING that would move to Trash
// (bundle + leftovers, each with provenance and a Safe/Caution label), confirm.
// Running apps can't be uninstalled — quit first (no force-kill in v1.0).
// App Store / root-installed apps: trashing the bundle is delegated to Finder,
// which shows the macOS admin-authorization popup — explained upfront, in-app.

/// App-scoped uninstaller state (the StatsStore pattern): the app list, the
/// chosen app, its leftover preview and selections survive sidebar switches.
@MainActor @Observable final class UninstallSession {
    enum Phase: Equatable { case loadingApps, appList, scanningLeftovers, preview }

    var phase: Phase = .loadingApps
    var apps: [InstalledApp] = []
    var running: Set<String> = []
    var search = ""
    var chosen: InstalledApp?
    var items: [ScannedItem] = []
    var selected: Set<ScannedItem.ID> = []
    var trashErrors: [ScannedItem.ID: String] = [:]
    // Honesty channel (mirrors SizeReport): a leftover whose root was unreadable
    // (bytes is a fake 0 → render "—") vs one with a denied subtree (bytes is a
    // FLOOR → render "≥ <size>"). Keyed by item URL per the engine contract.
    var deniedItems: Set<URL> = []
    var partialItems: Set<URL> = []
    var toast: String?
    var toastStyle: ToastStyle = .success
    /// Optional trailing action on the current toast (e.g. "Show in History").
    var toastAction: ToastAction?
}

struct UninstallView: View {
    typealias Phase = UninstallSession.Phase

    @Bindable var session: UninstallSession
    @State private var showConfirm = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var filteredApps: [InstalledApp] {
        session.search.isEmpty ? session.apps
            : session.apps.filter { $0.name.localizedCaseInsensitiveContains(session.search) }
    }
    private var selectedItems: [ScannedItem] { session.items.filter { session.selected.contains($0.id) } }
    private var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }
    private var confirmTitle: String {
        let name = session.chosen?.name ?? "app"
        return "Uninstall \(name) — move \(session.selected.count) item\(session.selected.count == 1 ? "" : "s") to Trash?"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                content
                Spacer(minLength: 0)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .toast(message: $session.toast, style: session.toastStyle, action: session.toastAction)
        .task { if session.phase == .loadingApps { await loadApps() } }
        .confirmationDialog(confirmTitle, isPresented: $showConfirm, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { trashSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Items go to the Trash and are recorded in History — you can put any of them back. Nothing is permanently deleted.")
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: CleanupCategory.appUninstaller.systemImage)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Theme.primary)
                .frame(width: 54, height: 54)
                .background(Theme.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).strokeBorder(Theme.primary.opacity(0.25), lineWidth: 1))
                .shadowGlow(Theme.primary, radius: 16, strength: 0.3)
            VStack(alignment: .leading, spacing: 6) {
                Text(CleanupCategory.appUninstaller.rawValue).font(Typo.h3).foregroundStyle(Theme.textPrimary)
                Text(CleanupCategory.appUninstaller.blurb)
                    .font(.callout).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            PillBadge(text: CleanupCategory.appUninstaller.milestone, tint: Theme.success)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    @ViewBuilder private var content: some View {
        switch session.phase {
        case .loadingApps:
            VStack(alignment: .leading, spacing: 12) {
                ForEach(0..<5, id: \.self) { _ in
                    HStack(spacing: 12) {
                        SkeletonView(width: 32, height: 32, cornerRadius: Theme.radiusSm)
                        SkeletonView(width: 200, height: 14)
                        Spacer()
                    }
                }
            }
            .padding(18)
            .glassCard(cornerRadius: Theme.radiusXl)

        case .appList:
            GlassTextField(placeholder: "Search applications", text: $session.search)
            Text("\(filteredApps.count) of \(session.apps.count) apps · running apps must be quit before uninstalling · admin-installed apps ask for macOS authorization")
                .font(.caption).foregroundStyle(Theme.textTertiary)
            if filteredApps.isEmpty {
                emptyAppList
            } else {
                VStack(spacing: 10) {
                    ForEach(filteredApps) { app in
                        AppRow(app: app,
                               isRunning: app.bundleID.map(session.running.contains) ?? false,
                               onChoose: { choose(app) })
                    }
                }
            }

        case .scanningLeftovers:
            VStack(alignment: .leading, spacing: 12) {
                Text("Finding everything \(session.chosen?.name ?? "the app") left behind…")
                    .font(.callout).foregroundStyle(Theme.textSecondary)
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: 12) {
                        SkeletonView(width: 32, height: 32, cornerRadius: Theme.radiusSm)
                        SkeletonView(width: 240, height: 14)
                        Spacer()
                        SkeletonView(width: 64, height: 16)
                    }
                }
            }
            .padding(18)
            .glassCard(cornerRadius: Theme.radiusXl)

        case .preview:
            HStack {
                Button {
                    session.items = []; session.selected = []; session.trashErrors = [:]; session.chosen = nil
                    setPhase(.appList)
                } label: {
                    Label("All apps", systemImage: "chevron.left")
                }
                .buttonStyle(GlassButtonStyle())
                Spacer()
            }
            if let app = session.chosen, app.needsAdminToDelete {
                adminAuthNotice(for: app)
            }
            summary
            Text("Exact bundle-ID matches are pre-selected. Name-only matches are Caution — verify them before opting in.")
                .font(.caption).foregroundStyle(Theme.textTertiary)
            VStack(spacing: 12) {
                ForEach(Array(session.items.enumerated()), id: \.element.id) { index, item in
                    VStack(alignment: .leading, spacing: 6) {
                        ResultCard(
                            item: item, index: index,
                            isSelected: session.selected.contains(item.id),
                            errorText: session.trashErrors[item.id],
                            reduceMotion: reduceMotion,
                            onToggle: { toggle(item) },
                            onReveal: { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                        )
                        // ResultCard shows item.sizeText verbatim; when the engine
                        // flagged the size as unmeasurable (—) or a floor (≥ X),
                        // append the honest qualifier rather than trust a fake 0.
                        if let note = sizeHonestyNote(for: item) {
                            Label(note, systemImage: "lock")
                                .font(.caption).foregroundStyle(Theme.textTertiary)
                                .padding(.leading, 16)
                        }
                    }
                }
            }
        }
    }

    /// The §7.0 `empty` leg for the app list — distinguishes "no search match"
    /// (offer a clear-search affordance) from "no apps found at all".
    @ViewBuilder private var emptyAppList: some View {
        if session.search.isEmpty {
            EmptyStateView(
                title: "No applications found",
                message: "Nothing was found in /Applications or your user Applications folder.",
                systemImage: "app.dashed")
            .frame(maxWidth: .infinity)
        } else {
            EmptyStateView(
                title: "No apps match “\(session.search)”",
                message: "Try a different name, or clear the search to see everything.",
                systemImage: "magnifyingglass",
                actionTitle: "Clear search",
                action: { session.search = "" })
            .frame(maxWidth: .infinity)
        }
    }

    /// Honest upfront framing: the bundle is root-owned, so Finder performs the
    /// move and macOS shows its standard admin-authorization popup — Dustpan
    /// never sees the password; the user authorizes each operation in-app.
    private func adminAuthNotice(for app: InstalledApp) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.primary)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(app.name) needs admin authorization to remove")
                    .font(Typo.cardHeading).foregroundStyle(Theme.textPrimary)
                Text("It was installed \(app.isAppStore ? "from the App Store" : "with admin privileges") and is owned by the system. When you confirm, macOS shows its standard authorization prompt (password or Touch ID) and Finder moves the app to the Trash — Dustpan never sees your password. The first time, macOS also asks to let Dustpan control Finder.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if app.isAppStore { StatusBadge(kind: .info, text: "App Store") }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: Theme.radiusXl)
    }

    private var summary: some View {
        HStack(alignment: .center, spacing: 28) {
            CountUpMetric(value: ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file), label: "Selected")
            CountUpMetric(value: "\(session.selected.count)/\(session.items.count)", label: "Items")
            Spacer()
            Button("Move to Trash") { showConfirm = true }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(session.selected.isEmpty)
                .opacity(session.selected.isEmpty ? 0.5 : 1)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    /// The honest size qualifier for a leftover whose measurement was gated by a
    /// permission error (mirrors SizeReport's —/≥ semantics). `nil` ⇒ the card's
    /// `item.sizeText` is exact and needs no annotation. An item is in at most
    /// one set per the engine contract.
    private func sizeHonestyNote(for item: ScannedItem) -> String? {
        if session.deniedItems.contains(item.url) {
            return "Size — (permission denied — can't measure)"
        }
        if session.partialItems.contains(item.url) {
            return "Size ≥ \(item.sizeText) (part of this is unreadable)"
        }
        return nil
    }

    // MARK: Actions

    private func loadApps() async {
        let found = await Task.detached(priority: .userInitiated) {
            (apps: UninstallEngine.listInstalledApps(), running: UninstallEngine.runningBundleIDs())
        }.value
        session.apps = found.apps
        session.running = found.running
        setPhase(.appList)
    }

    private func choose(_ app: InstalledApp) {
        session.chosen = app
        setPhase(.scanningLeftovers)
        Task { @MainActor [session] in
            let found = await Task.detached(priority: .userInitiated) {
                UninstallEngine.findUninstallItems(for: app)
            }.value
            session.items = found.items
            session.deniedItems = Set(found.deniedItems)
            session.partialItems = Set(found.partialItems)
            // Pre-select the Safe tier (bundle + exact bundle-ID matches) only.
            session.selected = Set(found.items.filter { $0.risk == .safe }.map(\.id))
            session.trashErrors = [:]
            setPhase(.preview)
        }
    }

    private func toggle(_ item: ScannedItem) {
        if session.selected.contains(item.id) { session.selected.remove(item.id) }
        else { session.selected.insert(item.id) }
    }

    private func trashSelected() {
        let chosenItems = selectedItems
        guard !chosenItems.isEmpty else { return }
        let urls = chosenItems.map(\.url)
        let names = chosenItems.map(\.name)
        Task { @MainActor [session] in
            let outcomes = await Task.detached {
                SafeDeleteEngine.moveToTrash(urls, names: names, context: "App Uninstaller")
            }.value
            let succeeded = zip(chosenItems, outcomes).filter { $0.1.success }
            let trashedIDs = Set(succeeded.map { $0.0.id })
            let reclaimed = outcomes.filter(\.success).reduce(0) { $0 + $1.reclaimedBytes }
            for (item, outcome) in zip(chosenItems, outcomes) where !outcome.success {
                session.trashErrors[item.id] = outcome.error ?? "Could not move to Trash"
            }
            if reduceMotion { session.items.removeAll { trashedIDs.contains($0.id) } }
            else { withAnimation(Theme.spring) { session.items.removeAll { trashedIDs.contains($0.id) } } }
            session.selected.subtract(trashedIDs)

            let sizeStr = ByteCountFormatter.string(fromByteCount: reclaimed, countStyle: .file)
            let refused = outcomes.count - succeeded.count
            session.toastStyle = refused > 0 ? .warning : .success
            session.toast = "Moved \(succeeded.count) to Trash · \(sizeStr) reclaimed"
                + (refused > 0 ? " · \(refused) refused" : "")
            // The toast promises "recorded in History" — give it a tap target.
            // Undo puts this exact batch back via the canonical journal restore
            // (Trash-side handles + its state guards), so the affordance is real.
            let trashedPaths = Set(succeeded.map { $0.0.url.path })
            session.toastAction = trashedPaths.isEmpty ? nil
                : ToastAction(title: "Undo") { undoLastTrash(originalPaths: trashedPaths) }
            if session.items.isEmpty || trashedIDs.contains(where: { id in chosenItems.first(where: { $0.id == id })?.url == session.chosen?.url }) {
                // The bundle itself is gone — back to a fresh app list.
                session.items = []; session.selected = []; session.chosen = nil
                setPhase(.loadingApps)
                await loadApps()
            }
        }
    }

    /// Put the just-trashed batch back, routed through the canonical journal
    /// restore (so this can't diverge from the History "Put back" path). Matches
    /// the newest uninstaller entries whose original path is in `originalPaths`,
    /// restores each that is still in the Trash, and reports the real outcome —
    /// never a false "restored" if the item already left the Trash.
    private func undoLastTrash(originalPaths: Set<String>) {
        Task { @MainActor [session] in
            let result = await Task.detached(priority: .userInitiated) { () -> (restored: Int, failed: Int) in
                let (entries, _) = UndoJournal.load() // newest first
                var seen = Set<String>()
                var restored = 0, failed = 0
                for entry in entries where entry.context == "App Uninstaller"
                    && originalPaths.contains(entry.originalPath)
                    && !seen.contains(entry.originalPath) {
                    seen.insert(entry.originalPath) // only the most recent per path
                    switch UndoJournal.restore(entry) {
                    case .success:                restored += 1
                    case .failure(let e):
                        // Already-restored / gone-from-Trash isn't a real failure
                        // to surface; only count genuine restore errors.
                        if case .notRestorable = e { } else { failed += 1 }
                    }
                    if seen.count == originalPaths.count { break }
                }
                return (restored, failed)
            }.value
            session.toastAction = nil
            session.toastStyle = result.failed > 0 ? .warning : .success
            session.toast = result.restored > 0
                ? "Put \(result.restored) back" + (result.failed > 0 ? " · \(result.failed) couldn't be restored" : "")
                : "Nothing to put back — items already left the Trash"
            // The bundle may be back on disk; refresh the app list so it reappears.
            if session.phase != .preview {
                setPhase(.loadingApps)
                await loadApps()
            }
        }
    }

    private func setPhase(_ newPhase: Phase) {
        if reduceMotion { session.phase = newPhase }
        else { withAnimation(Theme.spring) { session.phase = newPhase } }
    }
}

// MARK: - App row

private struct AppRow: View {
    let app: InstalledApp
    let isRunning: Bool
    let onChoose: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                .resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(Typo.cardHeading).foregroundStyle(Theme.textPrimary)
                Text(app.bundleID ?? "no bundle identifier")
                    .font(Typo.mono).foregroundStyle(Theme.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if app.isAppStore {
                StatusBadge(kind: .info, text: "App Store")
                    .help("Installed from the App Store — macOS asks for admin authorization when it moves to Trash.")
            }
            if isRunning {
                StatusBadge(kind: .caution, text: "Running")
            }
            if let used = app.lastUsed {
                Text("Used \(used.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(Theme.textTertiary)
            }
            Button("Uninstall…", action: onChoose)
                .buttonStyle(GlassButtonStyle())
                .disabled(isRunning)
                .opacity(isRunning ? 0.5 : 1)
                .help(isRunning ? "Quit \(app.name) first — Dustpan never force-quits."
                      : app.needsAdminToDelete ? "macOS will ask for admin authorization before the app moves to Trash."
                      : "Preview everything before anything moves to Trash")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: Theme.radiusXl)
    }
}
