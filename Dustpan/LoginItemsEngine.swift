import Foundation

// Phase 4.2 — login items & launch agents VIEWER. Report-only by design:
// touching launchd is OnyX-risk territory, so this release only explains.
// No disable, no delete — the surface offers no destructive affordance at all
// (same contract as Trash/snapshots/Photos/Mail).
//
// Honesty boundary: the System Settings "Login Items" pane reads the BTM
// database, which needs admin to dump (`sfltool dumpbtm`). We list what is
// readable without privileges — the three launchd folders — and the UI says
// so instead of pretending this is the whole picture.

/// One launchd job definition found on disk.
struct LoginItem: Identifiable, Hashable {
    enum Domain: String, CaseIterable {
        case userAgent = "Your login items"
        case globalAgent = "Agents for all users"
        case daemon = "Background daemons (third-party)"
    }

    let id = UUID()
    let label: String        // launchd Label, or filename when the plist is unreadable
    let plistURL: URL
    let programPath: String? // Program, or ProgramArguments[0]
    let programExists: Bool  // false ⇒ launchd points at a binary that is gone
    let domain: Domain
    let vendorInstalled: Bool // an installed or running app matches the vendor prefix
    let schedule: String     // plain-language: when does this run?
    let readable: Bool       // false ⇒ plist could not be parsed; shown, never hidden
    let provenance: String   // " · Last modified …"

    var vendorTitle: String {
        UninstallEngine.vendorDisplayName(UninstallEngine.vendorPrefix(of: label))
    }
}

enum LoginItemsEngine {

    /// The three launchd folders readable without privileges. /System is
    /// excluded on purpose: it is macOS itself, pure noise for this surface.
    static var defaultRoots: [(URL, LoginItem.Domain)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            (home.appendingPathComponent("Library/LaunchAgents"), .userAgent),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), .globalAgent),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), .daemon),
        ]
    }

    static func scan() -> [LoginItem] {
        var livePrefixes = Set<String>()
        for id in UninstallEngine.listInstalledApps().compactMap(\.bundleID)
                + Array(UninstallEngine.runningBundleIDs()) {
            livePrefixes.insert(UninstallEngine.vendorPrefix(of: id))
        }
        return scan(roots: defaultRoots, livePrefixes: livePrefixes)
    }

    /// Root-injectable for the empirical harness.
    static func scan(roots: [(URL, LoginItem.Domain)], livePrefixes: Set<String>) -> [LoginItem] {
        var items: [LoginItem] = []
        for (root, domain) in roots {
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            else { continue } // folder absent or unreadable — nothing to claim
            for url in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard url.pathExtension == "plist" else { continue }
                let filename = url.deletingPathExtension().lastPathComponent
                // Apple-placed jobs in these folders are OS-owned — out of scope
                // exactly like com.apple.* is for the orphan scan.
                if filename.hasPrefix("com.apple.") { continue }

                guard let data = try? Data(contentsOf: url),
                      let plist = (try? PropertyListSerialization.propertyList(
                          from: data, options: [], format: nil)) as? [String: Any]
                else {
                    // Unreadable ≠ invisible: an audit surface that hides what
                    // it can't parse isn't one.
                    items.append(LoginItem(
                        label: filename, plistURL: url, programPath: nil,
                        programExists: false, domain: domain, vendorInstalled: false,
                        schedule: "Could not read this file — shown so nothing is hidden.",
                        readable: false,
                        provenance: UninstallEngine.provenance(of: url)))
                    continue
                }

                let label = plist["Label"] as? String ?? filename
                let program = plist["Program"] as? String
                    ?? (plist["ProgramArguments"] as? [Any])?.first as? String
                let exists = program.map { FileManager.default.fileExists(atPath: $0) } ?? false
                items.append(LoginItem(
                    label: label, plistURL: url, programPath: program,
                    programExists: exists, domain: domain,
                    vendorInstalled: livePrefixes.contains(UninstallEngine.vendorPrefix(of: label)),
                    schedule: schedule(from: plist),
                    readable: true,
                    provenance: UninstallEngine.provenance(of: url)))
            }
        }
        return items
    }

    /// launchd keys → plain language. One line, no jargon.
    static func schedule(from plist: [String: Any]) -> String {
        var parts: [String] = []
        // KeepAlive may be Bool or a condition dictionary — both mean "relaunched".
        if let keepAlive = plist["KeepAlive"] {
            if (keepAlive as? Bool) != false { parts.append("runs continuously (relaunched if it quits)") }
        }
        if plist["RunAtLoad"] as? Bool == true { parts.append("starts at login") }
        if let interval = plist["StartInterval"] as? Int {
            parts.append("runs every \(formatInterval(interval))")
        }
        if plist["StartCalendarInterval"] != nil { parts.append("runs on a schedule") }
        if plist["WatchPaths"] != nil || plist["QueueDirectories"] != nil {
            parts.append("runs when watched files change")
        }
        if parts.isEmpty { return "Starts on demand — only when something asks for it." }
        let sentence = parts.joined(separator: ", ")
        return sentence.prefix(1).uppercased() + sentence.dropFirst() + "."
    }

    private static func formatInterval(_ seconds: Int) -> String {
        switch seconds {
        case ..<120: return "\(seconds) seconds"
        case ..<7200: return "\(seconds / 60) minutes"
        case ..<172_800: return "\(seconds / 3600) hours"
        default: return "\(seconds / 86_400) days"
        }
    }
}
