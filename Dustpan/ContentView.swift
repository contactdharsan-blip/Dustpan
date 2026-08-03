import SwiftUI
import AppKit
import QuickLook
import Observation

/// The cleaning surfaces. As of Phase 1 ALL categories run real engines:
/// uninstall + orphans (UninstallEngine), large files (LargeFileEngine),
/// developer caches (SafeDeleteEngine). Every trash action lands in the
/// undo journal (History).
enum CleanupCategory: String, CaseIterable, Identifiable {
    case appUninstaller = "App Uninstaller"
    case orphanScan = "Orphaned Files"
    case largeFiles = "Large Files"
    case clutter = "Installers & Screenshots"
    case duplicates = "Duplicate Files"
    case developerCaches = "Developer Caches"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .appUninstaller: return "trash"
        case .orphanScan: return "doc.badge.gearshape"
        case .largeFiles: return "externaldrive.badge.minus"
        case .clutter: return "camera.on.rectangle"
        case .duplicates: return "doc.on.doc"
        case .developerCaches: return "hammer"
        }
    }

    var milestone: String {
        switch self {
        case .appUninstaller, .orphanScan, .largeFiles, .clutter: return "v1.0 · live"
        case .developerCaches: return "v1.1 · live"
        case .duplicates: return "v1.2 · live"
        }
    }

    /// True when the category offers genuinely different Quick/Deep behavior.
    /// Orphan and clutter scans have exactly one honest mode, so they show no
    /// switcher — two modes that secretly do the same thing would be a placebo
    /// control.
    var supportsModes: Bool { self != .orphanScan && self != .clutter }

    var quickCaption: String {
        switch self {
        case .developerCaches: return "Checks known reclaimable locations only — fast."
        case .duplicates: return "Byte-identical files ≥ 10 MB in Downloads, Desktop, Documents, Movies, and Music — confirmed by full content hash, not name or size. The newest copy is suggested to keep; nothing is pre-selected."
        case .largeFiles: return "Files ≥ 100 MB in Downloads, Desktop, Documents, Movies, and Music."
        case .orphanScan: return "Scans ~/Library for files whose owning app is no longer installed. Everything found is Caution — verify before trashing."
        case .clutter: return "Installer images in Downloads, plus screenshots and screen recordings on Desktop and in Downloads. Oldest first — age is the signal. Everything is Caution: your files, your call."
        case .appUninstaller: return ""
        }
    }

    var deepCaption: String {
        switch self {
        case .developerCaches: return "Everything in Quick, plus a read-only search of your folders for large caches, simulator devices, old archives, and node_modules. Slower."
        case .duplicates: return "Byte-identical files ≥ 10 MB across your whole home folder (except ~/Library — other categories own it). Hashing every same-size pair is disk-heavy. Slower."
        case .largeFiles: return "Files ≥ 100 MB across your whole home folder (except ~/Library — other categories own it). Photos/Music libraries and app bundles are skipped: macOS manages those. Slower."
        case .orphanScan, .clutter, .appUninstaller: return ""
        }
    }

    var blurb: String {
        switch self {
        case .appUninstaller: return "Remove an app and every leftover file it left in ~/Library."
        case .orphanScan: return "Find files left behind by apps you already deleted."
        case .largeFiles: return "Surface your biggest files — you decide what moves to Trash."
        case .clutter: return "Old installers and screenshots, oldest first — the stale stuff is obvious."
        case .duplicates: return "Find byte-identical copies of your files — keep one, trash the rest."
        case .developerCaches: return "Reclaim Xcode, simulator, and package-manager caches over known-safe paths."
        }
    }
}

extension CleanRisk {
    var status: StatusKind { self == .safe ? .safe : .caution }
}

/// What the sidebar can point at: the live storage Overview (default), or one of
/// the cleaning categories. Kept as a tiny enum so the detail pane can switch on
/// it directly while still letting `List(selection:)` drive the selection.
enum SidebarItem: Hashable, Identifiable {
    case overview
    case systemData
    case diskMap
    case category(CleanupCategory)
    case loginItems
    case protectedFolders
    case history

    var id: String {
        switch self {
        case .overview: return "overview"
        case .systemData: return "system-data"
        case .diskMap: return "disk-map"
        case .category(let c): return c.id
        case .loginItems: return "login-items"
        case .protectedFolders: return "protected-folders"
        case .history: return "history"
        }
    }
}

// MARK: - Root

struct ContentView: View {
    @State private var selection: SidebarItem? = .overview
    /// App-scoped so sidebar round-trips don't restart the dashboard measurement.
    // Owned by DustpanApp and shared with the menu-bar scene. An @Observable
    // passed as a plain `let` still drives view updates via Observation.
    let store: StatsStore
    /// App-scoped scan state (same pattern as StatsStore): results and in-flight
    /// scans survive sidebar switches — the view dies, the session doesn't.
    @State private var scanSessions: [CleanupCategory: ScanSession] = Dictionary(
        uniqueKeysWithValues: CleanupCategory.allCases.map { ($0, ScanSession()) })
    @State private var uninstallSession = UninstallSession()
    /// App-scoped so the protected-folder list survives sidebar round-trips.
    @State private var protectedStore = ProtectedFoldersStore()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(PrefKey.permissionFlowCompleted) private var permissionFlowCompleted = false
    @State private var showPermissionGate = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Overview", systemImage: "chart.pie")
                    .badge("live")
                    .tag(SidebarItem.overview)
                Label("System Data", systemImage: "questionmark.folder")
                    .badge("explained")
                    .tag(SidebarItem.systemData)
                Label("Disk Map", systemImage: "rectangle.split.3x3")
                    .badge("treemap")
                    .tag(SidebarItem.diskMap)
                ForEach(CleanupCategory.allCases) { category in
                    Label(category.rawValue, systemImage: category.systemImage)
                        .badge(category.milestone)
                        .tag(SidebarItem.category(category))
                }
                Label("Login Items", systemImage: "power")
                    .badge("report-only")
                    .tag(SidebarItem.loginItems)
                Label("Protected Folders", systemImage: "lock.shield")
                    .badge("excluded")
                    .tag(SidebarItem.protectedFolders)
                Label("History", systemImage: "clock.arrow.circlepath")
                    .badge("audit")
                    .tag(SidebarItem.history)
            }
            .navigationTitle("Dustpan")
            .scrollContentBackground(.hidden)
            .background(Theme.bgSecondary.opacity(0.5))
            .frame(minWidth: 230)
        } detail: {
            ZStack {
                AmbientBackground()
                switch selection {
                case .overview:
                    DashboardView(store: store, navigate: { selection = $0 })
                        .id(SidebarItem.overview)
                case .systemData:
                    // Shares the app-scoped measurement — never a second scan.
                    SystemDataView(store: store).id(SidebarItem.systemData)
                case .diskMap:
                    TreemapView(store: store, navigate: { selection = $0 })
                        .id(SidebarItem.diskMap)
                case .category(.appUninstaller):
                    // Pick-an-app flow — a different shape from scan-everything.
                    UninstallView(session: uninstallSession).id(SidebarItem.category(.appUninstaller))
                case .category(let category):
                    // Force-unwrap is total by construction: the dictionary is
                    // initialized over CleanupCategory.allCases.
                    ScanView(category: category, session: scanSessions[category]!, navigate: { selection = $0 }).id(category)
                case .loginItems:
                    LoginItemsView().id(SidebarItem.loginItems)
                case .protectedFolders:
                    ProtectedFoldersView(store: protectedStore).id(SidebarItem.protectedFolders)
                case .history:
                    HistoryView().id(SidebarItem.history)
                case nil:
                    ContentUnavailableView("Select a category", systemImage: "sidebar.left")
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .animation(motionSafeSpring(reduceMotion), value: selection)
        }
        // The one-time permission moment: modal over the whole split view, so
        // no scan entry point (Overview, System Data, Large Files…) can fire a
        // TCC dialog behind it. Dismissal — by Continue OR Skip — is the single
        // write path for the flag and starts the gated first scan.
        .onAppear { if !permissionFlowCompleted { showPermissionGate = true } }
        .sheet(isPresented: $showPermissionGate, onDismiss: {
            permissionFlowCompleted = true
            if store.snapshot == nil { store.refresh() }
        }) {
            PermissionGateView()
                .interactiveDismissDisabled()
        }
    }
}

// MARK: - Scan flow

/// Per-category scan state, hoisted out of the view (the StatsStore pattern) so
/// results — and scans still in flight — survive sidebar switches. The running
/// scan Task writes into the session it captured, not into dead view @State.
@MainActor @Observable final class ScanSession {
    enum Mode: String, CaseIterable { case quick = "Quick", deep = "Deep" }
    enum Phase: Equatable { case idle, scanning, results, empty }

    var mode: Mode = .quick
    var phase: Phase = .idle
    var items: [ScannedItem] = []
    var selected: Set<ScannedItem.ID> = []
    /// Scan roots macOS refused outright (permission-denied) on the last scan.
    /// Non-empty means we cannot honestly claim "nothing to clean" — some of the
    /// disk was never seen. Cleared on every new scan.
    var deniedRoots: [URL] = []
    var filter = ""
    /// Refusal reasons per item (SafeDeleteEngine promises these are surfaced,
    /// never silently swallowed). Cleared on every new scan.
    var trashErrors: [ScannedItem.ID: String] = [:]
    var toast: String?
    var toastStyle: ToastStyle = .success
    /// Optional trailing toast button (e.g. post-trash "Show in History"). Set
    /// alongside `toast`; cleared on the next toast that has no action.
    var toastAction: ToastAction?
    var scanTask: Task<Void, Never>?
}

struct ScanView: View {
    typealias Mode = ScanSession.Mode
    typealias Phase = ScanSession.Phase

    let category: CleanupCategory
    @Bindable var session: ScanSession
    /// Lets the post-trash toast jump to History (the undo surface) without
    /// owning navigation itself.
    var navigate: (SidebarItem) -> Void = { _ in }

    /// Transient chrome only — everything that should outlive the view lives in the session.
    @State private var showConfirm = false
    /// Quick Look target — "see it before you trash it".
    @State private var quickLookURL: URL?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var filtered: [ScannedItem] {
        session.filter.isEmpty ? session.items
            : session.items.filter { $0.name.localizedCaseInsensitiveContains(session.filter) }
    }
    private var selectedItems: [ScannedItem] { session.items.filter { session.selected.contains($0.id) } }
    private var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }

    /// Duplicate-only confirm-dialog guard (finding 6): names every group whose
    /// every byte-identical copy — suggested-keep included — is in the current
    /// selection, so confirming would leave no copy of that file on disk. Empty
    /// for non-duplicate categories and whenever at least one copy survives.
    private var lastCopyWarning: String {
        guard category == .duplicates, !selectedItems.isEmpty else { return "" }
        let selectedIDs = session.selected
        let wipedGroups = Dictionary(grouping: session.items) { $0.ownerApp ?? "ungrouped" }
            .filter { _, group in group.count > 1 && group.allSatisfy { selectedIDs.contains($0.id) } }
            .compactMap { _, group in group.first(where: \.suggestedKeep)?.name ?? group.first?.name }
            .sorted()
        guard !wipedGroups.isEmpty else { return "" }
        let names = wipedGroups.prefix(3).joined(separator: ", ")
            + (wipedGroups.count > 3 ? ", and \(wipedGroups.count - 3) more" : "")
        return "\n\n⚠️ This includes the suggested keep — confirming leaves NO copy of: \(names)."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                controls
                content
                Spacer(minLength: 0)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .toast(message: $session.toast, style: session.toastStyle, action: session.toastAction)
        .quickLookPreview($quickLookURL)
        .confirmationDialog(
            "Move \(session.selected.count) item\(session.selected.count == 1 ? "" : "s") to Trash?",
            isPresented: $showConfirm, titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { trashSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Selection isn't pruned on filter change — disclose anything the
            // active filter is hiding so the count never surprises.
            let hiddenCount = selectedItems
                .filter { item in !filtered.contains(where: { $0.id == item.id }) }
                .count
            // Name what's about to move — capped so the dialog stays readable.
            let preview = selectedItems.prefix(6)
                .map { "\($0.name)  (\(ByteCountFormatter.string(fromByteCount: $0.bytes, countStyle: .file)))" }
                .joined(separator: "\n")
            let overflow = selectedItems.count - 6
            Text(preview
                 + (overflow > 0 ? "\n…and \(overflow) more" : "")
                 + "\n\nItems go to the Trash and are recorded in History — you can put them back. Nothing is permanently deleted."
                 + (hiddenCount > 0
                    ? " Includes \(hiddenCount) selected item\(hiddenCount == 1 ? "" : "s") not shown by the current filter."
                    : "")
                 // Duplicate-only: warn before the last copy of a group leaves
                 // the disk. The suggested-keep is individually selectable, so a
                 // "select all + keep" sequence can quietly trash every copy.
                 + lastCopyWarning)
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: category.systemImage)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Theme.primary)
                .frame(width: 54, height: 54)
                .background(Theme.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).strokeBorder(Theme.primary.opacity(0.25), lineWidth: 1))
                .shadowGlow(Theme.primary, radius: 16, strength: 0.3)

            VStack(alignment: .leading, spacing: 6) {
                Text(category.rawValue).font(Typo.h3).foregroundStyle(Theme.textPrimary)
                Text(category.blurb)
                    .font(.callout).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            PillBadge(text: category.milestone, tint: Theme.success)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                if category.supportsModes {
                    ModeSwitcher(options: Mode.allCases, title: { $0.rawValue }, selection: $session.mode)
                        .frame(maxWidth: 220)
                        // Locked mid-scan so results/copy always describe the mode that ran.
                        .disabled(session.phase == .scanning)
                        .opacity(session.phase == .scanning ? 0.5 : 1)
                }
                Spacer()
                if session.phase == .scanning {
                    Button("Cancel") { session.scanTask?.cancel(); setPhase(.idle) }
                        .buttonStyle(GlassButtonStyle())
                }
                if session.phase == .results || session.phase == .empty {
                    Button("Rescan") { startScan() }.buttonStyle(GlassButtonStyle())
                }
                Button(session.phase == .scanning ? "Scanning…" : "Scan") { startScan() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(session.phase == .scanning)
            }
            // Honest mode description — modes REALLY differ at the engine level
            // (a category with one honest mode shows no switcher at all).
            let caption = category.supportsModes
                ? (session.mode == .deep ? category.deepCaption : category.quickCaption)
                : category.quickCaption
            if !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch session.phase {
        case .idle:
            EmptyStateView(
                title: "Ready when you are",
                message: "Run a scan — it's read-only. Nothing is deleted without your review and confirmation, and everything trashed lands in History.",
                systemImage: "sparkle.magnifyingglass"
            )
            .frame(maxWidth: .infinity)

        case .scanning:
            VStack(alignment: .leading, spacing: 12) {
                ForEach(0..<4, id: \.self) { _ in
                    HStack(spacing: 12) {
                        SkeletonView(width: 32, height: 32, cornerRadius: Theme.radiusSm)
                        VStack(alignment: .leading, spacing: 8) {
                            SkeletonView(width: 180, height: 14)
                            SkeletonView(width: 120, height: 10)
                        }
                        Spacer()
                        SkeletonView(width: 64, height: 16)
                    }
                }
            }
            .padding(18)
            .glassCard(cornerRadius: Theme.radiusXl)

        case .results:
            summary
            // Honest disclosure when the scan found things AND hit a wall: the
            // list below is a floor, not the whole picture (findings 5 + 23).
            if !session.deniedRoots.isEmpty { deniedBanner }
            Text(category == .orphanScan
                 ? "Grouped by the app the files belonged to — the header selects a whole group. Everything is Caution: verify before trashing."
                 : category == .duplicates
                 ? "Grouped by identical content — the header selects every copy except the suggested keep. Nothing is pre-selected: your files, your call."
                 : "Safe items are pre-selected — Caution items are left for you to opt into.")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
            GlassTextField(placeholder: "Filter results", text: $session.filter)
            if category == .orphanScan {
                orphanGroupList
            } else if category == .duplicates {
                duplicateGroupList
            } else {
                VStack(spacing: 12) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                        resultCard(item: item, index: index)
                    }
                }
            }

        case .empty:
            // Distinct DENIED leg (findings 5 + 23): if a scan root was refused
            // we found nothing *that we could see* — never claim "nothing to
            // clean" over a permission wall. Em-dash honesty, plus a path back in.
            if session.deniedRoots.isEmpty {
                EmptyStateView(
                    title: "Nothing to clean",
                    message: "A \(category.supportsModes ? session.mode.rawValue.lowercased() + " " : "")scan found nothing reclaimable here.",
                    systemImage: "checkmark.seal",
                    actionTitle: category.supportsModes && session.mode == .quick ? "Deep scan" : nil,
                    action: category.supportsModes && session.mode == .quick ? { session.mode = .deep; startScan() } : nil
                )
                .frame(maxWidth: .infinity)
            } else {
                deniedEmptyState
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// The folders macOS refused, shown verbatim so the denial is auditable.
    private var deniedRootLines: String {
        session.deniedRoots
            .map { $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
            .joined(separator: "\n")
    }

    /// Inline banner over a results list when *some* roots were denied: the list
    /// is honest but partial. Calm, not alarmist — and offers the way back in.
    private var deniedBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.warning)
                Text("Partial results — \(session.deniedRoots.count) folder\(session.deniedRoots.count == 1 ? " was" : "s were") unreadable")
                    .font(Typo.cardHeading).foregroundStyle(Theme.textPrimary)
                Spacer()
                PermissionBadgeButton()
            }
            Text("These show as “—”, not 0 — Dustpan never saw inside them:\n\(deniedRootLines)\n\nGrant Full Disk Access, then rescan to include them.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: Theme.radiusXl)
    }

    /// Full-pane denied state shown in place of "Nothing to clean" when the scan
    /// found nothing AND a root was refused: we genuinely don't know if it's clean.
    private var deniedEmptyState: some View {
        VStack(spacing: 16) {
            EmptyStateView(
                title: "Couldn’t see everything",
                message: "Nothing reclaimable was found in the folders Dustpan could read — but \(session.deniedRoots.count) folder\(session.deniedRoots.count == 1 ? " was" : "s were") refused by macOS, so this isn’t a clean bill. Those folders read “—”, never 0:\n\n\(deniedRootLines)",
                systemImage: "lock.shield"
            )
            HStack(spacing: 12) {
                Button("Open Full Disk Access") { PermissionBadgeButton.openFullDiskAccessSettings() }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Rescan") { startScan() }
                    .buttonStyle(GlassButtonStyle())
            }
            Text("Grant access in System Settings, then rescan.")
                .font(.caption).foregroundStyle(Theme.textTertiary)
        }
    }

    private func resultCard(item: ScannedItem, index: Int) -> some View {
        ResultCard(
            item: item, index: index,
            isSelected: session.selected.contains(item.id),
            errorText: session.trashErrors[item.id],
            reduceMotion: reduceMotion,
            onToggle: { toggle(item) },
            onReveal: { NSWorkspace.shared.activateFileViewerSelecting([item.url]) },
            // Quick Look where it answers "what IS this file" — large files,
            // clutter, and duplicates (eyeball a copy before trashing it).
            onPreview: (category == .largeFiles || category == .clutter || category == .duplicates) ? { quickLookURL = item.url } : nil
        )
    }

    /// Orphans linked back to the app they belonged to: grouped by vendor prefix
    /// (the exact level the orphan inference runs at — no name-guessing), biggest
    /// group first. Items inside keep the engine's size ordering.
    private var orphanGroups: [(owner: String, items: [ScannedItem])] {
        Dictionary(grouping: filtered) { $0.ownerApp ?? "unknown" }
            .map { (owner: $0.key, items: $0.value) }
            .sorted { lhs, rhs in
                lhs.items.reduce(0) { $0 + $1.bytes } > rhs.items.reduce(0) { $0 + $1.bytes }
            }
    }

    private var orphanGroupList: some View {
        VStack(spacing: 12) {
            ForEach(orphanGroups, id: \.owner) { group in
                OrphanGroupHeader(
                    owner: group.owner,
                    items: group.items,
                    selectedCount: group.items.filter { session.selected.contains($0.id) }.count,
                    onToggleAll: { toggleGroup(group.items) })
                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                    resultCard(item: item, index: index)
                }
            }
        }
    }

    private func toggleGroup(_ groupItems: [ScannedItem]) {
        let ids = Set(groupItems.map(\.id))
        if ids.isSubset(of: session.selected) { session.selected.subtract(ids) }
        else { session.selected.formUnion(ids) }
    }

    /// Duplicates grouped by content hash (the engine puts it in ownerApp),
    /// biggest reclaim first. Engine ordering inside a group is kept: the
    /// suggested-keep copy is always first.
    private var duplicateGroups: [(key: String, items: [ScannedItem])] {
        Dictionary(grouping: filtered) { $0.ownerApp ?? "ungrouped" }
            .map { (key: $0.key, items: $0.value) }
            .sorted { lhs, rhs in
                lhs.items.reduce(0) { $0 + $1.bytes } > rhs.items.reduce(0) { $0 + $1.bytes }
            }
    }

    private var duplicateGroupList: some View {
        VStack(spacing: 12) {
            ForEach(duplicateGroups, id: \.key) { group in
                DuplicateGroupHeader(
                    hashPrefix: group.key,
                    items: group.items,
                    selectedCount: group.items.filter { session.selected.contains($0.id) }.count,
                    onToggleCopies: { toggleDuplicateCopies(group.items) })
                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                    resultCard(item: item, index: index)
                }
            }
        }
    }

    /// The duplicate group gesture deliberately differs from the orphan one:
    /// it never touches the suggested-keep copy, so "select the group" can't
    /// silently mean "delete every copy of this file".
    private func toggleDuplicateCopies(_ groupItems: [ScannedItem]) {
        let copyIDs = Set(groupItems.filter { !$0.suggestedKeep }.map(\.id))
        if copyIDs.isSubset(of: session.selected) { session.selected.subtract(copyIDs) }
        else { session.selected.formUnion(copyIDs) }
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

    // MARK: Actions

    private func toggle(_ item: ScannedItem) {
        if session.selected.contains(item.id) { session.selected.remove(item.id) }
        else { session.selected.insert(item.id) }
    }

    private func startScan() {
        session.scanTask?.cancel()
        session.filter = ""; session.selected = []; session.trashErrors = [:]
        session.deniedRoots = []
        setPhase(.scanning)
        // The Task captures the app-scoped session (a class), so a scan finishing
        // after the user switched tabs still lands its results — nothing is lost
        // to a destroyed view.
        session.scanTask = Task { @MainActor [session] in
            // Real read-only scan off the main thread (sizing can take a moment).
            // Each category dispatches to its own engine; Quick/Deep genuinely
            // change engine behavior — never just a different sleep.
            let scanMode: SafeDeleteEngine.ScanMode = (session.mode == .deep) ? .deep : .quick
            let cat = category
            // Cancellation must be propagated by hand into the detached task
            // (the engines poll Task.isCancelled), so Cancel stops the disk
            // walk itself — not just the UI while I/O burns on in the background.
            // Carries both legs of the engines' honesty contract: the items and
            // the roots macOS refused (so "nothing to clean" can't hide a wall).
            let walk = Task.detached(priority: .userInitiated) { () -> (items: [ScannedItem], denied: [URL]) in
                switch cat {
                case .developerCaches: return (SafeDeleteEngine.scanReclaimable(mode: scanMode), [])
                case .orphanScan: return (UninstallEngine.scanOrphans().items, [])
                case .largeFiles: let r = LargeFileEngine.scan(mode: scanMode); return (r.items, r.deniedRoots)
                case .clutter: let r = ClutterEngine.scan(); return (r.items, r.deniedRoots)
                case .duplicates: let r = DuplicateEngine.scan(mode: scanMode); return (r.items, r.deniedRoots)
                case .appUninstaller: return ([], []) // routed to UninstallView, never here
                }
            }
            let result = await withTaskCancellationHandler {
                await walk.value
            } onCancel: {
                walk.cancel()
            }
            guard !Task.isCancelled else { return }
            let found = result.items
            session.items = found
            session.deniedRoots = result.denied
            // Pre-select the .safe items; leave .caution for the user to opt into.
            session.selected = Set(found.filter { $0.risk == .safe }.map(\.id))
            setPhase(found.isEmpty ? .empty : .results)
            if !found.isEmpty {
                let size = ByteCountFormatter.string(fromByteCount: found.reduce(0) { $0 + $1.bytes }, countStyle: .file)
                session.toastStyle = .success
                session.toastAction = nil
                session.toast = "Found \(size) across \(found.count) item\(found.count == 1 ? "" : "s") — read-only until you confirm"
            }
        }
    }

    private func trashSelected() {
        let chosen = selectedItems
        guard !chosen.isEmpty else { return }
        let urls = chosen.map(\.url)
        let names = chosen.map(\.name)
        let context = category.rawValue
        Task { @MainActor in
            let outcomes = await Task.detached {
                SafeDeleteEngine.moveToTrash(urls, names: names, context: context)
            }.value
            let succeeded = zip(chosen, outcomes).filter { $0.1.success }
            let trashedIDs = Set(succeeded.map { $0.0.id })
            let reclaimed = outcomes.filter(\.success).reduce(0) { $0 + $1.reclaimedBytes }

            // Surface every refusal on its (still-listed) row — the engine's
            // doc contract: refusal reasons are never silently swallowed.
            for (item, outcome) in zip(chosen, outcomes) where !outcome.success {
                session.trashErrors[item.id] = outcome.error ?? "Could not move to Trash"
            }

            if reduceMotion { session.items.removeAll { trashedIDs.contains($0.id) } }
            else { withAnimation(Theme.spring) { session.items.removeAll { trashedIDs.contains($0.id) } } }
            session.selected.subtract(trashedIDs)

            let sizeStr = ByteCountFormatter.string(fromByteCount: reclaimed, countStyle: .file)
            let refused = outcomes.count - succeeded.count
            session.toastStyle = refused > 0 ? .warning : .success
            // Name the path to undo (finding 10): every trash lands in History,
            // where each entry can be put back — so the toast jumps straight there.
            session.toastAction = succeeded.isEmpty ? nil
                : ToastAction(title: "Show in History") { navigate(.history) }
            session.toast = "Moved \(succeeded.count) to Trash · \(sizeStr) reclaimed" + (refused > 0 ? " · \(refused) refused" : "")
            if session.items.isEmpty { setPhase(.empty) }
        }
    }

    private func setPhase(_ newPhase: Phase) {
        if reduceMotion { session.phase = newPhase }
        else { withAnimation(Theme.spring) { session.phase = newPhase } }
    }
}

// MARK: - Orphan group header

/// One inferred former app in the orphan list — title from the vendor prefix,
/// raw prefix shown alongside so the inference stays auditable. The checkbox
/// selects/deselects every leftover in the group.
private struct OrphanGroupHeader: View {
    let owner: String          // vendor prefix, e.g. "com.spotify"
    let items: [ScannedItem]
    let selectedCount: Int
    let onToggleAll: () -> Void

    private var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    private var title: String { UninstallEngine.vendorDisplayName(owner) }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggleAll) {
                Image(systemName: selectedCount == items.count ? "checkmark.circle.fill"
                                  : selectedCount > 0 ? "minus.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(selectedCount > 0 ? Theme.primary : Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(selectedCount == items.count ? "Deselect" : "Select") all \(title) leftovers")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typo.cardHeading).foregroundStyle(Theme.textPrimary)
                Text("\(owner).* — app no longer installed")
                    .font(Typo.mono).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Text("\(items.count) file\(items.count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                .font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 6)
        .padding(.top, 10)
    }
}

/// Header for one byte-identical duplicate group. The toggle selects only the
/// non-keep copies — see toggleDuplicateCopies for why.
private struct DuplicateGroupHeader: View {
    let hashPrefix: String     // content-hash prefix — the auditable group key
    let items: [ScannedItem]
    let selectedCount: Int
    let onToggleCopies: () -> Void

    private var copies: [ScannedItem] { items.filter { !$0.suggestedKeep } }
    private var copyBytes: Int64 { copies.reduce(0) { $0 + $1.bytes } }
    private var title: String { items.first(where: \.suggestedKeep)?.name ?? items.first?.name ?? "Duplicates" }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggleCopies) {
                Image(systemName: selectedCount >= copies.count && !copies.isEmpty ? "checkmark.circle.fill"
                                  : selectedCount > 0 ? "minus.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(selectedCount > 0 ? Theme.primary : Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(selectedCount >= copies.count && !copies.isEmpty ? "Deselect" : "Select") all extra copies of \(title)")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typo.cardHeading).foregroundStyle(Theme.textPrimary)
                Text("sha256 \(hashPrefix)… — \(items.count) byte-identical copies")
                    .font(Typo.mono).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Text("\(copies.count) extra cop\(copies.count == 1 ? "y" : "ies") · \(ByteCountFormatter.string(fromByteCount: copyBytes, countStyle: .file))")
                .font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 6)
        .padding(.top, 10)
    }
}

// MARK: - Result row (§5.2 staggerItem)

struct ResultCard: View {
    let item: ScannedItem
    let index: Int
    let isSelected: Bool
    var errorText: String? = nil
    let reduceMotion: Bool
    let onToggle: () -> Void
    /// Reveal in Finder — every live row gets one ("verify, don't trust").
    var onReveal: (() -> Void)? = nil
    /// Quick Look — see the actual file before deciding (large files).
    var onPreview: (() -> Void)? = nil

    @State private var shown = false

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Theme.primary : Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(isSelected ? "Deselect" : "Select") \(item.name)")
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(Typo.cardHeading).foregroundStyle(Theme.textPrimary)
                Text(item.displayPath).font(Typo.mono).foregroundStyle(Theme.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
                Text(item.detail).font(.caption).foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if let onPreview {
                Button(action: onPreview) {
                    Image(systemName: "eye")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
                .help("Quick Look")
                .accessibilityLabel("Quick Look \(item.name)")
            }
            if let onReveal {
                Button(action: onReveal) {
                    Image(systemName: "magnifyingglass.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal \(item.name) in Finder")
            }
            if errorText != nil {
                StatusBadge(kind: .caution, text: "Refused")
            } else if item.suggestedKeep {
                // Duplicate-only (finding 7): the copy Dustpan suggests keeping
                // wears its own badge, never the generic Caution every other copy
                // carries — so "keep this one" reads at a glance.
                StatusBadge(kind: .safe, text: "Suggested keep")
            } else {
                StatusBadge(kind: item.risk.status)
            }
            Text(item.sizeText)
                .font(.subheadline.weight(.semibold)).monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
                .frame(minWidth: 70, alignment: .trailing)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: Theme.radiusXl)
        // Whole-row hit target; the inner Button consumes its own tap so this
        // doesn't double-toggle.
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 12)
        .onAppear {
            if reduceMotion { shown = true }
            else { withAnimation(Theme.spring.delay(Double(index) * 0.06)) { shown = true } }
        }
    }
}

#Preview {
    ContentView(store: StatsStore())
        .frame(width: 880, height: 620)
        .preferredColorScheme(.dark)
}
