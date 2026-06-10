import Foundation

// C1 — the undo journal. Foundation-only, like SafeDeleteEngine, so it can be
// unit-tested standalone. Every move-to-Trash the app performs is recorded here
// BEFORE the engine returns, with the Trash-side URL captured, so any entry can
// be restored with a plain file move while the item is still in the Trash.
// Append-only JSONL on disk: auditable with `cat`, greppable, no database.

/// One journaled action. `trashPath` is where the item landed in the Trash —
/// the restore handle. A failed trash attempt is journaled too (success=false):
/// the journal is an audit log first, an undo mechanism second.
struct JournalEntry: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var date: Date = Date()
    let name: String
    let originalPath: String
    let trashPath: String?
    let bytes: Int64
    let success: Bool
    let error: String?
    /// Which feature performed the action ("Developer Caches", "App Uninstaller"…).
    let context: String

    var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

/// Whether an entry can be restored right now, and why not when it can't.
enum RestoreState: Equatable {
    case restorable
    case alreadyRestored      // nothing in Trash, original exists again
    case trashItemGone        // Trash was emptied (or item moved) — unrecoverable here
    case originalOccupied     // something new exists at the original path
    case notRestorable        // failed action or no trash handle recorded

    var explanation: String {
        switch self {
        case .restorable:       return "Still in the Trash — can be put back"
        case .alreadyRestored:  return "Already back at its original location"
        case .trashItemGone:    return "No longer in the Trash (emptied or moved)"
        case .originalOccupied: return "Something else now exists at the original path"
        case .notRestorable:    return "Nothing was moved, so there is nothing to restore"
        }
    }
}

enum UndoJournal {

    /// ~/Library/Application Support/Cleanitup/history.jsonl — append-only.
    static var journalURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cleanitup", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.jsonl")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: Record

    /// Append entries to the journal. Failures to WRITE the journal are returned
    /// (not thrown, not swallowed) so the UI can tell the user their action
    /// happened but wasn't recorded — never the other way around.
    @discardableResult
    static func record(_ entries: [JournalEntry]) -> Bool {
        guard !entries.isEmpty else { return true }
        var blob = Data()
        for entry in entries {
            guard let line = try? encoder.encode(entry) else { return false }
            blob.append(line)
            blob.append(0x0A) // newline
        }
        let url = journalURL
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: blob)
                return true
            } catch { return false }
        }
        // First write — create the file.
        return (try? blob.write(to: url, options: .atomic)) != nil
    }

    /// Build a journal entry from a trash outcome (the engine calls this).
    static func entry(for outcome: TrashOutcome, name: String, context: String) -> JournalEntry {
        JournalEntry(name: name,
                     originalPath: outcome.url.path,
                     trashPath: outcome.trashedTo?.path,
                     bytes: outcome.reclaimedBytes,
                     success: outcome.success,
                     error: outcome.error,
                     context: context)
    }

    // MARK: Read

    /// All entries, newest first. Unparseable lines are counted, not hidden —
    /// honesty rule: never silently drop records from an audit log.
    static func load() -> (entries: [JournalEntry], unreadableLines: Int) {
        guard let data = try? Data(contentsOf: journalURL),
              let text = String(data: data, encoding: .utf8) else { return ([], 0) }
        var entries: [JournalEntry] = []
        var bad = 0
        for line in text.split(separator: "\n") where !line.isEmpty {
            if let entry = try? decoder.decode(JournalEntry.self, from: Data(line.utf8)) {
                entries.append(entry)
            } else {
                bad += 1
            }
        }
        return (entries.reversed(), bad)
    }

    // MARK: Restore

    static func restoreState(of entry: JournalEntry) -> RestoreState {
        guard entry.success, let trashPath = entry.trashPath else { return .notRestorable }
        let fm = FileManager.default
        let inTrash = fm.fileExists(atPath: trashPath)
        let atOriginal = fm.fileExists(atPath: entry.originalPath)
        switch (inTrash, atOriginal) {
        case (true, false):  return .restorable
        case (true, true):   return .originalOccupied
        case (false, true):  return .alreadyRestored
        case (false, false): return .trashItemGone
        }
    }

    /// Put an item back from the Trash to its original path. A plain move —
    /// nothing is overwritten (restoreState guards the destination first).
    static func restore(_ entry: JournalEntry) -> Result<Void, RestoreError> {
        switch restoreState(of: entry) {
        case .restorable: break
        case let state: return .failure(.notRestorable(state))
        }
        let trashURL = URL(fileURLWithPath: entry.trashPath!)
        let originalURL = URL(fileURLWithPath: entry.originalPath)
        do {
            // Re-create the parent if the cleanup removed it alongside.
            try FileManager.default.createDirectory(at: originalURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: trashURL, to: originalURL)
            return .success(())
        } catch {
            return .failure(.moveFailed(error.localizedDescription))
        }
    }

    enum RestoreError: Error, Equatable {
        case notRestorable(RestoreState)
        case moveFailed(String)

        var message: String {
            switch self {
            case .notRestorable(let state): return state.explanation
            case .moveFailed(let reason):   return reason
            }
        }
    }
}
