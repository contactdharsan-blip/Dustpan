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

    var blurb: String {
        switch self {
        case .appUninstaller:
            return "Remove an app and every leftover file it left in ~/Library."
        case .orphanScan:
            return "Find files left behind by apps you already deleted."
        case .largeFiles:
            return "Surface your biggest files — you decide what moves to Trash."
        case .developerCaches:
            return "Reclaim Xcode, simulator, node_modules and Docker bloat over known-safe paths."
        }
    }
}

// MARK: - Mock scan model

/// A single discovered item. `kind` carries the Safe/Caution risk label.
struct ScanItem: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let bytes: Int64
    let kind: StatusKind

    var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    /// Sample results per category. Developer-cache sizes are the real figures
    /// measured on a developer Mac (see PRD.md §2) — CoreSimulator is the worst offender.
    static func samples(for category: CleanupCategory, deep: Bool) -> [ScanItem] {
        switch category {
        case .developerCaches:
            var items = [
                ScanItem(name: "CoreSimulator", path: "~/Library/Developer/CoreSimulator", bytes: 25_000_000_000, kind: .safe),
                ScanItem(name: "Xcode DerivedData", path: "~/Library/Developer/Xcode/DerivedData", bytes: 8_200_000_000, kind: .safe),
                ScanItem(name: "iOS DeviceSupport", path: "~/Library/Developer/Xcode/iOS DeviceSupport", bytes: 5_700_000_000, kind: .caution),
                ScanItem(name: "npm cache", path: "~/.npm", bytes: 3_800_000_000, kind: .safe),
            ]
            if deep {
                items.append(ScanItem(name: "node_modules (open-design)", path: "~/open-design/node_modules", bytes: 1_300_000_000, kind: .caution))
                items.append(ScanItem(name: "Homebrew cache", path: "~/Library/Caches/Homebrew", bytes: 734_000_000, kind: .safe))
            }
            return items
        case .appUninstaller:
            return [
                ScanItem(name: "Spotify", path: "/Applications/Spotify.app", bytes: 1_200_000_000, kind: .safe),
                ScanItem(name: "Figma", path: "/Applications/Figma.app", bytes: 980_000_000, kind: .safe),
                ScanItem(name: "Zoom", path: "/Applications/zoom.us.app", bytes: 410_000_000, kind: .caution),
            ]
        case .orphanScan:
            return [
                ScanItem(name: "com.oldapp.plist", path: "~/Library/Preferences/com.oldapp.plist", bytes: 12_000, kind: .safe),
                ScanItem(name: "OldApp Support", path: "~/Library/Application Support/OldApp", bytes: 240_000_000, kind: .safe),
            ]
        case .largeFiles:
            return deep ? [
                ScanItem(name: "archive.zip", path: "~/Downloads/archive.zip", bytes: 6_400_000_000, kind: .caution),
                ScanItem(name: "screen-recording.mov", path: "~/Desktop/screen-recording.mov", bytes: 2_100_000_000, kind: .caution),
            ] : []
        }
    }
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
                    ScanView(category: selection)
                        .id(selection)   // fresh scan state per category
                } else {
                    ContentUnavailableView("Select a category", systemImage: "sidebar.left")
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .animation(motionSafeSpring(reduceMotion), value: selection)
        }
    }
}

// MARK: - Scan flow (showcases the component library)

struct ScanView: View {
    let category: CleanupCategory

    enum Mode: String, CaseIterable { case quick = "Quick", deep = "Deep" }
    enum Phase: Equatable { case idle, scanning, results, empty }

    @State private var mode: Mode = .quick
    @State private var phase: Phase = .idle
    @State private var items: [ScanItem] = []
    @State private var filter = ""
    @State private var toast: String?
    @State private var scanTask: Task<Void, Never>?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var filtered: [ScanItem] {
        guard !filter.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    private var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

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
    }

    // Header card
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
            PillBadge(text: category.milestone)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // Mode switcher + scan button
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

    // Phase-driven content (the §7.0 four-state contract)
    @ViewBuilder private var content: some View {
        switch phase {
        case .idle:
            EmptyStateView(
                title: "Ready when you are",
                message: "Run a \(mode.rawValue.lowercased()) scan to see what \(category.rawValue.lowercased()) can be safely reclaimed. Nothing is deleted without your review.",
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
                    ResultCard(item: item, index: index, reduceMotion: reduceMotion)
                }
            }

        case .empty:
            EmptyStateView(
                title: "Nothing to clean",
                message: "A \(mode.rawValue.lowercased()) scan found no reclaimable \(category.rawValue.lowercased()). Try a deep scan to look harder.",
                systemImage: "checkmark.seal",
                actionTitle: "Deep scan",
                action: { mode = .deep; startScan() }
            )
            .frame(maxWidth: .infinity)
        }
    }

    // Results summary: metrics + primary action
    private var summary: some View {
        HStack(alignment: .center, spacing: 28) {
            CountUpMetric(value: ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file), label: "Reclaimable")
            CountUpMetric(value: "\(items.count)", label: "Items")
            Spacer()
            Button("Move \(items.count) to Trash") { confirmTrash() }
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: Actions

    private func startScan() {
        scanTask?.cancel()
        filter = ""
        setPhase(.scanning)
        scanTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: mode == .deep ? 1_500_000_000 : 900_000_000)
            guard !Task.isCancelled else { return }
            let found = ScanItem.samples(for: category, deep: mode == .deep)
            items = found
            setPhase(found.isEmpty ? .empty : .results)
            if !found.isEmpty {
                let size = ByteCountFormatter.string(fromByteCount: found.reduce(0) { $0 + $1.bytes }, countStyle: .file)
                toast = "Found \(size) across \(found.count) items"
            }
        }
    }

    private func confirmTrash() {
        toast = "Preview first — nothing deleted yet (demo)"
    }

    private func setPhase(_ newPhase: Phase) {
        if reduceMotion { phase = newPhase }
        else { withAnimation(Theme.spring) { phase = newPhase } }
    }
}

// MARK: - Result row (§5.2 staggerItem)

struct ResultCard: View {
    let item: ScanItem
    let index: Int
    let reduceMotion: Bool

    @State private var shown = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.fill")
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 32, height: 32)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(Typo.cardHeading).foregroundStyle(Theme.textPrimary)
                Text(item.path).font(Typo.mono).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            StatusBadge(kind: item.kind)
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
        .frame(width: 860, height: 600)
        .preferredColorScheme(.dark)
}
