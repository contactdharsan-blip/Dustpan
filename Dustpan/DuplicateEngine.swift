import Foundation
import CryptoKit

// Phase 4.1 — the duplicate finder. Read-only analysis pipeline:
// size-bucket → partial-hash (first+last 64 KB) → full streaming hash.
// Only full-hash-confirmed groups are ever reported, so "identical" here
// means byte-identical content, not a heuristic.
//
// Per D9 this slice ships classic Trash-delete only (reusing the hardened
// SafeDeleteEngine path); APFS clone-dedup is a later, separate mode.
// Everything is Caution — duplicates are the user's own data — and the
// newest copy in each group is flagged `suggestedKeep` so the UI can
// suggest without pre-selecting.

enum DuplicateEngine {

    /// Hashing is IO-bound; below this, duplicates reclaim too little to be
    /// worth the disk churn. The UI caption states the floor honestly.
    static let threshold: Int64 = 10_000_000 // 10 MB

    static func scan(mode: SafeDeleteEngine.ScanMode) -> [ScannedItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots: [URL]
        switch mode {
        case .quick:
            // Same folders the large-file finder calls "where big files
            // actually accumulate" — duplicates follow the same gravity.
            roots = ["Downloads", "Desktop", "Documents", "Movies", "Music"]
                .map(home.appendingPathComponent)
        case .deep:
            // Whole home except ~/Library (other features own it; caches are
            // legitimately duplicated and trashing them there is misleading).
            roots = (try? FileManager.default.contentsOfDirectory(
                at: home, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]))?
                .filter { $0.lastPathComponent != "Library" } ?? []
        }
        return scan(roots: roots)
    }

    /// Root-injectable for the empirical harness.
    static func scan(roots: [URL]) -> [ScannedItem] {
        struct Candidate {
            let url: URL
            let logicalSize: Int64   // identical content ⇒ identical logical size
            let allocatedBytes: Int64 // what trashing this copy actually frees
            let modified: Date
            let linkCount: Int       // >1 ⇒ trashing this path frees nothing yet
        }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                                         .isVolumeKey, .isPackageKey, .fileSizeKey,
                                         .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                                         .contentModificationDateKey, .fileResourceIdentifierKey,
                                         .linkCountKey]
        let managedExtensions: Set<String> = ["photoslibrary", "musiclibrary", "tvlibrary",
                                              "aplibrary", "migratedphotolibrary", "app"]

        // 1. Collect candidates, dropping hard links to an already-seen file:
        //    two paths to one inode reclaim nothing — they are not duplicates.
        var seenIdentities = Set<AnyHashable>()
        var candidates: [Candidate] = []
        for root in roots {
            guard let en = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in true }) // unreadable subtree → skip, keep walking
            else { continue }

            var visited = 0
            for case let url as URL in en {
                visited += 1
                if visited % 2048 == 0 && Task.isCancelled { return [] }
                guard let v = try? url.resourceValues(forKeys: keys) else { continue }
                if v.isSymbolicLink == true { if v.isDirectory == true { en.skipDescendants() }; continue }
                if v.isVolume == true { en.skipDescendants(); continue }
                if managedExtensions.contains(url.pathExtension.lowercased()) || v.isPackage == true {
                    en.skipDescendants()
                    continue
                }
                guard v.isRegularFile == true else { continue }
                let logical = Int64(v.fileSize ?? 0)
                guard logical >= threshold else { continue }
                if let identity = v.fileResourceIdentifier {
                    let key = AnyHashable(identity as! NSObject)
                    guard seenIdentities.insert(key).inserted else { continue } // hard link
                }
                candidates.append(Candidate(
                    url: url,
                    logicalSize: logical,
                    allocatedBytes: Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0),
                    modified: v.contentModificationDate ?? .distantPast,
                    linkCount: v.linkCount ?? 1))
            }
        }

        // 2. Size buckets — identical content can't differ in logical size.
        let sizeBuckets = Dictionary(grouping: candidates, by: \.logicalSize)
            .values.filter { $0.count > 1 }

        // 3. Partial hash (first + last 64 KB) prunes same-size-different-content
        //    cheaply. 4. Full streaming hash confirms — fixed-header formats can
        //    share head and tail while differing in the middle.
        var groups: [(hash: String, members: [Candidate])] = []
        for bucket in sizeBuckets {
            if Task.isCancelled { return [] }
            let partialBuckets = Dictionary(grouping: bucket) {
                partialHash(of: $0.url, fileSize: $0.logicalSize) ?? "unreadable-\($0.url.path)"
            }
            for (partial, sameTails) in partialBuckets where sameTails.count > 1 && !partial.hasPrefix("unreadable") {
                let confirmed = Dictionary(grouping: sameTails) {
                    fullHash(of: $0.url, expectedBytes: $0.logicalSize) ?? "unreadable-\($0.url.path)"
                }
                for (full, members) in confirmed where members.count > 1 && !full.hasPrefix("unreadable") {
                    groups.append((hash: full, members: members))
                }
            }
        }

        // 5. Emit per-group items: newest copy first and flagged suggestedKeep;
        //    ownerApp carries the content hash as the grouping key (unique even
        //    when two unrelated groups share a file name and size).
        var items: [ScannedItem] = []
        let bySize = groups.sorted {
            $0.members.reduce(Int64(0)) { $0 + $1.allocatedBytes }
                > $1.members.reduce(Int64(0)) { $0 + $1.allocatedBytes }
        }
        for group in bySize {
            let byNewest = group.members.sorted { $0.modified > $1.modified }
            guard let keeper = byNewest.first else { continue }
            for (i, member) in byNewest.enumerated() {
                // A path with other hard links frees nothing when trashed —
                // claiming its size would be a fake number. Report 0 and say why.
                let multiLinked = member.linkCount > 1
                items.append(ScannedItem(
                    name: member.url.lastPathComponent,
                    url: member.url,
                    bytes: multiLinked ? 0 : member.allocatedBytes,
                    risk: .caution,
                    detail: (i == 0
                             ? "Newest copy — suggested keep."
                             : "Byte-identical to \(keeper.url.lastPathComponent).")
                            + (multiLinked
                               ? " Has \(member.linkCount - 1) other hard link\(member.linkCount == 2 ? "" : "s") — trashing this path frees no space."
                               : "")
                            + UninstallEngine.provenance(of: member.url),
                    ownerApp: String(group.hash.prefix(16)),
                    suggestedKeep: i == 0))
            }
        }
        return items
    }

    /// SHA-256 over the first and last 64 KB. Nil when the file can't be read —
    /// callers must treat that as "not a duplicate", never as a match.
    static func partialHash(of url: URL, fileSize: Int64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let chunk = 65_536
        var hasher = SHA256()
        guard let head = try? handle.read(upToCount: chunk) else { return nil }
        hasher.update(data: head)
        if fileSize > Int64(chunk) {
            let tailOffset = max(Int64(chunk), fileSize - Int64(chunk))
            guard (try? handle.seek(toOffset: UInt64(tailOffset))) != nil,
                  let tail = try? handle.read(upToCount: chunk) else { return nil }
            hasher.update(data: tail)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Full streaming SHA-256, 4 MB chunks, cancellation-polled — multi-GB
    /// files must not pin a cancelled scan to the disk. read(upToCount:)
    /// returns nil at EOF but THROWS on real errors; only the throw may
    /// poison the hash — a silently truncated hash could manufacture a
    /// false duplicate. `expectedBytes` guards against files mutating
    /// mid-scan: a size mismatch means the content we hashed is stale.
    static func fullHash(of url: URL, expectedBytes: Int64? = nil) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            if Task.isCancelled { return nil }
            do {
                guard let data = try handle.read(upToCount: 4_194_304), !data.isEmpty else { break }
                hasher.update(data: data)
                total += Int64(data.count)
            } catch { return nil } // real read error — never allowed to match
        }
        if let expected = expectedBytes, total != expected { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
