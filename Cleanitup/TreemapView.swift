import SwiftUI

// Phase 2.1 — the "Disk Map": a squarified treemap over the SAME measurements
// the Overview renders (the app-scoped StatsStore — never a second scan).
// Tile area ∝ allocated bytes, colors match the Overview legend
// (CategoryPalette), and the honest remainder is a tile like any other.
// Treemap over sunburst was a user decision (2026-06-10): area reads more
// honestly than angle, and tiles double as navigation into the surface that
// can act on each bucket.
//
// HONESTY RULES here:
//   - The map draws only once the measurement is complete — a half-measured
//     map would silently re-shuffle and imply precision that isn't there yet.
//   - Categories that can't be drawn honestly (denied root → unknown size,
//     or no honest remainder) are NAMED below the map, never silently absent.
//   - Pure presentation layer: reads the StatsStore snapshot, calls no engine.

struct TreemapView: View {
    let store: StatsStore
    var navigate: ((SidebarItem) -> Void)? = nil
    @AppStorage(PrefKey.permissionFlowCompleted) private var permissionFlowCompleted = false
    @State private var selectedID: String?

    private var snapshot: StatsSnapshot? { store.snapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                mapCard
                Spacer(minLength: 0)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        // Same idempotent pattern as the other measurement surfaces: reuse the
        // app-scoped snapshot; only start a run if nothing has ever run — and
        // never before the one-time permission moment has finished.
        .task {
            if store.snapshot == nil && permissionFlowCompleted { store.refresh() }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "rectangle.split.3x3")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Theme.primary)
                .frame(width: 54, height: 54)
                .background(Theme.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).strokeBorder(Theme.primary.opacity(0.25), lineWidth: 1))
                .shadowGlow(Theme.primary, radius: 16, strength: 0.3)
            VStack(alignment: .leading, spacing: 6) {
                Text("Disk Map").font(Typo.h3).foregroundStyle(Theme.textPrimary)
                Text("Your used space as a picture: every tile's area is proportional to real measured bytes — the same numbers as the Overview, drawn instead of listed.")
                    .font(.callout).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            PillBadge(text: snapshot?.isComplete == true ? "measured" : "measuring…", tint: Theme.neutral)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: Map card

    private var mapCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What your used space looks like").typoLabel()

            if let snapshot, snapshot.isComplete, let disk = snapshot.disk {
                let tiles = Self.tiles(for: snapshot)
                GeometryReader { geo in
                    let placed = Self.place(tiles, in: CGRect(origin: .zero, size: geo.size))
                    ZStack(alignment: .topLeading) {
                        ForEach(placed) { tile in
                            tileView(tile, used: disk.used)
                        }
                    }
                }
                .frame(height: 380)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1))

                if let selected = Self.tiles(for: snapshot).first(where: { $0.id == selectedID }) {
                    detailStrip(selected, used: disk.used)
                } else {
                    Text("Click a tile to see what's inside it and where to act on it.")
                        .font(.caption).foregroundStyle(Theme.textTertiary)
                }
                notDrawnNote(snapshot)
            } else {
                // Drawn only from a COMPLETE measurement — a half-measured map
                // would silently re-shuffle as buckets resolve.
                SkeletonView(height: 380, cornerRadius: Theme.radiusMd)
                Text("The map draws once every category is measured — partial pictures mislead.")
                    .font(.caption).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func tileView(_ tile: Tile, used: Int64) -> some View {
        let isSelected = tile.id == selectedID
        // Labels only where they honestly fit — tiny tiles stay quiet and rely
        // on the tooltip + detail strip instead of overlapping text.
        let showName = tile.rect.width > 76 && tile.rect.height > 30
        let showSize = tile.rect.width > 76 && tile.rect.height > 48
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(tile.color.opacity(isSelected ? 0.95 : 0.72))
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(isSelected ? Color.white.opacity(0.9) : Theme.bgPrimary.opacity(0.9),
                              lineWidth: isSelected ? 1.5 : 1))
            .overlay(alignment: .topLeading) {
                if showName {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tile.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.bgPrimary.opacity(0.9))
                            .lineLimit(1)
                        if showSize {
                            Text(tile.sizeText)
                                .font(.caption2).monospacedDigit()
                                .foregroundStyle(Theme.bgPrimary.opacity(0.7))
                        }
                    }
                    .padding(6)
                }
            }
            .frame(width: max(tile.rect.width, 1), height: max(tile.rect.height, 1))
            .offset(x: tile.rect.minX, y: tile.rect.minY)
            .contentShape(Rectangle())
            .onTapGesture { selectedID = (selectedID == tile.id) ? nil : tile.id }
            .help("\(tile.name) — \(tile.sizeText)")
            .accessibilityLabel("\(tile.name), \(tile.sizeText)")
            .accessibilityAddTraits(.isButton)
    }

    private func detailStrip(_ tile: Tile, used: Int64) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(tile.color).frame(width: 12, height: 12)
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(tile.name).font(Typo.cardHeading).foregroundStyle(Theme.textPrimary)
                    Text("\(tile.sizeText) · \(percentText(tile.bytes, of: used)) of used space")
                        .font(.caption).monospacedDigit().foregroundStyle(Theme.textSecondary)
                }
                Text(tile.explanation)
                    .font(.caption).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let act = tile.act, let navigate {
                Button(act.label) { navigate(act.destination) }
                    .buttonStyle(GlassButtonStyle())
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
    }

    /// Anything the map can't draw honestly is NAMED, never silently absent.
    @ViewBuilder
    private func notDrawnNote(_ snapshot: StatsSnapshot) -> some View {
        let denied = snapshot.categories.filter(\.rootDenied).map(\.category.name)
        let lines: [String] = (denied.isEmpty ? [] :
            ["Not drawn — size unknown without permission: \(denied.joined(separator: ", "))."])
            + (snapshot.unaccountedBytes == nil && snapshot.isComplete
               ? [snapshot.sumExceedsUsed
                  ? "No remainder tile: categories sum past Used (APFS clones share disk blocks)."
                  : "No remainder tile: it can't be computed honestly while folders are unreadable."]
               : [])
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(lines, id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func percentText(_ bytes: Int64, of used: Int64) -> String {
        guard used > 0 else { return "—" }
        let pct = Double(bytes) / Double(used) * 100
        return pct < 0.1 ? "<0.1%" : String(format: "%.1f%%", pct)
    }

    // MARK: Tiles (pure data — built from the snapshot, layout below)

    struct Tile: Identifiable {
        let id: String
        let name: String
        let bytes: Int64
        let color: Color
        let explanation: String
        let act: (label: String, destination: SidebarItem)?
        var rect: CGRect = .zero

        var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    }

    /// What lives in each bucket + which surface acts on it. Trash stays
    /// report-only on purpose (emptying it lives in Finder).
    private static func info(for id: String) -> (String, (String, SidebarItem)?) {
        switch id {
        case "music", "movies", "pictures", "desktop", "documents", "downloads", "home-other":
            return ("Your own files. The Large Files scan surfaces the biggest ones for review.",
                    ("Open Large Files", .category(.largeFiles)))
        case "applications":
            return ("Installed apps. Uninstall one and its leftovers together.",
                    ("Open App Uninstaller", .category(.appUninstaller)))
        case "caches", "logs", "developer":
            return ("Rebuildable caches, logs, and developer tooling — the classic reclaim targets.",
                    ("Open Developer Caches", .category(.developerCaches)))
        case "containers", "group-containers", "app-support":
            return ("Per-app data. Leftovers from deleted apps linger here.",
                    ("Open Orphaned Files", .category(.orphanScan)))
        case "trash":
            return ("Already in the Trash — emptying it stays in Finder, on purpose.", nil)
        case "mail-messages", "cloud", "library-other", "sys-library", "sys-other":
            return ("Mostly macOS-managed. See the System Data view for the honest breakdown.",
                    ("Open System Data", .systemData))
        case "remainder":
            return ("Sealed system volume, snapshots, and whatever our categories don't reach — honestly unindexed.",
                    ("Open System Data", .systemData))
        default:
            return ("Measured on your Mac.", nil)
        }
    }

    /// Snapshot → unplaced tiles. Enumerates the FULL category array so palette
    /// indices line up with the Overview legend; drops only what genuinely has
    /// no drawable size (nil/0 bytes — denied roots are disclosed separately).
    static func tiles(for snapshot: StatsSnapshot) -> [Tile] {
        var tiles: [Tile] = snapshot.categories.enumerated().compactMap { index, usage in
            guard let bytes = usage.bytes, bytes > 0 else { return nil }
            let (explanation, act) = info(for: usage.category.id)
            return Tile(id: usage.category.id, name: usage.category.name, bytes: bytes,
                        color: CategoryPalette.color(for: index), explanation: explanation,
                        act: act.map { (label: $0.0, destination: $0.1) })
        }
        if let remainder = snapshot.unaccountedBytes, remainder > 0 {
            let (explanation, act) = info(for: "remainder")
            tiles.append(Tile(id: "remainder", name: snapshot.unaccountedLabel, bytes: remainder,
                              color: CategoryPalette.remainder, explanation: explanation,
                              act: act.map { (label: $0.0, destination: $0.1) }))
        }
        return tiles.sorted { $0.bytes > $1.bytes }
    }

    // MARK: Squarified layout (Bruls–Huizing–van Wijk) — a pure function

    /// Place tiles (already sorted descending) into `rect`, keeping each row's
    /// worst aspect ratio as close to square as the greedy criterion allows.
    /// Pure geometry: no view state, trivially testable.
    static func place(_ tiles: [Tile], in rect: CGRect) -> [Tile] {
        let total = tiles.reduce(0.0) { $0 + Double($1.bytes) }
        guard total > 0, rect.width > 0, rect.height > 0 else { return [] }
        let scale = Double(rect.width * rect.height) / total
        let areas = tiles.map { Double($0.bytes) * scale }
        var placed: [Tile] = []
        var bounds = rect
        var index = 0

        // Worst aspect ratio if `row` is laid along a side of length `side`.
        func worst(_ row: ArraySlice<Double>, side: Double) -> Double {
            let sum = row.reduce(0, +)
            guard sum > 0, side > 0 else { return .infinity }
            let thickness = sum / side
            var m = 0.0
            for area in row {
                let length = area / thickness
                m = max(m, max(thickness / length, length / thickness))
            }
            return m
        }

        while index < areas.count {
            let side = Double(min(bounds.width, bounds.height))
            // Grow the row while it improves (or matches) the worst ratio.
            var end = index + 1
            while end < areas.count,
                  worst(areas[index...end], side: side) <= worst(areas[index..<end], side: side) {
                end += 1
            }
            let row = areas[index..<end]
            let sum = row.reduce(0, +)
            let thickness = side > 0 ? CGFloat(sum / side) : 0

            if bounds.width >= bounds.height {
                // Row is a vertical strip on the left edge.
                var y = bounds.minY
                for (offset, area) in row.enumerated() {
                    let h = thickness > 0 ? CGFloat(area) / thickness : 0
                    placed.append(withRect(tiles[index + offset],
                                           CGRect(x: bounds.minX, y: y, width: thickness, height: h)))
                    y += h
                }
                bounds = CGRect(x: bounds.minX + thickness, y: bounds.minY,
                                width: bounds.width - thickness, height: bounds.height)
            } else {
                // Row is a horizontal strip on the top edge.
                var x = bounds.minX
                for (offset, area) in row.enumerated() {
                    let w = thickness > 0 ? CGFloat(area) / thickness : 0
                    placed.append(withRect(tiles[index + offset],
                                           CGRect(x: x, y: bounds.minY, width: w, height: thickness)))
                    x += w
                }
                bounds = CGRect(x: bounds.minX, y: bounds.minY + thickness,
                                width: bounds.width, height: bounds.height - thickness)
            }
            index = end
        }
        return placed
    }

    private static func withRect(_ tile: Tile, _ rect: CGRect) -> Tile {
        var t = tile
        t.rect = rect
        return t
    }
}
