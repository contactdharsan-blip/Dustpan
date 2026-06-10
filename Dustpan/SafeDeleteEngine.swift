import Foundation

// The safe-delete core. Foundation-only (no SwiftUI) so it can be unit-tested
// standalone with `swiftc`. Design contract (PRD §6): move to Trash, never `rm`;
// refuse anything outside the user's home or under system/SIP paths; report
// exactly what was reclaimed. Nothing here deletes without an explicit caller.

/// Honest risk label for a discovered item (drives the Safe/Caution badge).
enum CleanRisk: Hashable {
    case safe       // rebuilt/repopulated automatically — low consequence
    case caution    // reclaimable but has a real cost to regenerate
}

/// One thing a scan found. Carries the real on-disk URL so the engine can act on it.
struct ScannedItem: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let url: URL
    let bytes: Int64
    let risk: CleanRisk
    let detail: String
    /// Vendor prefix ("com.spotify") of the app this item belonged to, when a
    /// scan can infer one (orphan scan). Lets the UI group leftovers per app.
    var ownerApp: String? = nil

    var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    /// Home-relative path for display (`/Users/x/Library` → `~/Library`).
    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.replacingOccurrences(of: home, with: "~")
    }
}

/// Why a path was refused — surfaced to the user, never silently swallowed.
enum SafetyVerdict: Equatable {
    case allowed
    case blockedSystemPath   // under a SIP/system root — never touch
    case blockedOutsideHome  // outside the user's home directory
    case blockedMissing      // nothing there to delete
    case blockedNeedsAdmin   // root-owned (App Store/installer) — Finder asks for admin auth

    var isAllowed: Bool { self == .allowed }
}

/// Honest sizing result. `deniedCount` counts permission-denied subtrees/files
/// (the byte total is then a FLOOR, shown as "≥"); `rootDenied` means the root
/// itself was unreadable (shown as "—", never a fake 0).
struct SizeReport: Equatable {
    var bytes: Int64 = 0
    var deniedCount: Int = 0
    var rootDenied: Bool = false
}

/// Result of attempting to Trash one item. `trashedTo` is where the item landed
/// inside the Trash — the undo journal's restore handle.
struct TrashOutcome: Identifiable {
    let id = UUID()
    let url: URL
    let success: Bool
    let reclaimedBytes: Int64
    let error: String?
    var trashedTo: URL? = nil
}

extension Array {
    /// Bounds-checked subscript (used to pair optional name lists with URLs).
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

enum SafeDeleteEngine {

    /// System roots we refuse outright (defense-in-depth on top of the home-only rule).
    static let blockedRoots = ["/System", "/usr", "/bin", "/sbin", "/Library",
                               "/private", "/Applications", "/opt", "/cores", "/Network"]

    // MARK: Safety gate

    /// The ONE exception to the home-only rule: a top-level `.app` bundle
    /// directly inside /Applications, and only when the user explicitly chose to
    /// uninstall it. Still Trash-only; SIP-protected Apple apps refuse at trash
    /// time and that refusal is surfaced. Nested paths (anything *inside* a
    /// bundle, or in a subfolder) stay blocked.
    static func isUserUninstallableAppBundle(_ path: String) -> Bool {
        guard path.hasPrefix("/Applications/"), path.hasSuffix(".app") else { return false }
        // Exactly ["", "Applications", "Name.app"] — no deeper.
        return path.components(separatedBy: "/").count == 3
    }

    /// App Store apps (and anything installed by a root installer) are owned by
    /// root — a user-level trashItem is refused by macOS with an opaque error.
    /// Those route through `finderTrash`: Finder performs the same Trash-only
    /// move and macOS shows its standard admin-authorization popup. Unreadable
    /// attributes fall through to the OS refusal at trash time (still surfaced,
    /// never swallowed).
    static func ownedByAnotherUser(_ path: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let owner = attrs[.ownerAccountID] as? NSNumber else { return false }
        return owner.uint32Value != getuid()
    }

    /// A path is allowed ONLY if it lives inside the user's home directory and is
    /// not under any blocked system root. Symlinks are resolved first so a link
    /// can't smuggle a system path past the check. Sole documented exception:
    /// `isUserUninstallableAppBundle` (explicit uninstall of a /Applications app).
    static func verdict(for url: URL) -> SafetyVerdict {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath().standardizedFileURL.path

        if isUserUninstallableAppBundle(path) {
            guard FileManager.default.fileExists(atPath: path) else { return .blockedMissing }
            return ownedByAnotherUser(path) ? .blockedNeedsAdmin : .allowed
        }

        for root in blockedRoots where path == root || path.hasPrefix(root + "/") {
            // /private/var/folders is fine (temp), but we still require home-membership below,
            // so a blocked root that isn't under home stays blocked.
            if !(path == home || path.hasPrefix(home + "/")) { return .blockedSystemPath }
        }
        guard path == home || path.hasPrefix(home + "/") else { return .blockedOutsideHome }
        guard path != home else { return .blockedSystemPath } // never the home dir itself
        guard FileManager.default.fileExists(atPath: path) else { return .blockedMissing }
        return .allowed
    }

    // MARK: Sizing

    /// True for the permission-denial shapes macOS actually throws: Cocoa 257
    /// (NSFileReadNoPermissionError, what TCC denials surface as) or a POSIX
    /// EPERM/EACCES (possibly wrapped as the underlying error). Also reused by
    /// PermissionGateView's one-time probe so denial classification is
    /// identical everywhere.
    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoPermissionError { return true } // 257
        let posix = (ns.userInfo[NSUnderlyingErrorKey] as? NSError) ?? ns
        return posix.domain == NSPOSIXErrorDomain && (posix.code == Int(EPERM) || posix.code == Int(EACCES))
    }

    /// Allocated size of a file or directory tree, with permission failures
    /// COUNTED instead of silently swallowed: `deniedCount > 0` means the byte
    /// total is a floor (display "≥"), `rootDenied` means the root itself was
    /// unreadable (display "—", never a fake 0). Never crosses volume boundaries.
    static func sizeReport(of url: URL) -> SizeReport {
        let fm = FileManager.default
        var report = SizeReport()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return report }
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                                      .isRegularFileKey, .isDirectoryKey, .isVolumeKey]

        func allocatedBytes(_ v: URLResourceValues) -> Int64 {
            Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }

        if !isDir.boolValue {
            do { report.bytes = allocatedBytes(try url.resourceValues(forKeys: Set(keys))) }
            catch { if isPermissionError(error) { report.rootDenied = true } }
            return report
        }

        // Root probe: an unreadable directory surfaces as denied, never as 0.
        do { _ = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: []) }
        catch {
            if isPermissionError(error) { report.rootDenied = true }
            return report
        }

        var denied = 0
        // options stay [] on purpose: package descendants (.app bundles, photo
        // libraries) and hidden files are real disk usage and MUST be counted.
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                     errorHandler: { _, error in
                                         if isPermissionError(error) { denied += 1 }
                                         return true // continue past failures, never abort the walk
                                     })
        else { return report }

        var fileCount = 0
        for case let child as URL in en {
            fileCount += 1
            // Cancellation: return a partial total — callers are already tearing down.
            if fileCount % 4096 == 0 && Task.isCancelled { break }
            do {
                let v = try child.resourceValues(forKeys: Set(keys))
                if v.isVolume == true { // mounted volume inside the tree — never cross it
                    if v.isDirectory == true { en.skipDescendants() }
                    continue
                }
                if v.isRegularFile == true { report.bytes += allocatedBytes(v) }
            } catch {
                if isPermissionError(error) { denied += 1 }
            }
        }
        report.deniedCount += denied
        return report
    }

    /// "Rest of root" sizing: sums every top-level child EXCEPT the named ones
    /// (which other categories itemize), skipping symlinks (e.g. the live
    /// `~/Library/GroupContainersAlias → Group Containers` hazard) and mount
    /// points so nothing is double-counted or cross-volume.
    static func sizeReport(of root: URL, excludingTopLevelNames excluded: Set<String>) -> SizeReport {
        let fm = FileManager.default
        var report = SizeReport()
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isVolumeKey]
        let children: [URL]
        do {
            // No .skipsHiddenFiles: hidden dirs (~/.npm, ~/.cargo…) are real usage.
            children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys), options: [])
        } catch {
            if isPermissionError(error) { report.rootDenied = true }
            return report
        }
        for child in children {
            if Task.isCancelled { break }
            if excluded.contains(child.lastPathComponent) { continue }
            let v = try? child.resourceValues(forKeys: keys)
            if v?.isSymbolicLink == true { continue }
            if v?.isVolume == true { continue }
            let sub = sizeReport(of: child)
            report.bytes += sub.bytes
            report.deniedCount += sub.deniedCount
            if sub.rootDenied { report.deniedCount += 1 } // denied subtree → partial total, not 0
        }
        return report
    }

    /// Allocated size of a file or directory tree (what actually frees on disk).
    /// Shim over sizeReport(of:) for moveToTrash and existing call sites.
    static func size(of url: URL) -> Int64 { sizeReport(of: url).bytes }

    // MARK: Trash (the only destructive op — reversible)

    /// Move one item to the Trash. Refuses unsafe paths; never permanently
    /// deletes. EVERY attempt — success or refusal — is recorded in the undo
    /// journal here at the engine level, so no call site can forget (C1).
    @discardableResult
    static func moveToTrash(_ url: URL, name: String? = nil, context: String = "Cleanup") -> TrashOutcome {
        let outcome = trashWithoutJournal(url)
        UndoJournal.record([UndoJournal.entry(for: outcome,
                                              name: name ?? url.lastPathComponent,
                                              context: context)])
        return outcome
    }

    static func moveToTrash(_ urls: [URL], names: [String]? = nil, context: String = "Cleanup") -> [TrashOutcome] {
        let outcomes = urls.map(trashWithoutJournal)
        let entries = outcomes.enumerated().map { i, outcome in
            UndoJournal.entry(for: outcome,
                              name: names?[safe: i] ?? outcome.url.lastPathComponent,
                              context: context)
        }
        UndoJournal.record(entries)
        return outcomes
    }

    private static func trashWithoutJournal(_ url: URL) -> TrashOutcome {
        let v = verdict(for: url)
        // Root-owned uninstall carve-out: macOS refuses a user-level trashItem,
        // so the move is delegated to Finder, which shows the system admin-auth
        // popup. Only the /Applications top-level-.app verdict can return this.
        if v == .blockedNeedsAdmin { return finderTrash(url) }
        guard v.isAllowed else {
            return TrashOutcome(url: url, success: false, reclaimedBytes: 0,
                                error: "Refused (\(v)) — outside the safe zone")
        }
        let reclaimed = size(of: url)
        do {
            var landedAt: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &landedAt)
            return TrashOutcome(url: url, success: true, reclaimedBytes: reclaimed,
                                error: nil, trashedTo: landedAt as URL?)
        } catch {
            return TrashOutcome(url: url, success: false, reclaimedBytes: 0,
                                error: error.localizedDescription)
        }
    }

    /// Trash a root-owned /Applications bundle by asking Finder to do it.
    /// Finder performs the same move-to-Trash and macOS shows its standard
    /// admin-authorization popup (password / Touch ID) — Dustpan itself never
    /// holds elevated rights and never sees the credential; the user authorizes
    /// each operation. First use also triggers the one-time "Dustpan wants to
    /// control Finder" Automation consent. Runs out-of-process (osascript) so
    /// no app thread blocks while the popup is up. Cancel/denial are surfaced.
    private static func finderTrash(_ url: URL) -> TrashOutcome {
        let reclaimed = size(of: url)
        // The path travels as argv, never interpolated into the script source —
        // a hostile bundle name (quotes, newlines…) can't inject AppleScript.
        let script = """
        on run argv
            set p to POSIX file (item 1 of argv)
            tell application "Finder" to set trashed to (delete p) as alias
            return POSIX path of trashed
        end run
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, url.path]
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch {
            return TrashOutcome(url: url, success: false, reclaimedBytes: 0,
                                error: "Couldn't ask Finder to move it: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        let outText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            return TrashOutcome(url: url, success: false, reclaimedBytes: 0,
                                error: friendlyFinderError(errText))
        }
        // Finder reports where the item landed ("/Users/x/.Trash/Name.app/") —
        // the journal's Put Back handle. Fall back to the conventional Trash
        // path if the output didn't parse; nil stays nil (honest notRestorable).
        var landed: URL?
        var path = outText.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path.hasPrefix("/") {
            landed = URL(fileURLWithPath: path)
        } else {
            let guess = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".Trash/\(url.lastPathComponent)")
            if FileManager.default.fileExists(atPath: guess.path) { landed = guess }
        }
        return TrashOutcome(url: url, success: true, reclaimedBytes: reclaimed,
                            error: nil, trashedTo: landed)
    }

    /// Map osascript's stderr to something the user can act on — never swallowed.
    private static func friendlyFinderError(_ stderr: String) -> String {
        if stderr.contains("-128") {
            return "Cancelled — the admin authorization prompt was dismissed. Nothing was moved."
        }
        if stderr.contains("-1743") || stderr.localizedCaseInsensitiveContains("not authorized") {
            return "Dustpan isn't allowed to ask Finder. Enable Finder for Dustpan in System Settings → Privacy & Security → Automation, then try again."
        }
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Finder couldn't move it to the Trash." : trimmed
    }

    // MARK: Real scan — reclaimable locations (read-only)

    /// Quick = the fixed, KNOWN reclaimable paths below only (no tree discovery).
    /// Deep  = strict SUPERSET: Quick + bounded read-only discovery (large per-app
    ///         caches, simulator devices, Xcode archives, node_modules).
    enum ScanMode { case quick, deep }

    private struct CacheSpec {
        let name: String, relativePath: String, risk: CleanRisk, detail: String
    }

    /// Known, genuinely-reclaimable locations. Honest risk labels:
    /// `.safe` regenerates automatically, `.caution` has a real regeneration cost.
    private static let quickSpecs: [CacheSpec] = [
        .init(name: "Xcode DerivedData", relativePath: "Library/Developer/Xcode/DerivedData",
              risk: .safe, detail: "Rebuilt on next build"),
        .init(name: "Simulator caches", relativePath: "Library/Developer/CoreSimulator/Caches",
              risk: .safe, detail: "Regenerated by the simulator"),
        .init(name: "iOS DeviceSupport", relativePath: "Library/Developer/Xcode/iOS DeviceSupport",
              risk: .caution, detail: "Re-downloaded when a device reconnects"),
        .init(name: "Homebrew cache", relativePath: "Library/Caches/Homebrew",
              risk: .safe, detail: "Downloaded again on next install"),
        .init(name: "npm cache", relativePath: ".npm/_cacache",
              risk: .safe, detail: "Repopulated by npm"),
        .init(name: "Yarn cache", relativePath: "Library/Caches/Yarn",
              risk: .safe, detail: "Repopulated by yarn"),
        .init(name: "pip cache", relativePath: "Library/Caches/pip",
              risk: .safe, detail: "Repopulated by pip"),
        .init(name: "Gradle caches", relativePath: ".gradle/caches",
              risk: .caution, detail: "Re-downloaded on next build"),
        .init(name: "CocoaPods cache", relativePath: "Library/Caches/CocoaPods",
              risk: .safe, detail: "Repopulated by pod install"),
        .init(name: "SwiftPM cache", relativePath: "Library/Caches/org.swift.swiftpm",
              risk: .safe, detail: "Re-cloned on next package resolve"),
        .init(name: "pnpm store", relativePath: "Library/pnpm/store",
              risk: .safe, detail: "Repopulated by pnpm install"),
        .init(name: "pnpm store (legacy)", relativePath: ".pnpm-store",
              risk: .safe, detail: "Repopulated by pnpm install"),
        .init(name: "Playwright browsers", relativePath: "Library/Caches/ms-playwright",
              risk: .safe, detail: "Re-downloaded by `playwright install`"),
        .init(name: "Playwright (Go) browsers", relativePath: "Library/Caches/ms-playwright-go",
              risk: .safe, detail: "Re-downloaded by playwright-go"),
        .init(name: "Puppeteer browsers", relativePath: ".cache/puppeteer",
              risk: .safe, detail: "Re-downloaded by puppeteer on next install"),
        .init(name: "Cargo registry", relativePath: ".cargo/registry",
              risk: .safe, detail: "Crates re-downloaded on next build"),
        .init(name: "uv cache", relativePath: ".cache/uv",
              risk: .safe, detail: "Repopulated by uv"),
        .init(name: "Bun cache", relativePath: ".bun/install/cache",
              risk: .safe, detail: "Repopulated by bun install"),
        .init(name: "Deno cache", relativePath: "Library/Caches/deno",
              risk: .safe, detail: "Repopulated by deno"),
        .init(name: "Go build cache", relativePath: "Library/Caches/go-build",
              risk: .safe, detail: "Rebuilt by the Go toolchain"),
        .init(name: "App logs", relativePath: "Library/Logs",
              risk: .safe, detail: "Apps recreate logs; past diagnostic history is lost"),
        .init(name: "Docker disk image",
              relativePath: "Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
              risk: .caution,
              detail: "Deletes all containers/images/volumes; quit Docker Desktop first. `docker system prune` is the in-place alternative"),
    ]

    /// ~/Library/Caches subdirectory names already covered by a quick spec —
    /// deep discovery must skip these so nothing is listed twice.
    private static let specCoveredCacheNames: Set<String> = [
        "Homebrew", "Yarn", "pip", "CocoaPods", "org.swift.swiftpm",
        "ms-playwright", "ms-playwright-go", "deno", "go-build",
    ]

    /// Absolute paths of every known reclaimable location. The orphan scan uses
    /// this to EXCLUDE them: a known cache (often CLI-owned, e.g. SwiftPM) is
    /// not an "orphan" — it has a better-labeled home in Developer Caches, and
    /// listing it twice would double-count reclaimable bytes across categories.
    static var knownReclaimablePaths: Set<String> {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Set(quickSpecs.map { home.appendingPathComponent($0.relativePath).path })
    }

    /// Scan reclaimable locations, read-only (discovers and measures, deletes
    /// nothing). Every returned URL is inside home, so `moveToTrash`'s verdict()
    /// gate keeps holding for anything the user later confirms.
    static func scanReclaimable(mode: ScanMode) -> [ScannedItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var items: [ScannedItem] = quickSpecs.compactMap { spec in
            let url = home.appendingPathComponent(spec.relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let bytes = size(of: url)
            guard bytes > 0 else { return nil }
            return ScannedItem(name: spec.name, url: url, bytes: bytes,
                               risk: spec.risk, detail: spec.detail)
        }
        // iOS device backups: one listdir of a fixed known path (no traversal),
        // one item per backup. FDA-denied root → omitted entirely, never shown as 0.
        items += scanDeviceBackups(home: home)

        if mode == .deep {
            let discovered = discoverLargeAppCaches(home: home)
                + discoverSimulatorDevices(home: home)
                + discoverXcodeArchives(home: home)
                + discoverNodeModules(home: home)
            for item in discovered {
                // Global dedupe: drop anything equal to or inside an emitted item.
                let covered = items.contains {
                    item.url.path == $0.url.path || item.url.path.hasPrefix($0.url.path + "/")
                }
                if !covered { items.append(item) }
            }
        }
        return items.sorted { $0.bytes > $1.bytes }
    }

    /// Compatibility wrapper — the historical name now means a quick scan.
    static func scanDeveloperCaches() -> [ScannedItem] { scanReclaimable(mode: .quick) }

    // MARK: Quick — iOS device backups (fixed path, one listdir)

    private static func scanDeviceBackups(home: URL) -> [ScannedItem] {
        let root = home.appendingPathComponent("Library/Application Support/MobileSync/Backup")
        guard let backups = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: []) else { return [] }
        return backups.compactMap { dir in
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            let bytes = size(of: dir)
            guard bytes > 0 else { return nil }
            var name = "iOS backup"
            var dateSuffix = ""
            let infoPlist = dir.appendingPathComponent("Info.plist")
            if let data = try? Data(contentsOf: infoPlist),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                if let device = plist["Display Name"] as? String ?? plist["Device Name"] as? String {
                    name = "iOS backup — \(device)"
                }
                if let date = plist["Last Backup Date"] as? Date {
                    dateSuffix = " (last backed up \(date.formatted(date: .abbreviated, time: .omitted)))"
                }
            }
            return ScannedItem(
                name: name, url: dir, bytes: bytes, risk: .caution,
                detail: "That device can only be restored from a newer backup" + dateSuffix)
        }
    }

    // MARK: Deep — bounded, read-only discovery (symlink-skipping, cancellable)

    /// One listdir of ~/Library/Caches; each subdirectory ≥ 100 MB becomes its own
    /// `.safe` item. Spec-covered names are skipped (deduped); permission-denied
    /// subdirectories are skipped via `rootDenied`, never shown as 0.
    private static func discoverLargeAppCaches(home: URL) -> [ScannedItem] {
        let root = home.appendingPathComponent("Library/Caches")
        let threshold: Int64 = 100_000_000
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])
        else { return [] }
        var found: [ScannedItem] = []
        for child in children {
            if Task.isCancelled { break }
            if specCoveredCacheNames.contains(child.lastPathComponent) { continue }
            let v = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard v?.isDirectory == true, v?.isSymbolicLink != true else { continue }
            let report = sizeReport(of: child)
            guard !report.rootDenied, report.bytes >= threshold else { continue }
            found.append(ScannedItem(
                name: "Cache — \(child.lastPathComponent)", url: child, bytes: report.bytes,
                risk: .safe, detail: "Apps rebuild caches on next launch"))
        }
        return found
    }

    /// Per-device simulator data dirs (the single biggest reclaim on dev machines).
    /// Reads each device.plist directly (no xcrun dependency); booted devices
    /// (state == 3) are skipped. Always per-device items, never one bulk row.
    private static func discoverSimulatorDevices(home: URL) -> [ScannedItem] {
        let root = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices")
        guard let devices = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return [] }
        var found: [ScannedItem] = []
        for dir in devices {
            if Task.isCancelled { break }
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("device.plist")),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { continue }
            if (plist["state"] as? Int) == 3 { continue } // booted — leave it alone
            let name = plist["name"] as? String ?? dir.lastPathComponent
            let bytes = size(of: dir)
            guard bytes > 0 else { continue }
            found.append(ScannedItem(
                name: "Simulator — \(name)", url: dir, bytes: bytes, risk: .caution,
                detail: "Removes that simulator's apps and data; Xcode recreates devices on demand. Quit Simulator first."))
        }
        return found
    }

    /// One item per dated Xcode archive folder.
    private static func discoverXcodeArchives(home: URL) -> [ScannedItem] {
        let root = home.appendingPathComponent("Library/Developer/Xcode/Archives")
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return [] }
        var found: [ScannedItem] = []
        for dir in folders {
            if Task.isCancelled { break }
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let bytes = size(of: dir)
            guard bytes > 0 else { continue }
            found.append(ScannedItem(
                name: "Xcode archives — \(dir.lastPathComponent)", url: dir, bytes: bytes, risk: .caution,
                detail: "Contains dSYMs needed to symbolicate shipped builds"))
        }
        return found
    }

    /// Bounded walk (maxDepth 4) of common project roots for node_modules dirs.
    /// Read-only, prunes into found node_modules, skips hidden dirs, symlinks,
    /// and mount points. `.caution`: the project won't build until reinstalled.
    private static func discoverNodeModules(home: URL) -> [ScannedItem] {
        let roots = ["Downloads", "Documents", "Desktop"].map(home.appendingPathComponent)
        var found: [ScannedItem] = []

        func walk(_ dir: URL, depth: Int) {
            if Task.isCancelled || depth > 4 { return }
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isVolumeKey,
                                             .contentModificationDateKey]
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
            else { return }
            for child in children {
                if Task.isCancelled { return }
                let v = try? child.resourceValues(forKeys: keys)
                guard v?.isDirectory == true, v?.isSymbolicLink != true, v?.isVolume != true else { continue }
                if child.lastPathComponent == "node_modules" {
                    let bytes = size(of: child)
                    guard bytes > 0 else { continue }
                    let project = child.deletingLastPathComponent()
                    let modified = (try? project.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate
                    let when = modified.map { " Project last modified \($0.formatted(date: .abbreviated, time: .omitted))." } ?? ""
                    found.append(ScannedItem(
                        name: "node_modules — \(project.lastPathComponent)", url: child, bytes: bytes,
                        risk: .caution,
                        detail: "Restored by npm/pnpm install; project won't build until reinstalled." + when))
                    continue // prune: never descend into a found node_modules
                }
                walk(child, depth: depth + 1)
            }
        }
        for root in roots { walk(root, depth: 1) }
        return found
    }
}
