import Foundation

extension Notification.Name {
    /// Broadcast after the protected list is successfully mutated (add/remove).
    /// Active scan sessions observe this to re-filter already-completed results,
    /// so a folder protected after a scan stops appearing without a rescan. Not a
    /// new global state holder — just a change signal over the existing list.
    static let protectedListDidChange = Notification.Name("DustpanProtectedListDidChange")
}

// Protected Folders — a user-managed HARD-BLOCK exclusion list. Foundation-only
// (no SwiftUI) so it unit-tests standalone with `swiftc`, mirroring the
// community cleaning-rules manifest in SafeDeleteEngine.
//
// The user picks folders (via a folder picker) that Dustpan must NEVER scan and
// NEVER offer to delete. Unlike cleaning-rules (home-relative paths the manifest
// ADDS to a read-only scan), these are ABSOLUTE folder paths the user explicitly
// chose, so absolute is correct here. They are persisted at
// ~/Library/Application Support/Dustpan/protected-paths.json.
//
// SAFETY: this list can only ADD refusals, never remove an existing block.
// SafeDeleteEngine.verdict() consults it AFTER symlink resolution and BEFORE any
// allow (the /Applications carve-out and the home-membership allow both lose to
// it), so neither GUI, CLI, nor any future caller can Trash anything inside a
// protected folder. The scan filter drops excluded items so they're never even
// offered. Defensive load (try?/never throws; absent ⇒ empty), exactly like
// userCleaningRules.

enum ExclusionList {

    /// The optional protected-paths manifest. Absent ⇒ no folders are protected.
    /// Computed like SafeDeleteEngine.cleaningRulesURL (same Dustpan dir).
    static var protectedPathsURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dustpan", isDirectory: true)
            .appendingPathComponent("protected-paths.json")
    }

    /// Normalize a path for robust, symlink-proof matching: standardize, resolve
    /// symlinks, and strip any trailing slash (so "/x/y/" and "/x/y" are equal).
    /// Mirrors the resolution verdict() applies to the candidate path, so a
    /// protected folder stored here matches the same resolved form verdict() sees.
    static func normalize(_ path: String) -> String {
        var p = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        if p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Loaded protected folders, normalized and de-duplicated. Unreadable or
    /// absent ⇒ empty; a malformed file degrades to empty, it never throws.
    /// `url` is injectable for testing. Mirrors userCleaningRules(from:).
    static func list(from url: URL = protectedPathsURL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        var seen = Set<String>()
        return raw.compactMap { entry -> String? in
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("/") else { return nil } // absolute paths only
            let n = normalize(trimmed)
            return seen.insert(n).inserted ? n : nil
        }
    }

    /// True if `url` is equal to OR inside any protected folder. The single
    /// helper verdict() and the scan filter share, so block and filter can't
    /// drift. The candidate is normalized the same way the stored paths are.
    static func isExcluded(_ url: URL, protected: [String] = list()) -> Bool {
        guard !protected.isEmpty else { return false }
        let path = normalize(url.path)
        return protected.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    // MARK: Mutators (read-modify-write the JSON, like the rules file's dir creation)

    /// Add a folder to the protected list. Read-modify-write; creates the Dustpan
    /// directory if missing (same as the cleaning-rules file). The path is
    /// normalized before storing so matching is robust. No-op if already present.
    /// THROWS if persistence fails — we never report a folder as protected when
    /// the manifest didn't actually save. On success, broadcasts the change.
    @discardableResult
    static func add(path: String, at url: URL = protectedPathsURL) throws -> [String] {
        let n = normalize(path)
        var current = list(from: url)
        if !current.contains(n) { current.append(n) }
        try write(current, to: url)
        NotificationCenter.default.post(name: .protectedListDidChange, object: nil)
        return current
    }

    /// Remove a folder from the protected list (matched after normalization).
    /// Read-modify-write; no-op if not present. THROWS if persistence fails, so
    /// the caller never shows a folder as un-protected while the manifest still
    /// blocks it. On success, broadcasts the change.
    @discardableResult
    static func remove(path: String, at url: URL = protectedPathsURL) throws -> [String] {
        let n = normalize(path)
        let current = list(from: url).filter { $0 != n }
        try write(current, to: url)
        NotificationCenter.default.post(name: .protectedListDidChange, object: nil)
        return current
    }

    /// Persist the list as a JSON array of absolute paths. Creates the Dustpan
    /// dir if missing. THROWS on any failure (dir-create, encode, write) so the
    /// mutators can surface it — a silently-dropped write would let the GUI claim
    /// a folder is protected when nothing was saved, breaking the trust promise.
    private static func write(_ paths: [String], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(paths)
        try data.write(to: url, options: .atomic)
    }
}
