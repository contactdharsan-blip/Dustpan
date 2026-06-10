import SwiftUI
import AppKit

// Phase 1.1 UI — pick an app, preview EVERYTHING that would move to Trash
// (bundle + leftovers, each with provenance and a Safe/Caution label), confirm.
// Running apps can't be uninstalled — quit first (no force-kill in v1.0).

struct UninstallView: View {
    enum Phase: Equatable { case loadingApps, appList, scanningLeftovers, preview }

    @State private var phase: Phase = .loadingApps
    @State private var apps: [InstalledApp] = []
    @State private var running: Set<String> = []
    @State private var search = ""
    @State private var chosen: InstalledApp?
    @State private var items: [ScannedItem] = []
    @State private var selected: Set<ScannedItem.ID> = []
    @State private var trashErrors: [ScannedItem.ID: String] = [:]
    @State private var showConfirm = false
    @State private var toast: String?
    @State private var toastStyle: ToastStyle = .success

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var filteredApps: [InstalledApp] {
        search.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }
    private var selectedItems: [ScannedItem] { items.filter { selected.contains($0.id) } }
    private var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }

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
        .toast(message: $toast, style: toastStyle)
        .task { await loadApps() }
        .confirmationDialog(
            "Uninstall \(chosen?.name ?? "app") — move \(selected.count) item\(selected.count == 1 ? "" : "s") to Trash?",
            isPresented: $showConfirm, titleVisibility: .visible
        ) {
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
        switch phase {
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
            GlassTextField(placeholder: "Search applications", text: $search)
            Text("\(filteredApps.count) of \(apps.count) apps · running apps must be quit before uninstalling")
                .font(.caption).foregroundStyle(Theme.textTertiary)
            VStack(spacing: 10) {
                ForEach(filteredApps) { app in
                    AppRow(app: app,
                           isRunning: app.bundleID.map(running.contains) ?? false,
                           onChoose: { choose(app) })
                }
            }

        case .scanningLeftovers:
            VStack(alignment: .leading, spacing: 12) {
                Text("Finding everything \(chosen?.name ?? "the app") left behind…")
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
                    items = []; selected = []; trashErrors = [:]; chosen = nil
                    setPhase(.appList)
                } label: {
                    Label("All apps", systemImage: "chevron.left")
                }
                .buttonStyle(GlassButtonStyle())
                Spacer()
            }
            summary
            Text("Exact bundle-ID matches are pre-selected. Name-only matches are Caution — verify them before opting in.")
                .font(.caption).foregroundStyle(Theme.textTertiary)
            VStack(spacing: 12) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    ResultCard(
                        item: item, index: index,
                        isSelected: selected.contains(item.id),
                        errorText: trashErrors[item.id],
                        reduceMotion: reduceMotion,
                        onToggle: { toggle(item) },
                        onReveal: { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                    )
                }
            }
        }
    }

    private var summary: some View {
        HStack(alignment: .center, spacing: 28) {
            CountUpMetric(value: ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file), label: "Selected")
            CountUpMetric(value: "\(selected.count)/\(items.count)", label: "Items")
            Spacer()
            Button("Move to Trash") { showConfirm = true }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(selected.isEmpty)
                .opacity(selected.isEmpty ? 0.5 : 1)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: Actions

    private func loadApps() async {
        let found = await Task.detached(priority: .userInitiated) {
            (apps: UninstallEngine.listInstalledApps(), running: UninstallEngine.runningBundleIDs())
        }.value
        apps = found.apps
        running = found.running
        setPhase(.appList)
    }

    private func choose(_ app: InstalledApp) {
        chosen = app
        setPhase(.scanningLeftovers)
        Task { @MainActor in
            let found = await Task.detached(priority: .userInitiated) {
                UninstallEngine.findUninstallItems(for: app)
            }.value
            items = found
            // Pre-select the Safe tier (bundle + exact bundle-ID matches) only.
            selected = Set(found.filter { $0.risk == .safe }.map(\.id))
            trashErrors = [:]
            setPhase(.preview)
        }
    }

    private func toggle(_ item: ScannedItem) {
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }

    private func trashSelected() {
        let chosenItems = selectedItems
        guard !chosenItems.isEmpty else { return }
        let urls = chosenItems.map(\.url)
        let names = chosenItems.map(\.name)
        Task { @MainActor in
            let outcomes = await Task.detached {
                SafeDeleteEngine.moveToTrash(urls, names: names, context: "App Uninstaller")
            }.value
            let succeeded = zip(chosenItems, outcomes).filter { $0.1.success }
            let trashedIDs = Set(succeeded.map { $0.0.id })
            let reclaimed = outcomes.filter(\.success).reduce(0) { $0 + $1.reclaimedBytes }
            for (item, outcome) in zip(chosenItems, outcomes) where !outcome.success {
                trashErrors[item.id] = outcome.error ?? "Could not move to Trash"
            }
            if reduceMotion { items.removeAll { trashedIDs.contains($0.id) } }
            else { withAnimation(Theme.spring) { items.removeAll { trashedIDs.contains($0.id) } } }
            selected.subtract(trashedIDs)

            let sizeStr = ByteCountFormatter.string(fromByteCount: reclaimed, countStyle: .file)
            let refused = outcomes.count - succeeded.count
            toastStyle = refused > 0 ? .warning : .success
            toast = "Moved \(succeeded.count) to Trash · \(sizeStr) reclaimed"
                + (refused > 0 ? " · \(refused) refused" : "")
            if items.isEmpty || trashedIDs.contains(where: { id in chosenItems.first(where: { $0.id == id })?.url == chosen?.url }) {
                // The bundle itself is gone — back to a fresh app list.
                items = []; selected = []; chosen = nil
                setPhase(.loadingApps)
                await loadApps()
            }
        }
    }

    private func setPhase(_ newPhase: Phase) {
        if reduceMotion { phase = newPhase }
        else { withAnimation(Theme.spring) { phase = newPhase } }
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
                .help(isRunning ? "Quit \(app.name) first — Cleanitup never force-quits." : "Preview everything before anything moves to Trash")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: Theme.radiusXl)
    }
}
