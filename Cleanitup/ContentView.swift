import SwiftUI

/// The planned cleaning surfaces. v1.0 ships the trust-first core (uninstall,
/// orphans, large files); developer caches are the v1.1 differentiation bet —
/// and the first one wired to the REAL SafeDeleteEngine.
enum CleanupCategory: String, CaseIterable, Identifiable {
    case appUninstaller = "App Uninstaller"
    case orphanScan = "Orphaned Files"
    case largeFiles = "Large Files"
    case developerCaches = "Developer Caches"

    var id: String { rawValue }

    /// Only this category performs a real on-disk scan + trash today.
    var isLive: Bool { self == .developerCaches }

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
        case .developerCaches: return "v1.1 · live"
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

// MARK: - Root

struct ContentView: View {
    @State private var selection: CleanupCategory? = .developerCaches
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    ScanView(category: selection).id(selection)
                } else {
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
    @State private var showConfirm = false
    @State private var scanTask: Task<Void, Never>?

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
        .toast(message: $toast, style: .success)
        .confirmationDialog(
            "Move \(selected.count) item\(selected.count == 1 ? "" : "s") to Trash?",
            isPresented: $showConfirm, titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { trashSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Items go to the Trash — you can restore them from there. Nothing is permanently deleted.")
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
            PillBadge(text: category.milestone, tint: category.isLive ? Theme.success : Theme.neutral)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var controls: some View {
        HStack(spacing: 14) {
            ModeSwitcher(options: Mode.allCases, title: { $0.rawValue }, selection: $mode)
                .frame(maxWidth: 220)
            Spacer()
            if phase == .results || phase == .empty {
                Button("Rescan") { startScan() }.buttonStyle(GlassButtonStyle())
            }
            Button(phase == .scanning ? "Scanning…" : "Scan") { startScan() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(phase == .scanning)
        }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .idle:
            EmptyStateView(
                title: "Ready when you are",
                message: category.isLive
                    ? "Run a scan to measure your real developer caches. Nothing is deleted without your review and confirmation."
                    : "This category is a preview of the design. Run a scan to see the flow — deletion is wired only for Developer Caches today.",
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
            GlassTextField(placeholder: "Filter results", text: $filter)
            VStack(spacing: 12) {
                ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                    ResultCard(
                        item: item, index: index,
                        isSelected: selected.contains(item.id),
                        reduceMotion: reduceMotion,
                        onToggle: { toggle(item) }
                    )
                }
            }

        case .empty:
            EmptyStateView(
                title: "Nothing to clean",
                message: "A \(mode.rawValue.lowercased()) scan found nothing reclaimable here.",
                systemImage: "checkmark.seal",
                actionTitle: category.isLive ? "Deep scan" : nil,
                action: category.isLive ? { mode = .deep; startScan() } : nil
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
        filter = ""; selected = []
        setPhase(.scanning)
        scanTask = Task { @MainActor in
            let found: [ScannedItem]
            if category.isLive {
                // Real read-only scan off the main thread (sizing can take a moment).
                found = await Task.detached(priority: .userInitiated) {
                    SafeDeleteEngine.scanDeveloperCaches()
                }.value
            } else {
                try? await Task.sleep(nanoseconds: mode == .deep ? 1_200_000_000 : 800_000_000)
                found = ScanView.demoItems(for: category, deep: mode == .deep)
            }
            guard !Task.isCancelled else { return }
            items = found
            // Pre-select the .safe items; leave .caution for the user to opt into.
            selected = Set(found.filter { $0.risk == .safe }.map(\.id))
            setPhase(found.isEmpty ? .empty : .results)
            if !found.isEmpty {
                let size = ByteCountFormatter.string(fromByteCount: found.reduce(0) { $0 + $1.bytes }, countStyle: .file)
                toast = category.isLive
                    ? "Found \(size) of real caches across \(found.count) paths"
                    : "Found \(size) across \(found.count) items (demo)"
            }
        }
    }

    private func trashSelected() {
        let chosen = selectedItems
        guard !chosen.isEmpty else { return }
        guard category.isLive else {
            toast = "Demo category — deletion is wired only for Developer Caches"
            return
        }
        let urls = chosen.map(\.url)
        Task { @MainActor in
            let outcomes = await Task.detached { SafeDeleteEngine.moveToTrash(urls) }.value
            let succeeded = zip(chosen, outcomes).filter { $0.1.success }
            let trashedIDs = Set(succeeded.map { $0.0.id })
            let reclaimed = outcomes.filter(\.success).reduce(0) { $0 + $1.reclaimedBytes }

            if reduceMotion { items.removeAll { trashedIDs.contains($0.id) } }
            else { withAnimation(Theme.spring) { items.removeAll { trashedIDs.contains($0.id) } } }
            selected.subtract(trashedIDs)

            let sizeStr = ByteCountFormatter.string(fromByteCount: reclaimed, countStyle: .file)
            let refused = outcomes.count - succeeded.count
            toast = "Moved \(succeeded.count) to Trash · \(sizeStr) reclaimed" + (refused > 0 ? " · \(refused) refused" : "")
            if items.isEmpty { setPhase(.empty) }
        }
    }

    private func setPhase(_ newPhase: Phase) {
        if reduceMotion { phase = newPhase }
        else { withAnimation(Theme.spring) { phase = newPhase } }
    }

    // Mock data for the not-yet-live categories (clearly labeled in the UI).
    static func demoItems(for category: CleanupCategory, deep: Bool) -> [ScannedItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        func mk(_ name: String, _ rel: String, _ bytes: Int64, _ risk: CleanRisk, _ detail: String) -> ScannedItem {
            ScannedItem(name: name, url: home.appendingPathComponent(rel), bytes: bytes, risk: risk, detail: detail)
        }
        switch category {
        case .appUninstaller:
            return [
                mk("Spotify", "Applications/Spotify.app", 1_200_000_000, .safe, "App + ~/Library leftovers"),
                mk("Figma", "Applications/Figma.app", 980_000_000, .safe, "App + caches"),
                mk("Zoom", "Applications/zoom.us.app", 410_000_000, .caution, "Check for background helper"),
            ]
        case .orphanScan:
            return [
                mk("OldApp Support", "Library/Application Support/OldApp", 240_000_000, .safe, "App already deleted"),
                mk("com.oldapp.plist", "Library/Preferences/com.oldapp.plist", 12_000, .safe, "Orphaned preference"),
            ]
        case .largeFiles:
            return deep ? [
                mk("archive.zip", "Downloads/archive.zip", 6_400_000_000, .caution, "You decide — read-only find"),
                mk("screen-recording.mov", "Desktop/screen-recording.mov", 2_100_000_000, .caution, "You decide"),
            ] : []
        case .developerCaches:
            return []
        }
    }
}

// MARK: - Result row (§5.2 staggerItem)

struct ResultCard: View {
    let item: ScannedItem
    let index: Int
    let isSelected: Bool
    let reduceMotion: Bool
    let onToggle: () -> Void

    @State private var shown = false

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Theme.primary : Theme.textTertiary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(Typo.cardHeading).foregroundStyle(Theme.textPrimary)
                Text(item.displayPath).font(Typo.mono).foregroundStyle(Theme.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            StatusBadge(kind: item.risk.status)
            Text(item.sizeText)
                .font(.subheadline.weight(.semibold)).monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
                .frame(minWidth: 70, alignment: .trailing)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: Theme.radiusXl)
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
