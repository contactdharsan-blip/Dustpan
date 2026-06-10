import Foundation

// Phase 1.3 — the large-file finder. Read-only analysis: it surfaces files,
// the user decides. Everything is Caution (nothing pre-selected) because a
// large file is by definition the user's own data, not a rebuildable cache.
// Photos/Mail libraries are skipped entirely — macOS manages those; deleting
// from inside them corrupts databases (the mode caption says so in the UI).

enum LargeFileEngine {

    static let threshold: Int64 = 100_000_000 // 100 MB

    /// Quick = the folders where big files actually accumulate.
    /// Deep  = the whole home directory, minus ~/Library (other features own it)
    ///         and managed libraries/bundles.
    static func scan(mode: SafeDeleteEngine.ScanMode) -> [ScannedItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots: [URL]
        switch mode {
        case .quick:
            roots = ["Downloads", "Desktop", "Documents", "Movies", "Music"]
                .map(home.appendingPathComponent)
        case .deep:
            // Whole home, except ~/Library: caches/leftovers are other features'
            // jobs, and listing the same bytes twice would double-count reclaim.
            roots = (try? FileManager.default.contentsOfDirectory(
                at: home, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]))?
                .filter { $0.lastPathComponent != "Library" } ?? []
        }

        var items: [ScannedItem] = []
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                                         .isVolumeKey, .isPackageKey, .totalFileAllocatedSizeKey,
                                         .fileAllocatedSizeKey]
        // Bundles/libraries macOS manages — never descend, never list contents.
        let managedExtensions: Set<String> = ["photoslibrary", "musiclibrary", "tvlibrary",
                                              "aplibrary", "migratedphotolibrary", "app"]

        for root in roots {
            guard let en = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in true }) // unreadable subtree → skip, keep walking
            else { continue }

            var visited = 0
            for case let url as URL in en {
                visited += 1
                if visited % 2048 == 0 && Task.isCancelled { return items.sorted { $0.bytes > $1.bytes } }
                guard let v = try? url.resourceValues(forKeys: keys) else { continue }
                if v.isSymbolicLink == true { if v.isDirectory == true { en.skipDescendants() }; continue }
                if v.isVolume == true { en.skipDescendants(); continue }
                if managedExtensions.contains(url.pathExtension.lowercased()) || v.isPackage == true {
                    en.skipDescendants()
                    continue // managed by macOS / an app bundle — not a "file you forgot"
                }
                guard v.isRegularFile == true else { continue }
                let bytes = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                guard bytes >= threshold else { continue }
                items.append(ScannedItem(
                    name: url.lastPathComponent, url: url, bytes: bytes, risk: .caution,
                    detail: "Your file — you decide." + UninstallEngine.provenance(of: url)))
            }
        }
        return items.sorted { $0.bytes > $1.bytes }
    }
}
