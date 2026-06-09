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

    var isAllowed: Bool { self == .allowed }
}

/// Result of attempting to Trash one item.
struct TrashOutcome: Identifiable {
    let id = UUID()
    let url: URL
    let success: Bool
    let reclaimedBytes: Int64
    let error: String?
}

enum SafeDeleteEngine {

    /// System roots we refuse outright (defense-in-depth on top of the home-only rule).
    static let blockedRoots = ["/System", "/usr", "/bin", "/sbin", "/Library",
                               "/private", "/Applications", "/opt", "/cores", "/Network"]

    // MARK: Safety gate

    /// A path is allowed ONLY if it lives inside the user's home directory and is
    /// not under any blocked system root. Symlinks are resolved first so a link
    /// can't smuggle a system path past the check.
    static func verdict(for url: URL) -> SafetyVerdict {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath().standardizedFileURL.path

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

    /// Allocated size of a file or directory tree (what actually frees on disk).
    static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]

        func bytes(_ u: URL) -> Int64 {
            let v = try? u.resourceValues(forKeys: Set(keys))
            return Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }

        if !isDir.boolValue { return bytes(url) }

        var total: Int64 = 0
        if let en = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: []) {
            for case let child as URL in en {
                let v = try? child.resourceValues(forKeys: Set(keys))
                if v?.isRegularFile == true { total += bytes(child) }
            }
        }
        return total
    }

    // MARK: Trash (the only destructive op — reversible)

    /// Move one item to the Trash. Refuses unsafe paths; never permanently deletes.
    @discardableResult
    static func moveToTrash(_ url: URL) -> TrashOutcome {
        let v = verdict(for: url)
        guard v.isAllowed else {
            return TrashOutcome(url: url, success: false, reclaimedBytes: 0,
                                error: "Refused (\(v)) — outside the safe zone")
        }
        let reclaimed = size(of: url)
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return TrashOutcome(url: url, success: true, reclaimedBytes: reclaimed, error: nil)
        } catch {
            return TrashOutcome(url: url, success: false, reclaimedBytes: 0,
                                error: error.localizedDescription)
        }
    }

    static func moveToTrash(_ urls: [URL]) -> [TrashOutcome] { urls.map(moveToTrash) }

    // MARK: Real scan — developer caches (read-only)

    private struct CacheSpec {
        let name: String, relativePath: String, risk: CleanRisk, detail: String
    }

    /// Known, genuinely-reclaimable developer cache locations. Honest risk labels:
    /// `.safe` regenerates automatically, `.caution` has a real regeneration cost.
    private static let developerCacheSpecs: [CacheSpec] = [
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
    ]

    /// Scan the known developer-cache paths that actually exist, with real sizes.
    /// Read-only: discovers and measures, deletes nothing.
    static func scanDeveloperCaches() -> [ScannedItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return developerCacheSpecs.compactMap { spec in
            let url = home.appendingPathComponent(spec.relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let bytes = size(of: url)
            guard bytes > 0 else { return nil }
            return ScannedItem(name: spec.name, url: url, bytes: bytes,
                               risk: spec.risk, detail: spec.detail)
        }
        .sorted { $0.bytes > $1.bytes }
    }
}
