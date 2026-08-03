import Foundation

// Everyday-clutter triage: installer images in ~/Downloads and screenshots /
// screen recordings on ~/Desktop and in ~/Downloads. Read-only discovery;
// trashing goes through SafeDeleteEngine like every other surface.
//
// AGE IS THE SIGNAL here (unlike every other scan, which sorts by size):
// results come back oldest-first, because a 14-month-old installer is obvious
// clutter while last week's might still be needed. Every item is .caution —
// these are the user's own files; nothing is ever pre-selected.
//
// Foundation-only (no SwiftUI) so it harness-tests standalone.

enum ClutterEngine {

    /// Installer/disk-image payloads people run once and keep forever.
    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip"]

    /// macOS screenshot/recording name prefixes (current and pre-Mojave).
    /// NOTE: matches the English defaults; a customized or localized capture
    /// prefix (com.apple.screencapture "name") simply isn't detected — missing
    /// a screenshot is safer than guessing at arbitrary user files.
    static let capturePrefixes = ["Screenshot ", "Screen Shot ", "Screen Recording "]
    static let captureExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "mov", "mp4"]

    /// Scan outcome carrying the same honesty signal as SafeDeleteEngine.SizeReport:
    /// `deniedRoots` are the ~/Downloads or ~/Desktop folders macOS refused outright
    /// (permission-denied), so the surface can render "—" + a permission affordance
    /// instead of an empty "nothing found". A root that simply doesn't exist is not
    /// a denial. Empty `deniedRoots` ⇒ both folders were readable.
    struct ScanResult: Equatable {
        var items: [ScannedItem] = []
        var deniedRoots: [URL] = []
    }

    static func scan() -> ScanResult {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let downloads = home.appendingPathComponent("Downloads")
        let desktop = home.appendingPathComponent("Desktop")

        // Load Protected Folders once per scan (not per file) and skip anything
        // the user hard-blocked. verdict() still gates the delete — scan-time half.
        let protected = ExclusionList.list()
        var found: [(item: ScannedItem, date: Date?)] = []
        var deniedRoots: [URL] = []
        // De-dupe denials: ~/Downloads is probed by both installers() and
        // captures(); a denied root must be reported once, not twice.
        var deniedSeen = Set<String>()
        func note(denied root: URL) {
            if deniedSeen.insert(root.path).inserted { deniedRoots.append(root) }
        }
        found += installers(in: downloads, protected: protected, onDenied: note)
        found += captures(in: desktop, protected: protected, onDenied: note)
        found += captures(in: downloads, protected: protected, onDenied: note)

        // Oldest first; undatable items sink to the end rather than posing as old.
        let items = found
            .sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
            .map(\.item)
        return ScanResult(items: items, deniedRoots: deniedRoots)
    }

    // MARK: Discovery (one top-level listdir each — no tree walking)

    private static func installers(in dir: URL, protected: [String],
                                   onDenied: (URL) -> Void) -> [(ScannedItem, Date?)] {
        if ExclusionList.isExcluded(dir, protected: protected) { return [] } // protected → skip entirely
        return children(of: dir, onDenied: onDenied)
            .filter { installerExtensions.contains($0.pathExtension.lowercased()) }
            .compactMap { url in
                if ExclusionList.isExcluded(url, protected: protected) { return nil } // protected item
                let date = bestDate(of: url)
                let item = ScannedItem(
                    name: url.lastPathComponent,
                    url: url,
                    bytes: SafeDeleteEngine.size(of: url), // .mpkg can be a directory
                    risk: .caution,
                    detail: "Installer — likely already run, re-downloadable from wherever you got it."
                        + provenance(date, verb: "Added"))
                return (item, date)
            }
    }

    private static func captures(in dir: URL, protected: [String],
                                 onDenied: (URL) -> Void) -> [(ScannedItem, Date?)] {
        if ExclusionList.isExcluded(dir, protected: protected) { return [] } // protected → skip entirely
        return children(of: dir, onDenied: onDenied)
            .filter { url in
                captureExtensions.contains(url.pathExtension.lowercased())
                    && capturePrefixes.contains { url.lastPathComponent.hasPrefix($0) }
            }
            .compactMap { url in
                if ExclusionList.isExcluded(url, protected: protected) { return nil } // protected item
                let date = bestDate(of: url)
                let isRecording = url.lastPathComponent.hasPrefix("Screen Recording ")
                let item = ScannedItem(
                    name: url.lastPathComponent,
                    url: url,
                    bytes: SafeDeleteEngine.size(of: url),
                    risk: .caution,
                    detail: (isRecording ? "Screen recording." : "Screenshot.")
                        + provenance(date, verb: "Taken"))
                return (item, date)
            }
    }

    /// Top-level regular files/bundles of one directory. A permission-denied root
    /// reports through `onDenied` (so the surface can show "—", never a fake clean
    /// empty state); a merely-missing root yields [] silently (we never had a
    /// number to misreport — "nothing found" is honest there).
    private static func children(of dir: URL, onDenied: (URL) -> Void) -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.addedToDirectoryDateKey, .creationDateKey,
                                             .contentModificationDateKey],
                options: [.skipsHiddenFiles])
        } catch {
            if SafeDeleteEngine.isPermissionError(error) { onDenied(dir) }
            return []
        }
    }

    /// When this thing appeared: date-added to its folder (closest to "when did
    /// I download/take this"), falling back to creation, then modification.
    private static func bestDate(of url: URL) -> Date? {
        let keys: Set<URLResourceKey> = [.addedToDirectoryDateKey, .creationDateKey,
                                         .contentModificationDateKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
        return v.addedToDirectoryDate ?? v.creationDate ?? v.contentModificationDate
    }

    /// A4 provenance suffix: " Taken 3 Jan 2026 (5 months ago)." — absolute date
    /// for audit, relative age for triage. Empty when genuinely undatable.
    private static func provenance(_ date: Date?, verb: String) -> String {
        guard let date else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: date, relativeTo: .now)
        return " \(verb) \(date.formatted(date: .abbreviated, time: .omitted)) (\(relative))."
    }
}
