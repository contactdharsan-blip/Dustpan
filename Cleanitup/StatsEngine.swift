// StatsEngine — Foundation-only (no SwiftUI), mirroring SafeDeleteEngine's testability.
// Powers the storage "Overview" dashboard. Every number is REAL or an em-dash.
//
// CONCURRENCY CONTRACT (load-bearing — do not change shape):
//   StatsEngine.live() returns an AsyncStream<StatsSnapshot> that emits
//   successively-more-complete IMMUTABLE snapshots from a detached background
//   task, then finishes. The dashboard consumes it idiomatically:
//
//       .task { for await snap in StatsEngine.live() { self.snapshot = snap } }
//
//   Sizing therefore runs OFF the main thread, and the dashboard can render
//   SkeletonView for any CategoryUsage whose `bytes == nil` (still measuring).
//   The stream cancels automatically when the consuming .task is torn down
//   (continuation.onTermination cancels the detached task).
//
// EMISSION ORDER the implementer MUST follow:
//   1. Emit immediately: disk totals resolved, every category bytes == nil,
//      reclaimable == [], isComplete == false  → dashboard shows all skeletons.
//   2. Emit after each category is sized (one snapshot per category, that
//      category's bytes now non-nil) → skeletons resolve one by one.
//   3. Emit after scanReclaimable(mode: .quick) completes (reclaimable populated).
//   4. Final emit: isComplete == true → score & unaccountedBytes become non-nil.
//   Then continuation.finish().
//   `score` and `unaccountedBytes` are nil until isComplete == true so the
//   dashboard never renders a half-baked score.

import Foundation

/// One disk bucket. Disjoint BY CONSTRUCTION: every explicit subtree appears in
/// exactly one category, and "rest of X" categories exclude exactly the
/// top-level names that other categories itemize — so the sum never double-counts.
struct StorageCategory: Identifiable, Hashable {
    let id: String                         // stable, e.g. "library-other" (not derived from a path)
    let name: String                       // display name, e.g. "Downloads"
    let systemImage: String                // SF Symbol
    let roots: [String]                    // "~/..." (resolved via homeDirectoryForCurrentUser) or absolute "/..."
    let excludeTopLevelNames: Set<String>  // non-empty → "rest of root" semantics (single-root only)
    let isReadOnlySystem: Bool             // sizing-only bucket outside home (never a delete target)

    init(id: String, name: String, systemImage: String, roots: [String],
         excludeTopLevelNames: Set<String> = [], isReadOnlySystem: Bool = false) {
        self.id = id; self.name = name; self.systemImage = systemImage
        self.roots = roots; self.excludeTopLevelNames = excludeTopLevelNames
        self.isReadOnlySystem = isReadOnlySystem
    }
}

/// A category's measured size. `bytes == nil && !rootDenied` means STILL SIZING →
/// the dashboard renders a SkeletonView; `rootDenied` means macOS refused to let
/// us read the root (show "—" + a permission affordance, never a fake 0);
/// `deniedCount > 0` means the byte total is a FLOOR (shown as "≥ X").
struct CategoryUsage: Identifiable, Hashable {
    var id: String { category.id }
    let category: StorageCategory
    let bytes: Int64?
    let deniedCount: Int
    let rootDenied: Bool

    init(category: StorageCategory, bytes: Int64?, deniedCount: Int = 0, rootDenied: Bool = false) {
        self.category = category; self.bytes = bytes
        self.deniedCount = deniedCount; self.rootDenied = rootDenied
    }

    var isMeasured: Bool { bytes != nil }
    var needsPermission: Bool { rootDenied || deniedCount > 0 }
    /// Formatted size; "—" while still sizing OR when the root was denied;
    /// "≥ X" when subtrees were denied (a partial count is a floor, never exact).
    var sizeText: String {
        if rootDenied { return "—" }
        guard let bytes else { return "—" }
        let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return deniedCount > 0 ? "≥ " + formatted : formatted
    }
}

/// Real disk capacity from URLResourceValues on the home URL.
/// NOTE: volumeTotalCapacity is `Int?`; volumeAvailableCapacityForImportantUsage
/// is `Int64?` — diskTotals() casts total to Int64. "Free"/"used" both derive
/// from availableForImportant (one definition of Used — they reconcile on screen).
struct DiskTotals: Equatable {
    let totalCapacity: Int64          // volumeTotalCapacity (cast Int -> Int64)
    let availableForImportant: Int64  // volumeAvailableCapacityForImportantUsage
    /// Strict free space (volumeAvailableCapacity, excludes purgeable); nil if
    /// the key was unavailable — purgeable then honestly reads "—".
    let availableStrict: Int64?
    var used: Int64 { max(0, totalCapacity - availableForImportant) }
    /// Space macOS can purge on demand (importance-aware free minus strict free).
    /// Read-only information — NEVER a score input or a reclaimable item.
    var purgeable: Int64? { availableStrict.map { max(0, availableForImportant - $0) } }
    var purgeableText: String {
        purgeable.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
    }
    var freeFraction: Double { totalCapacity > 0 ? Double(availableForImportant) / Double(totalCapacity) : 0 }
    var totalText: String { ByteCountFormatter.string(fromByteCount: totalCapacity, countStyle: .file) }
    var freeText: String  { ByteCountFormatter.string(fromByteCount: availableForImportant, countStyle: .file) }
    var usedText: String  { ByteCountFormatter.string(fromByteCount: used, countStyle: .file) }
}

/// The 0–100 cleanliness score, carrying its own reproducible inputs so the
/// number is auditable next to it. value == round(percentFree − reclaimablePenalty).
struct CleanlinessScore: Equatable {
    let value: Int                  // 0...100
    let freeFraction: Double        // input 1
    let reclaimableBytes: Int64     // input 2 (drives the penalty)
    let inputsSummary: [String]     // human-readable inputs to show beside the score
}

/// One immutable point-in-time view of storage. Reuses SafeDeleteEngine's
/// `ScannedItem` for the reclaimable list verbatim (no new item type).
struct StatsSnapshot {
    let disk: DiskTotals?           // nil only if volume keys unavailable (show "—")
    let categories: [CategoryUsage] // always all StatsEngine.categories, in order
    let reclaimable: [ScannedItem]  // from SafeDeleteEngine.scanReclaimable(mode: .quick)
    let isComplete: Bool            // true once every category sized + caches scanned

    /// Sum of measured categories (unmeasured and root-denied count as 0 mid-scan).
    var measuredCategoryBytes: Int64 { categories.reduce(0) { $0 + ($1.bytes ?? 0) } }

    /// True when the itemized categories sum PAST Used — APFS clones share disk
    /// space (two real files can occupy the same blocks), and hard links count
    /// once per path rather than once per inode. The remainder then renders "—"
    /// with a one-line explanation instead of a silently-clamped 0.
    var sumExceedsUsed: Bool {
        isComplete && disk.map { measuredCategoryBytes > $0.used } ?? false
    }

    /// True when any category hit a permission wall (drives the quiet FDA hint).
    var anyPermissionDenied: Bool { categories.contains { $0.needsPermission } }

    /// True when any category's ROOT was unreadable — its real size is unknown
    /// (it sums as 0), so the Used-based remainder can't be computed honestly.
    var anyRootDenied: Bool { categories.contains { $0.rootDenied } }

    /// HONEST remainder = Used − sum(categories). nil until complete; nil when
    /// `sumExceedsUsed` (the dashboard shows "—" + the APFS-clones note rather
    /// than a fake 0); and nil when `anyRootDenied` — a denied root's bytes would
    /// otherwise silently inflate the remainder under the wrong label. The
    /// max(0,…) only absorbs tiny mid-emit races.
    var unaccountedBytes: Int64? {
        guard isComplete, let disk, !sumExceedsUsed, !anyRootDenied else { return nil }
        return max(0, disk.used - measuredCategoryBytes)
    }
    /// The MANDATED label for the remainder — never "System Data".
    var unaccountedLabel: String { "System & other (not itemized)" }

    var reclaimableBytes: Int64 { reclaimable.reduce(0) { $0 + $1.bytes } }
    var cacheLocationsFound: Int { reclaimable.count }
    /// Gated on isComplete so a half-finished scan never crowns a transient winner.
    var largestCategory: CategoryUsage? {
        guard isComplete else { return nil }
        return categories.filter { $0.bytes != nil }.max { ($0.bytes ?? 0) < ($1.bytes ?? 0) }
    }

    /// nil until isComplete. value = round(freeFraction*100 − penaltyPts),
    /// penaltyPts = min(reclaimableBytes / totalCapacity * 100, 10), clamped 0...100.
    var score: CleanlinessScore? {
        guard isComplete, let disk else { return nil }
        let free = disk.freeFraction
        let penaltyPts = disk.totalCapacity > 0
            ? min(Double(reclaimableBytes) / Double(disk.totalCapacity) * 100, 10) : 0
        let v = Int((free * 100 - penaltyPts).rounded())
        return CleanlinessScore(
            value: max(0, min(100, v)),
            freeFraction: free,
            reclaimableBytes: reclaimableBytes,
            inputsSummary: [
                "\(Int((free * 100).rounded()))% of disk free",
                ByteCountFormatter.string(fromByteCount: reclaimableBytes, countStyle: .file)
                    + " reclaimable now (penalty up to 10 pts)",
            ]
        )
    }
}

enum StatsEngine {

    /// The disjoint disk buckets measured via SafeDeleteEngine.sizeReport(of:).
    /// Explicit subtrees appear in exactly one category, and the "rest of X"
    /// buckets (`excludeTopLevelNames`) exclude exactly the names other categories
    /// itemize — so the sum never double-counts and the "System & other" remainder
    /// stays an honest leftover (genuinely sealed system, preboot, swap).
    /// DECLARATION ORDER == SCAN ORDER: TCC-prompted folders (Desktop, Documents,
    /// Downloads) go LAST — sizing blocks synchronously on each permission dialog,
    /// so putting them first stalled the whole first-run dashboard on a prompt.
    /// This way every non-gated bucket resolves progressively while the user
    /// decides; expect up to three sequential prompts at the tail. Order does not
    /// affect disjointness — exclusions are by top-level name, not position.
    /// Since the one-time PermissionGateView, these dialogs are normally already
    /// answered before any scan; the ordering stays for the Skip path, where
    /// they still fire here at the tail.
    static let categories: [StorageCategory] = [
        StorageCategory(id: "music",     name: "Music",     systemImage: "music.note",             roots: ["~/Music"]),
        StorageCategory(id: "movies",    name: "Movies",    systemImage: "film",                   roots: ["~/Movies"]),
        StorageCategory(id: "pictures",  name: "Pictures & Photos", systemImage: "photo",          roots: ["~/Pictures"]),
        StorageCategory(id: "applications", name: "Applications", systemImage: "app.badge",
                        roots: ["/Applications", "~/Applications"], isReadOnlySystem: true),
        StorageCategory(id: "caches",    name: "App Caches", systemImage: "shippingbox",           roots: ["~/Library/Caches"]),
        StorageCategory(id: "logs",      name: "Logs",      systemImage: "text.alignleft",         roots: ["~/Library/Logs"]),
        StorageCategory(id: "developer", name: "Developer", systemImage: "hammer",                 roots: ["~/Library/Developer"]),
        StorageCategory(id: "containers", name: "App Containers", systemImage: "square.stack.3d.up",
                        roots: ["~/Library/Containers"]),
        StorageCategory(id: "group-containers", name: "Group Containers", systemImage: "square.stack.3d.up.fill",
                        roots: ["~/Library/Group Containers"]),
        StorageCategory(id: "mail-messages", name: "Mail & Messages", systemImage: "envelope",
                        roots: ["~/Library/Mail", "~/Library/Messages"]),
        StorageCategory(id: "cloud", name: "iCloud & cloud storage (on this Mac)", systemImage: "icloud",
                        roots: ["~/Library/Mobile Documents", "~/Library/CloudStorage"]),
        StorageCategory(id: "app-support", name: "App Support", systemImage: "gearshape.2",
                        roots: ["~/Library/Application Support"]),
        StorageCategory(id: "library-other", name: "Other Library", systemImage: "books.vertical",
                        roots: ["~/Library"],
                        excludeTopLevelNames: ["Caches", "Logs", "Developer", "Containers",
                                               "Group Containers", "Mail", "Messages",
                                               "Mobile Documents", "CloudStorage",
                                               "Application Support"]),
        StorageCategory(id: "trash", name: "Trash", systemImage: "trash",
                        roots: ["~/.Trash"]), // report-only: emptying stays in Finder
        // Excludes `Applications` too, so ~/Applications isn't counted twice (bucket 7).
        StorageCategory(id: "home-other", name: "Other home folders", systemImage: "house",
                        roots: ["~"],
                        excludeTopLevelNames: ["Desktop", "Documents", "Downloads", "Movies",
                                               "Music", "Pictures", "Library", "Applications",
                                               ".Trash"]),
        StorageCategory(id: "sys-library", name: "System libraries (read-only)", systemImage: "building.columns",
                        roots: ["/Library"], isReadOnlySystem: true),
        StorageCategory(id: "sys-other", name: "macOS support & services (read-only)", systemImage: "gear",
                        roots: ["/System/Volumes/Data/System", "/private/var", "/usr/local",
                                "/opt", "/Users/Shared"], isReadOnlySystem: true),
        // TCC-gated folders LAST (see DECLARATION ORDER note above).
        StorageCategory(id: "desktop",   name: "Desktop",   systemImage: "menubar.dock.rectangle", roots: ["~/Desktop"]),
        StorageCategory(id: "documents", name: "Documents", systemImage: "doc",                    roots: ["~/Documents"]),
        StorageCategory(id: "downloads", name: "Downloads", systemImage: "arrow.down.circle",      roots: ["~/Downloads"]),
    ]

    /// Resolve a category root: "~"-prefixed via homeDirectoryForCurrentUser
    /// (never a hardcoded /Users/<name>), anything else as an absolute path.
    private static func resolve(_ root: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if root == "~" { return home }
        if root.hasPrefix("~/") { return home.appendingPathComponent(String(root.dropFirst(2))) }
        return URL(fileURLWithPath: root)
    }

    /// Size one category: sum sizeReport over its roots, applying the top-level
    /// exclusions (single-root "rest of X" buckets). rootDenied is OR'd across
    /// roots; deniedCounts sum.
    private static func sizeCategory(_ category: StorageCategory) -> SizeReport {
        var combined = SizeReport()
        for root in category.roots {
            let url = resolve(root)
            let report = category.excludeTopLevelNames.isEmpty
                ? SafeDeleteEngine.sizeReport(of: url)
                : SafeDeleteEngine.sizeReport(of: url, excludingTopLevelNames: category.excludeTopLevelNames)
            combined.bytes += report.bytes
            combined.deniedCount += report.deniedCount
            combined.rootDenied = combined.rootDenied || report.rootDenied
        }
        return combined
    }

    // MARK: Disk totals

    /// Real capacity from URLResourceValues on the home URL. Returns nil only if
    /// the volume keys are unavailable (dashboard shows "—", never a fake number).
    /// volumeTotalCapacity is `Int?` (cast to Int64); volumeAvailableCapacityForImportantUsage
    /// is already `Int64?`. Both optionals are handled explicitly — never force-unwrapped.
    static func diskTotals() -> DiskTotals? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey, // strict free → purgeable; non-fatal if missing
        ]
        guard let values = try? home.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return DiskTotals(totalCapacity: Int64(total),
                          availableForImportant: available,
                          availableStrict: values.volumeAvailableCapacity.map(Int64.init))
    }

    // MARK: Progressive snapshot stream

    /// Progressive, off-main snapshot stream (see CONCURRENCY CONTRACT above).
    /// Emits a skeleton-only snapshot first, then one per sized category, then one
    /// with caches scanned, then a final isComplete snapshot — then finishes.
    static func live() -> AsyncStream<StatsSnapshot> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                // Disk totals resolve first so the very first emit already carries them
                // (or nil — passed straight through so the dashboard shows "—").
                let disk = diskTotals()

                // Seed every category as unmeasured (bytes == nil → SkeletonView).
                var usages = categories.map { CategoryUsage(category: $0, bytes: nil) }

                // 1. Immediate skeleton emit.
                continuation.yield(StatsSnapshot(disk: disk, categories: usages,
                                                 reclaimable: [], isComplete: false))

                // 2. Size each category in order, emitting after each so skeletons
                //    resolve one by one. sizeCategory() is called unconditionally —
                //    a missing path honestly measures 0, never a permanent skeleton;
                //    a permission-DENIED root carries bytes == nil + rootDenied so
                //    it renders "—" (never a fake 0) and sums as 0.
                for index in usages.indices {
                    if Task.isCancelled { continuation.finish(); return }
                    let report = sizeCategory(categories[index])
                    usages[index] = CategoryUsage(category: categories[index],
                                                  bytes: report.rootDenied ? nil : report.bytes,
                                                  deniedCount: report.deniedCount,
                                                  rootDenied: report.rootDenied)
                    continuation.yield(StatsSnapshot(disk: disk, categories: usages,
                                                     reclaimable: [], isComplete: false))
                }

                // 3. Quick scan of known reclaimable locations, then emit (still
                //    incomplete). Always .quick here — fast and honest; deep
                //    discovery lives behind ScanView's explicit Deep mode.
                if Task.isCancelled { continuation.finish(); return }
                let reclaimable = SafeDeleteEngine.scanReclaimable(mode: .quick)
                continuation.yield(StatsSnapshot(disk: disk, categories: usages,
                                                 reclaimable: reclaimable, isComplete: false))

                // 4. Final emit: isComplete == true. This is the ONLY trigger that
                //    makes score & unaccountedBytes non-nil (they self-gate on it).
                if Task.isCancelled { continuation.finish(); return }
                continuation.yield(StatsSnapshot(disk: disk, categories: usages,
                                                 reclaimable: reclaimable, isComplete: true))
                continuation.finish()
            }
            // Tearing down the consuming .task cancels the detached sizing task.
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
