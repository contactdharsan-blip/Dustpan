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

    static func scan() -> [ScannedItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let downloads = home.appendingPathComponent("Downloads")
        let desktop = home.appendingPathComponent("Desktop")

        var found: [(item: ScannedItem, date: Date?)] = []
        found += installers(in: downloads)
        found += captures(in: desktop)
        found += captures(in: downloads)

        // Oldest first; undatable items sink to the end rather than posing as old.
        return found
            .sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
            .map(\.item)
    }

    // MARK: Discovery (one top-level listdir each — no tree walking)

    private static func installers(in dir: URL) -> [(ScannedItem, Date?)] {
        children(of: dir)
            .filter { installerExtensions.contains($0.pathExtension.lowercased()) }
            .compactMap { url in
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

    private static func captures(in dir: URL) -> [(ScannedItem, Date?)] {
        children(of: dir)
            .filter { url in
                captureExtensions.contains(url.pathExtension.lowercased())
                    && capturePrefixes.contains { url.lastPathComponent.hasPrefix($0) }
            }
            .compactMap { url in
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

    /// Top-level regular files/bundles of one directory. A denied or missing
    /// root yields [] — the surface's empty state says "nothing found", which
    /// is honest for both (we never had a number to misreport).
    private static func children(of dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.addedToDirectoryDateKey, .creationDateKey,
                                         .contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
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
