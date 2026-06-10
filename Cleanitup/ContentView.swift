import SwiftUI
import AppKit
import QuickLook

/// The cleaning surfaces. As of Phase 1 ALL categories run real engines:
/// uninstall + orphans (UninstallEngine), large files (LargeFileEngine),
/// developer caches (SafeDeleteEngine). Every trash action lands in the
/// undo journal (History).
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
        case .appUninstaller, .orphanScan, .largeFiles: return "v1.0 · live"
        case .developerCaches: return "v1.1 · live"
        }
    }

    /// True when the category offers genuinely different Quick/Deep behavior.
    /// Orphan scanning has exactly one honest mode, so it shows no switcher —
    /// two modes that secretly do the same thing would be a placebo control.
    var supportsModes: Bool { self != .orphanScan }

    var quickCaption: String {
        switch self {
        case .developerCaches: return "Checks known reclaimable locations only — fast."
        case .largeFiles: return "Files ≥ 100 MB in Downloads, Desktop, Documents, Movies, and Music."
        case .orphanScan: return "Scans ~/Library for files whose owning app is no longer installed. Everything found is Caution — verify before trashing."
        case .appUninstaller: return ""
        }
    }

    var deepCaption: String {
        switch self {
        case .developerCaches: return "Everything in Quick, plus a read-only search of your folders for large caches, simulator devices, old archives, and node_modules. Slower."
        case .largeFiles: return "Files ≥ 100 MB across your whole home folder (except ~/Library — other categories own it). Photos/Music libraries and app bundles are skipped: macOS manages those. Slower."
        case .orphanScan, .appUninstaller: return ""
        }
    }

    var blurb: String {
        switch self {
        case .appUninstaller: return "Remove an app and every leftover file it left in ~/Library."
        case .orphanScan: return "Find files left behind by apps you already deleted."
        case .largeFiles: return "Surface your biggest files — you decide what moves to Trash."
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
    case category(CleanupCategory)
    case history

    var id: String {
        switch self {
        case .overview: return "overview"
        case .systemData: return "system-data"
        case .category(let c): return c.id
        case .history: return "history"
        }
    }
}

// MARK: - Root

struct ContentView: View {
    @State private var selection: SidebarItem? = .overview
    /// App-scoped so sidebar round-trips don't restart the dashboard measurement.
    @State private var store = StatsStore()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Overview", systemImage: "chart.pie")
                    .badge("live")
                    .tag(SidebarItem.overview)
                Label("System Data", systemImage: "questionmark.folder")
                    .badge("explained")
                    .tag(SidebarItem.systemData)
                ForEach(CleanupCategory.allCases) { category in
                    Label(category.rawValue, systemImage: category.systemImage)
                        .badge(category.milestone)
                        .tag(SidebarItem.category(category))
                }
                Label("History", systemImage: "clock.arrow.circlepath")
                    .badge("audit")
                    .tag(SidebarItem.history)
            }
            .navigationTitle("Cleanitup")
            .scrollContentBackground(.hidden)
            .background(Theme.bgSecondary.opacity(0.5))
            .frame(minWidth: 230)
        } detail: {
            ZStack {
                AmbientBackground()
                switch selection {
                case .overview:
                    DashboardView(store: store).id(SidebarItem.overview)
                case .systemData:
                    // Shares the app-scoped measurement — never a second scan.
                    SystemDataView(store: store).id(SidebarItem.systemData)
                case .category(.appUninstaller):
                    // Pick-an-app flow — a different shape from scan-everything.
                    UninstallView().id(SidebarItem.category(.appUninstaller))
                case .category(let category):
                    ScanView(category: category).id(category)
                case .history:
                    HistoryView().id(SidebarItem.history)
                case nil:
                    ContentUnavailableView("Select a category", systemImage: "sidebar.left")
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .animation(motionSafeSpring(reduceMotion), value: selection)
        }
    }
}

// MARK: - Scan flow

struct ScanView: View {
    let category: CleanupCategory

    enum Mode: String, CaseIterable { case quick = "Quick", deep = "Deep" }
    enum Phase: Equatable { case idle, scanning, results, empty }

    @State private var mode: Mode = .quick
    @State private var phase: Phase = .idle
    @State private var items: [ScannedItem] = []
    @State private var selected: Set<ScannedItem.ID> = []
    @State private var filter = ""
    @State private var toast: String?
    @State private var toastStyle: ToastStyle = .success
    @State private var showConfirm = false
    @State private var scanTask: Task<Void, Never>?
    /// Refusal reasons per item (SafeDeleteEngine promises these are surfaced,
    /// never silently swallowed). Cleared on every new scan.
    @State private var trashErrors: [ScannedItem.ID: String] = [:]
    /// Quick Look target — "see it before you trash it".
    @State private var quickLookURL: URL?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var filtered: [ScannedItem] {
        filter.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }
    private var selectedItems: [ScannedItem] { items.filter { selected.contains($0.id) } }
    private var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }

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
        .toast(message: $toast, style: toastStyle)
        .quickLookPreview($quickLookURL)
        .confirmationDialog(
            "Move \(selected.count) item\(selected.count == 1 ? "" : "s") to Trash?",
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
            Text("Items go to the Trash and are recorded in History — you can put them back. Nothing is permanently deleted."
                 + (hiddenCount > 0
                    ? " Includes \(hiddenCount) selected item\(hiddenCount == 1 ? "" : "s") not shown by the current filter."
                    : ""))
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
                    ModeSwitcher(options: Mode.allCases, title: { $0.rawValue }, selection: $mode)
                        .frame(maxWidth: 220)
                        // Locked mid-scan so results/copy always describe the mode that ran.
                        .disabled(phase == .scanning)
                        .opacity(phase == .scanning ? 0.5 : 1)
                }
                Spacer()
                if phase == .scanning {
                    Button("Cancel") { scanTask?.cancel(); setPhase(.idle) }
                        .buttonStyle(GlassButtonStyle())
                }
                if phase == .results || phase == .empty {
                    Button("Rescan") { startScan() }.buttonStyle(GlassButtonStyle())
                }
                Button(phase == .scanning ? "Scanning…" : "Scan") { startScan() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(phase == .scanning)
            }
            // Honest mode description — modes REALLY differ at the engine level
            // (a category with one honest mode shows no switcher at all).
            let caption = category.supportsModes
                ? (mode == .deep ? category.deepCaption : category.quickCaption)
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
        switch phase {
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
            Text("Safe items are pre-selected — Caution items are left for you to opt into.")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
            GlassTextField(placeholder: "Filter results", text: $filter)
            VStack(spacing: 12) {
                ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                    ResultCard(
                        item: item, index: index,
                        isSelected: selected.contains(item.id),
                        errorText: trashErrors[item.id],
                        reduceMotion: reduceMotion,
                        onToggle: { toggle(item) },
                        onReveal: { NSWorkspace.shared.activateFileViewerSelecting([item.url]) },
                        onPreview: category == .largeFiles ? { quickLookURL = item.url } : nil
                    )
                }
            }

        case .empty:
            EmptyStateView(
                title: "Nothing to clean",
                message: "A \(category.supportsModes ? mode.rawValue.lowercased() + " " : "")scan found nothing reclaimable here.",
                systemImage: "checkmark.seal",
                actionTitle: category.supportsModes && mode == .quick ? "Deep scan" : nil,
                action: category.supportsModes && mode == .quick ? { mode = .deep; startScan() } : nil
            )
            .frame(maxWidth: .infinity)
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

    private func toggle(_ item: ScannedItem) {
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }

    private func startScan() {
        scanTask?.cancel()
        filter = ""; selected = []; trashErrors = [:]
        setPhase(.scanning)
        scanTask = Task { @MainActor in
            // Real read-only scan off the main thread (sizing can take a moment).
            // Each category dispatches to its own engine; Quick/Deep genuinely
            // change engine behavior — never just a different sleep.
            let scanMode: SafeDeleteEngine.ScanMode = (mode == .deep) ? .deep : .quick
            let cat = category
            // Cancellation must be propagated by hand into the detached task
            // (the engines poll Task.isCancelled), so Cancel stops the disk
            // walk itself — not just the UI while I/O burns on in the background.
            let walk = Task.detached(priority: .userInitiated) { () -> [ScannedItem] in
                switch cat {
                case .developerCaches: return SafeDeleteEngine.scanReclaimable(mode: scanMode)
                case .orphanScan: return UninstallEngine.scanOrphans()
                case .largeFiles: return LargeFileEngine.scan(mode: scanMode)
                case .appUninstaller: return [] // routed to UninstallView, never here
                }
            }
            let found = await withTaskCancellationHandler {
                await walk.value
            } onCancel: {
                walk.cancel()
            }
            guard !Task.isCancelled else { return }
            items = found
            // Pre-select the .safe items; leave .caution for the user to opt into.
            selected = Set(found.filter { $0.risk == .safe }.map(\.id))
            setPhase(found.isEmpty ? .empty : .results)
            if !found.isEmpty {
                let size = ByteCountFormatter.string(fromByteCount: found.reduce(0) { $0 + $1.bytes }, countStyle: .file)
                toastStyle = .success
                toast = "Found \(size) across \(found.count) item\(found.count == 1 ? "" : "s") — read-only until you confirm"
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
                trashErrors[item.id] = outcome.error ?? "Could not move to Trash"
            }

            if reduceMotion { items.removeAll { trashedIDs.contains($0.id) } }
            else { withAnimation(Theme.spring) { items.removeAll { trashedIDs.contains($0.id) } } }
            selected.subtract(trashedIDs)

            let sizeStr = ByteCountFormatter.string(fromByteCount: reclaimed, countStyle: .file)
            let refused = outcomes.count - succeeded.count
            toastStyle = refused > 0 ? .warning : .success
            toast = "Moved \(succeeded.count) to Trash · \(sizeStr) reclaimed" + (refused > 0 ? " · \(refused) refused" : "")
            if items.isEmpty { setPhase(.empty) }
        }
    }

    private func setPhase(_ newPhase: Phase) {
        if reduceMotion { phase = newPhase }
        else { withAnimation(Theme.spring) { phase = newPhase } }
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
    ContentView()
        .frame(width: 880, height: 620)
        .preferredColorScheme(.dark)
}
