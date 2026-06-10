import Foundation

// A3 (Phase 2, report-only) — local Time Machine snapshot browser.
// Lists APFS local snapshots via `tmutil listlocalsnapshots /` and explains
// them. REPORT-ONLY by design: deletion/thinning is not Trash-reversible and
// ships later behind the D8 irreversible-consent tier (v1.1) — this view never
// offers an action it can't take back.
//
// Per-snapshot SIZES are deliberately "—": macOS does not expose them without
// privileged APIs, and we don't guess (em-dash rule). What we CAN say honestly:
// the snapshots exist, when they were taken, and that their space reports as
// purgeable.

/// One local APFS snapshot, parsed from a name like
/// "com.apple.TimeMachine.2026-06-10-130145.local".
struct LocalSnapshot: Identifiable, Hashable {
    let id: String      // the full snapshot name (unique per disk)
    let name: String
    let date: Date?     // nil if the name doesn't carry a parseable stamp

    var dateText: String {
        date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? name
    }
    var ageText: String {
        guard let date else { return "—" }
        let hours = Int(-date.timeIntervalSinceNow / 3600)
        if hours < 1 { return "under an hour old" }
        if hours < 24 { return "\(hours) hour\(hours == 1 ? "" : "s") old" }
        let days = hours / 24
        return "\(days) day\(days == 1 ? "" : "s") old"
    }
}

/// Result of a snapshot listing. `toolUnavailable` distinguishes "tmutil
/// failed/missing" from a genuine empty list — an error must never render as
/// a clean "no snapshots" (that would be a fake 0).
struct SnapshotReport: Equatable {
    let snapshots: [LocalSnapshot]
    let toolUnavailable: Bool
}

enum SnapshotEngine {

    /// Parse `tmutil listlocalsnapshots` output. Exposed for testing — the
    /// harness feeds synthetic output because a healthy Mac often has zero
    /// snapshots (macOS prunes them within ~24 h).
    static func parse(_ output: String) -> [LocalSnapshot] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")

        return output.split(separator: "\n")
            .map(String.init)
            .filter { $0.hasPrefix("com.apple.TimeMachine.") }
            .map { line in
                // "com.apple.TimeMachine.2026-06-10-130145.local" → stamp segment.
                let stamp = line
                    .replacingOccurrences(of: "com.apple.TimeMachine.", with: "")
                    .replacingOccurrences(of: ".local", with: "")
                return LocalSnapshot(id: line, name: line, date: formatter.date(from: stamp))
            }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// List local snapshots for the root volume. Runs `tmutil` (read-only
    /// listing needs no privileges). Never throws into the UI: failure surfaces
    /// as `toolUnavailable`, distinct from an honest empty list.
    static func listLocalSnapshots() -> SnapshotReport {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["listlocalsnapshots", "/"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // errors -> toolUnavailable, never the UI

        do {
            try process.run()
            // Bounded read THEN wait: tmutil output is tiny, but reading after
            // exit avoids any pipe-buffer deadlock shape.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8) else {
                return SnapshotReport(snapshots: [], toolUnavailable: true)
            }
            return SnapshotReport(snapshots: parse(output), toolUnavailable: false)
        } catch {
            return SnapshotReport(snapshots: [], toolUnavailable: true)
        }
    }
}
