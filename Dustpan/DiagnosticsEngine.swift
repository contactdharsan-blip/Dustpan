import Foundation

// A5 — "why is this huge" diagnostics for the libraries users report as
// mysteriously enormous (Photos, Mail) on every Mac forum. REPORT-ONLY by
// design: these are macOS-managed, database-backed stores — deleting files
// inside them corrupts the database. We measure honestly, explain why each
// grows, and point at the Apple-blessed fix. Dustpan never offers to
// clean them, and no other surface lists their contents either (the Large
// Files deep scan already skips managed libraries).
//
// Foundation-only (no SwiftUI), like SnapshotEngine — testable standalone.

/// One diagnosed library. `report` keeps the honest sizing semantics:
/// rootDenied → the view shows "—" + a permission affordance, never a fake 0.
struct MediaDiagnostic: Identifiable {
    let id: String
    let name: String
    let systemImage: String
    let url: URL
    let report: SizeReport
    let explanation: String   // why it gets huge
    let blessedFix: String    // the Apple-supported way to shrink it

    var sizeText: String {
        if report.rootDenied { return "—" }
        let formatted = ByteCountFormatter.string(fromByteCount: report.bytes, countStyle: .file)
        return report.deniedCount > 0 ? "≥ " + formatted : formatted
    }
}

enum DiagnosticsEngine {

    /// Measure the Photos and Mail stores. Read-only; missing stores are
    /// omitted (an absent library is not a 0-byte library).
    static func photosMailDiagnostics() -> [MediaDiagnostic] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var found: [MediaDiagnostic] = []

        // Photos libraries: every .photoslibrary bundle at the top of ~/Pictures.
        // (The default location; a library moved elsewhere simply isn't listed —
        // we don't walk the whole disk hunting for one.)
        let pictures = home.appendingPathComponent("Pictures")
        if let children = try? FileManager.default.contentsOfDirectory(
            at: pictures, includingPropertiesForKeys: nil, options: []) {
            for child in children where child.pathExtension == "photoslibrary" {
                found.append(MediaDiagnostic(
                    id: "photos-\(child.lastPathComponent)",
                    name: "Photos library — \(child.deletingPathExtension().lastPathComponent)",
                    systemImage: "photo.on.rectangle",
                    url: child,
                    report: SafeDeleteEngine.sizeReport(of: child),
                    explanation: "Holds originals, edit derivatives, and thumbnails. With iCloud Photos it can keep full-size originals locally even when set to optimize — items that haven't finished uploading can't be offloaded.",
                    blessedFix: "Photos → Settings → iCloud → Optimize Mac Storage, then leave Photos open until syncing finishes. Never delete files inside the library bundle."))
            }
        }

        // The Mail message store: full offline copies of every IMAP account.
        let mail = home.appendingPathComponent("Library/Mail")
        if FileManager.default.fileExists(atPath: mail.path) {
            found.append(MediaDiagnostic(
                id: "mail-store",
                name: "Mail message store",
                systemImage: "envelope",
                url: mail,
                report: SafeDeleteEngine.sizeReport(of: mail),
                explanation: "Mail keeps a complete offline copy of every account — decades of messages and attachments add up.",
                blessedFix: "Mail → Settings → Accounts → Account Information → Download Attachments: “Recent” or “None”. Re-adding an account re-syncs it fresh."))
        }

        // Mail Downloads — the classic forum complaint (50+ GB reports): every
        // attachment ever opened or quick-looked gets copied here and kept.
        let mailDownloads = home.appendingPathComponent(
            "Library/Containers/com.apple.mail/Data/Library/Mail Downloads")
        if FileManager.default.fileExists(atPath: mailDownloads.path) {
            found.append(MediaDiagnostic(
                id: "mail-downloads",
                name: "Mail Downloads (opened attachments)",
                systemImage: "paperclip",
                url: mailDownloads,
                report: SafeDeleteEngine.sizeReport(of: mailDownloads),
                explanation: "Every attachment you open or Quick Look from Mail is copied here — and never cleaned up. The originals stay safely inside the message store above.",
                blessedFix: "Quit Mail, then delete the folder's contents in Finder — macOS and Mail recreate what they need. Dustpan leaves this to you: it sits inside Mail's own container."))
        }

        return found.sorted { $0.report.bytes > $1.report.bytes }
    }
}
