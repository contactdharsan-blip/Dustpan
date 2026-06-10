import Foundation
import AppKit // NSWorkspace/NSRunningApplication for the running-app guard + icons

// Phase 1.1 + 1.2 — one engine, two directions.
//   Uninstall: given an app, find every file it left in ~/Library.
//   Orphans:   given ~/Library, find files whose app is already gone.
// Matching policy (locked 2026-06-10): exact bundle-ID match = Safe;
// exact app-NAME folder match = Caution (shown, never pre-selected);
// NO substring/fuzzy matching in v1.0 — Pearcleaner's false positives
// came from fuzzy matching, and one false positive is fatal for trust.

/// An installed application (top level of /Applications or ~/Applications).
struct InstalledApp: Identifiable, Hashable {
    let id: String          // url.path — stable across rescans
    let name: String        // display name without ".app"
    let bundleID: String?   // nil for malformed bundles (still listed, honestly)
    let url: URL
    let lastUsed: Date?     // content access date of the bundle — a hint, not truth
    let isAppStore: Bool    // has Contents/_MASReceipt/receipt — installed by the App Store
    /// Bundle owned by root (App Store / root installer): trashing it is
    /// delegated to Finder, which shows the macOS admin-authorization popup —
    /// Cleanitup itself never holds elevated rights or sees the password.
    let needsAdminToDelete: Bool

    var isInUserApplications: Bool { url.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path) }
}

enum UninstallEngine {

    /// The ~/Library roots where macOS apps leave per-app files. Each entry
    /// declares HOW children map back to an app: by bundle ID or by app name.
    /// Group Containers is deliberately absent in v1.0 — its "{TEAMID}.group"
    /// names can't be mapped to a bundle ID without guessing.
    private struct LeftoverRoot {
        let relativePath: String
        let kind: Kind
        enum Kind {
            case bundleIDDirectory      // child directory named exactly the bundle ID
            case bundleIDPlist          // "{bundleID}.plist"
            case bundleIDSavedState     // "{bundleID}.savedState"
            case bundleIDCookies        // "{bundleID}.binarycookies"
            case appNameDirectory       // child directory named exactly the app name (Caution tier)
        }
    }

    private static let leftoverRoots: [LeftoverRoot] = [
        .init(relativePath: "Library/Application Support", kind: .bundleIDDirectory),
        .init(relativePath: "Library/Application Support", kind: .appNameDirectory),
        .init(relativePath: "Library/Caches", kind: .bundleIDDirectory),
        .init(relativePath: "Library/Containers", kind: .bundleIDDirectory),
        .init(relativePath: "Library/HTTPStorages", kind: .bundleIDDirectory),
        .init(relativePath: "Library/WebKit", kind: .bundleIDDirectory),
        .init(relativePath: "Library/Logs", kind: .appNameDirectory),
        .init(relativePath: "Library/Preferences", kind: .bundleIDPlist),
        .init(relativePath: "Library/Saved Application State", kind: .bundleIDSavedState),
        .init(relativePath: "Library/Cookies", kind: .bundleIDCookies),
    ]

    // MARK: Installed apps (read-only)

    /// Top-level .app bundles in /Applications and ~/Applications. One listdir
    /// each, no recursion — subfolders (e.g. /Applications/Utilities) hold
    /// Apple-managed apps we have no business uninstalling in v1.0.
    static func listInstalledApps() -> [InstalledApp] {
        let fm = FileManager.default
        let roots = [URL(fileURLWithPath: "/Applications"),
                     fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        var apps: [InstalledApp] = []
        for root in roots {
            guard let children = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.contentAccessDateKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]) else { continue }
            for url in children where url.pathExtension == "app" {
                if Task.isCancelled { return apps }
                let values = try? url.resourceValues(forKeys: [.contentAccessDateKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { continue } // links (e.g. brew) — not the real bundle
                let receipt = url.appendingPathComponent("Contents/_MASReceipt/receipt")
                apps.append(InstalledApp(
                    id: url.path,
                    name: url.deletingPathExtension().lastPathComponent,
                    bundleID: Bundle(url: url)?.bundleIdentifier,
                    url: url,
                    lastUsed: values?.contentAccessDate,
                    isAppStore: fm.fileExists(atPath: receipt.path),
                    needsAdminToDelete: SafeDeleteEngine.ownedByAnotherUser(url.path)))
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Bundle IDs of running apps — the UI refuses to uninstall these.
    static func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    // MARK: 1.1 Leftovers for one app (read-only)

    /// Everything the app left in ~/Library, plus the bundle itself (first item).
    /// Exact matches only; every item carries provenance (A4) in its detail.
    static func findUninstallItems(for app: InstalledApp) -> [ScannedItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var items: [ScannedItem] = []

        // The bundle itself — Safe: the user explicitly chose this app. Root-owned
        // bundles (App Store / root installer) are offered too: the engine
        // delegates those to Finder, which asks for admin authorization in-app.
        let bundleBytes = SafeDeleteEngine.size(of: app.url)
        let adminNote = app.needsAdminToDelete
            ? " macOS will ask for admin authorization when it moves to Trash."
            : ""
        items.append(ScannedItem(
            name: "\(app.name).app", url: app.url, bytes: bundleBytes, risk: .safe,
            detail: "The application bundle itself." + adminNote + provenance(of: app.url)))

        for root in leftoverRoots {
            if Task.isCancelled { break }
            let rootURL = home.appendingPathComponent(root.relativePath)
            for match in matches(in: rootURL, kind: root.kind, bundleID: app.bundleID, appName: app.name) {
                let bytes = SafeDeleteEngine.size(of: match.url)
                // Zero-byte plists are still real leftovers; only skip true misses.
                guard FileManager.default.fileExists(atPath: match.url.path) else { continue }
                items.append(ScannedItem(
                    name: "\(root.relativePath.replacingOccurrences(of: "Library/", with: "")) — \(match.url.lastPathComponent)",
                    url: match.url, bytes: bytes, risk: match.risk,
                    detail: match.reason + provenance(of: match.url)))
            }
        }
        // LaunchAgents: plists whose filename starts with the bundle ID
        // (helpers append suffixes: com.foo.app.helper.plist). Caution — a
        // launch agent the user may have configured deliberately.
        if let bundleID = app.bundleID {
            let agents = home.appendingPathComponent("Library/LaunchAgents")
            if let plists = try? FileManager.default.contentsOfDirectory(
                at: agents, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for plist in plists where plist.lastPathComponent.hasPrefix(bundleID) {
                    items.append(ScannedItem(
                        name: "LaunchAgents — \(plist.lastPathComponent)",
                        url: plist, bytes: SafeDeleteEngine.size(of: plist), risk: .caution,
                        detail: "Launch agent registered by the app." + provenance(of: plist)))
                }
            }
        }
        return items
    }

    private struct Match { let url: URL; let risk: CleanRisk; let reason: String }

    private static func matches(in root: URL, kind: LeftoverRoot.Kind,
                                bundleID: String?, appName: String) -> [Match] {
        switch kind {
        case .bundleIDDirectory:
            guard let id = bundleID else { return [] }
            return [Match(url: root.appendingPathComponent(id), risk: .safe,
                          reason: "Exact bundle-ID match (\(id)).")]
        case .bundleIDPlist:
            guard let id = bundleID else { return [] }
            return [Match(url: root.appendingPathComponent("\(id).plist"), risk: .safe,
                          reason: "Preference file — exact bundle-ID match.")]
        case .bundleIDSavedState:
            guard let id = bundleID else { return [] }
            return [Match(url: root.appendingPathComponent("\(id).savedState"), risk: .safe,
                          reason: "Window restore state — exact bundle-ID match.")]
        case .bundleIDCookies:
            guard let id = bundleID else { return [] }
            return [Match(url: root.appendingPathComponent("\(id).binarycookies"), risk: .safe,
                          reason: "Cookie store — exact bundle-ID match.")]
        case .appNameDirectory:
            // Name match is the Caution tier: same folder name, but another
            // vendor's product could share it. Never pre-selected.
            return [Match(url: root.appendingPathComponent(appName), risk: .caution,
                          reason: "Folder named exactly “\(appName)” — name match, verify it belongs to this app.")]
        }
    }

    // MARK: 1.2 Orphan scan (read-only)

    /// Files in ~/Library that look app-owned (reverse-DNS names) whose owning
    /// app is gone. Vendor-prefix matching: an item is an orphan only if NO
    /// installed or running app shares its first two reverse-DNS components
    /// (com.spotify.webhelper survives if com.spotify.client is installed).
    /// Everything returned is Caution — orphan inference is heuristic (D-rule:
    /// when ownership can't be proven, say so, don't guess Safe).
    static func scanOrphans() -> [ScannedItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let installed = listInstalledApps()
        var livePrefixes = Set<String>()
        for id in installed.compactMap(\.bundleID) + Array(runningBundleIDs()) {
            livePrefixes.insert(vendorPrefix(of: id))
        }

        var items: [ScannedItem] = []
        let scanRoots = ["Library/Application Support", "Library/Caches", "Library/Containers",
                         "Library/HTTPStorages", "Library/Saved Application State",
                         "Library/Preferences", "Library/LaunchAgents"]
        for rel in scanRoots {
            if Task.isCancelled { break }
            let root = home.appendingPathComponent(rel)
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles])
            else { continue }
            let knownCaches = SafeDeleteEngine.knownReclaimablePaths
            for child in children {
                if Task.isCancelled { break }
                if (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
                // Known reclaimable caches (often CLI-owned: SwiftPM, Homebrew…)
                // are Developer Caches' job — not orphans, and never double-listed.
                if knownCaches.contains(child.path) { continue }
                guard let candidate = bundleIDCandidate(from: child.lastPathComponent) else { continue }
                if candidate.hasPrefix("com.apple.") || candidate == "com.apple" { continue } // OS-owned, always
                if livePrefixes.contains(vendorPrefix(of: candidate)) { continue }
                let bytes = SafeDeleteEngine.size(of: child)
                let area = rel.replacingOccurrences(of: "Library/", with: "")
                items.append(ScannedItem(
                    name: "\(area) — \(child.lastPathComponent)",
                    url: child, bytes: bytes, risk: .caution,
                    detail: "Looks owned by “\(candidate)” — no installed app matches that vendor."
                            + provenance(of: child),
                    ownerApp: vendorPrefix(of: candidate)))
            }
        }
        return items.sorted { $0.bytes > $1.bytes }
    }

    /// "com.spotify.client.plist" → "com.spotify.client"; non-reverse-DNS names
    /// (e.g. "Google", "Adobe") return nil — the orphan scan stays out of the
    /// name-guessing business entirely.
    private static func bundleIDCandidate(from filename: String) -> String? {
        var name = filename
        for suffix in [".plist", ".savedState", ".binarycookies"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        let parts = name.split(separator: ".")
        guard parts.count >= 3 else { return nil } // need tld.vendor.product at minimum
        // First component looks like a TLD (letters, short) — filters "My App 2.0" style names.
        let tld = parts[0]
        guard tld.count <= 6, tld.allSatisfy({ $0.isLetter }) else { return nil }
        return name
    }

    /// First two reverse-DNS components: "com.spotify.client" → "com.spotify".
    private static func vendorPrefix(of bundleID: String) -> String {
        bundleID.split(separator: ".").prefix(2).joined(separator: ".")
    }

    /// "com.spotify" → "Spotify" — display title for an orphan group. Vendor
    /// level because the orphan inference itself runs at the vendor level; the
    /// raw prefix is always shown alongside so the guess stays auditable.
    static func vendorDisplayName(_ prefix: String) -> String {
        guard let vendor = prefix.split(separator: ".").last, !vendor.isEmpty else { return prefix }
        return vendor.prefix(1).uppercased() + vendor.dropFirst()
    }

    // MARK: A4 provenance

    /// " · Last modified Mar 3, 2026" — appended to item details so every
    /// preview row says when the file was last touched, not just what it is.
    static func provenance(of url: URL) -> String {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .contentAccessDateKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return "" }
        if let used = v.contentAccessDate {
            return " · Last used \(used.formatted(date: .abbreviated, time: .omitted))"
        }
        if let modified = v.contentModificationDate {
            return " · Last modified \(modified.formatted(date: .abbreviated, time: .omitted))"
        }
        return ""
    }
}
