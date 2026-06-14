// Dustpan CLI — scriptable, feature-parity front-end over the Foundation engines.
//
// This is a THIRD presentation layer (after SwiftUI views and the test harness)
// over the exact same engines. It adds no cleaning logic of its own: every
// number comes from StatsEngine / SafeDeleteEngine / the scan engines, and the
// only mutating verbs (`trash`, `restore`) route through
// SafeDeleteEngine.moveToTrash + UndoJournal — so verdict()-gating, Trash-only
// deletion, and the audit journal hold here for free. The CLI literally cannot
// bypass them.
//
// Built via scripts/build-cli.sh (swiftc, matching the repo's harness convention).

import Foundation

// MARK: - Argument parsing

let rawArgs = Array(CommandLine.arguments.dropFirst())
let flags = Set(rawArgs.filter { $0.hasPrefix("-") })
let positional = rawArgs.filter { !$0.hasPrefix("-") }
let command = positional.first ?? "help"
let operands = Array(positional.dropFirst())

let jsonMode = flags.contains("--json")
let deepMode = flags.contains("--deep")
let assumeYes = flags.contains("--yes") || flags.contains("-y")

let DUSTPAN_VERSION = "0.1.0"

// MARK: - Output helpers

func fmt(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// In --json mode, serialize a JSON-safe value (dict/array/scalar) and exit-flush.
/// In human mode, this is a no-op — callers print rows directly.
func emitJSON(_ object: Any) {
    guard JSONSerialization.isValidJSONObject(object) else {
        FileHandle.standardError.write(Data("internal: non-JSON object\n".utf8))
        exit(2)
    }
    let data = try! JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func line(_ s: String = "") { print(s) }
func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

/// Shared JSON shape for a ScannedItem so every scan command serializes identically.
func itemDict(_ it: ScannedItem) -> [String: Any] {
    var d: [String: Any] = [
        "name": it.name,
        "path": it.url.path,
        "displayPath": it.displayPath,
        "bytes": it.bytes,
        "sizeText": it.sizeText,
        "risk": it.risk == .safe ? "safe" : "caution",
        "detail": it.detail,
    ]
    if let owner = it.ownerApp { d["ownerApp"] = owner }
    if it.suggestedKeep { d["suggestedKeep"] = true }
    return d
}

/// Human row for a ScannedItem: "  12.3 MB  [safe]     ~/path  — detail".
func printItem(_ it: ScannedItem) {
    let risk = it.risk == .safe ? "safe   " : "caution"
    let size = it.sizeText.padding(toLength: 10, withPad: " ", startingAt: 0)
    var row = "  \(size) [\(risk)] \(it.displayPath)"
    if !it.detail.isEmpty { row += "  — \(it.detail)" }
    print(row)
}

/// Print a list of items as human rows + a total footer, or a JSON envelope.
func report(title: String, items: [ScannedItem], jsonKey: String) {
    let total = items.reduce(Int64(0)) { $0 + $1.bytes }
    if jsonMode {
        emitJSON([
            jsonKey: items.map(itemDict),
            "count": items.count,
            "totalBytes": total,
            "totalText": fmt(total),
        ])
        return
    }
    line(title)
    if items.isEmpty {
        line("  (nothing found)")
    } else {
        for it in items { printItem(it) }
        line("  ─────")
        line("  \(items.count) item(s), \(fmt(total)) total")
    }
}

// MARK: - Commands

func cmdScan() {
    // Consume the same frozen AsyncStream the SwiftUI dashboard uses; break on
    // the isComplete snapshot. The semaphore is a hang-safety net only.
    let sem = DispatchSemaphore(value: 0)
    final class Box { var snap: StatsSnapshot? }
    let box = Box()
    let task = Task.detached {
        for await snap in StatsEngine.live() {
            box.snap = snap
            if snap.isComplete { break }
        }
        sem.signal()
    }
    if sem.wait(timeout: .now() + 300) == .timedOut { task.cancel() }

    guard let snap = box.snap else {
        err("scan: no snapshot produced"); exit(1)
    }

    if jsonMode {
        var out: [String: Any] = [
            "isComplete": snap.isComplete,
            "categories": snap.categories.map { u -> [String: Any] in
                var d: [String: Any] = [
                    "id": u.category.id,
                    "name": u.category.name,
                    "measured": u.isMeasured,
                    "needsPermission": u.needsPermission,
                ]
                if let b = u.bytes { d["bytes"] = b; d["sizeText"] = fmt(b) }
                return d
            },
            "reclaimable": [
                "locations": snap.cacheLocationsFound,
                "bytes": snap.reclaimableBytes,
                "text": fmt(snap.reclaimableBytes),
            ],
        ]
        if let disk = snap.disk {
            out["disk"] = [
                "totalBytes": disk.totalCapacity, "totalText": disk.totalText,
                "usedBytes": disk.used, "usedText": disk.usedText,
                "freeBytes": disk.availableForImportant, "freeText": disk.freeText,
            ]
        }
        if let score = snap.score { out["cleanlinessScore"] = score.value }
        if let un = snap.unaccountedBytes { out["unaccountedBytes"] = un }
        emitJSON(out)
        return
    }

    line("Dustpan — storage overview")
    line("")
    if let disk = snap.disk {
        line("Disk:  \(disk.usedText) used of \(disk.totalText)  ·  \(disk.freeText) free")
        if let p = disk.purgeable, p > 0 { line("       \(fmt(p)) purgeable (macOS frees on demand)") }
    } else {
        line("Disk:  — (volume capacity unavailable)")
    }
    if let score = snap.score {
        line("Cleanliness: \(score.value)/100")
    }
    line("")
    line("Categories (largest first):")
    let sorted = snap.categories.sorted { ($0.bytes ?? -1) > ($1.bytes ?? -1) }
    for u in sorted {
        let size = (u.bytes.map(fmt) ?? "—").padding(toLength: 10, withPad: " ", startingAt: 0)
        let flag = u.needsPermission ? "  (needs permission)" : ""
        line("  \(size) \(u.category.name)\(flag)")
    }
    if let un = snap.unaccountedBytes {
        line("  \(fmt(un).padding(toLength: 10, withPad: " ", startingAt: 0)) \(snap.unaccountedLabel)")
    }
    line("")
    line("Reclaimable now: \(fmt(snap.reclaimableBytes)) across \(snap.cacheLocationsFound) location(s)")
    line("  → `dustpan caches` to list them.")
}

func cmdCaches() {
    let mode: SafeDeleteEngine.ScanMode = deepMode ? .deep : .quick
    report(title: "Reclaimable caches (\(deepMode ? "deep" : "quick")):",
           items: SafeDeleteEngine.scanReclaimable(mode: mode), jsonKey: "caches")
}

func cmdDuplicates() {
    let mode: SafeDeleteEngine.ScanMode = deepMode ? .deep : .quick
    report(title: "Duplicate files (\(deepMode ? "deep" : "quick")) — byte-identical groups:",
           items: DuplicateEngine.scan(mode: mode), jsonKey: "duplicates")
}

func cmdLarge() {
    let mode: SafeDeleteEngine.ScanMode = deepMode ? .deep : .quick
    report(title: "Large files (\(deepMode ? "deep" : "quick")):",
           items: LargeFileEngine.scan(mode: mode), jsonKey: "largeFiles")
}

func cmdClutter() {
    report(title: "Installers & screenshots (oldest first):",
           items: ClutterEngine.scan(), jsonKey: "clutter")
}

func cmdOrphans() {
    report(title: "Orphaned leftovers (from already-removed apps):",
           items: UninstallEngine.scanOrphans(), jsonKey: "orphans")
}

func cmdApps() {
    let apps = UninstallEngine.listInstalledApps()
    if jsonMode {
        emitJSON([
            "apps": apps.map { a -> [String: Any] in
                var d: [String: Any] = [
                    "name": a.name, "path": a.url.path,
                    "isAppStore": a.isAppStore, "needsAdminToDelete": a.needsAdminToDelete,
                ]
                if let b = a.bundleID { d["bundleID"] = b }
                if let u = a.lastUsed { d["lastUsed"] = ISO8601DateFormatter().string(from: u) }
                return d
            },
            "count": apps.count,
        ])
        return
    }
    line("Installed apps (\(apps.count)):")
    for a in apps.sorted(by: { $0.name.lowercased() < $1.name.lowercased() }) {
        var tags: [String] = []
        if a.isAppStore { tags.append("App Store") }
        if a.needsAdminToDelete { tags.append("admin to remove") }
        let suffix = tags.isEmpty ? "" : "  [\(tags.joined(separator: ", "))]"
        line("  \(a.name)\(suffix)")
        line("      \(a.bundleID ?? "(no bundle id)")")
    }
    line("")
    line("  → orphan leftovers: `dustpan orphans`")
}

func cmdLoginItems() {
    let items = LoginItemsEngine.scan()
    if jsonMode {
        emitJSON([
            "loginItems": items.map { i -> [String: Any] in
                var d: [String: Any] = [
                    "label": i.label, "domain": i.domain.rawValue,
                    "schedule": i.schedule, "programExists": i.programExists,
                    "readable": i.readable, "vendorInstalled": i.vendorInstalled,
                    "plist": i.plistURL.path,
                ]
                if let p = i.programPath { d["program"] = p }
                return d
            },
            "count": items.count,
        ])
        return
    }
    line("Login items & background jobs (report-only):")
    if items.isEmpty { line("  (none found)"); return }
    let grouped = Dictionary(grouping: items, by: { $0.domain })
    for domain in LoginItem.Domain.allCases {
        guard let group = grouped[domain], !group.isEmpty else { continue }
        line("")
        line("  \(domain.rawValue):")
        for i in group {
            var notes: [String] = []
            if !i.programExists { notes.append("⚠ missing binary") }
            if !i.readable { notes.append("⚠ unreadable plist") }
            let note = notes.isEmpty ? "" : "  [\(notes.joined(separator: ", "))]"
            line("    • \(i.label) — \(i.schedule)\(note)")
        }
    }
}

func cmdRules() {
    let url = SafeDeleteEngine.cleaningRulesURL
    let userRules = SafeDeleteEngine.userCleaningRules()
    let effective = SafeDeleteEngine.reclaimableSpecs()
    if jsonMode {
        emitJSON([
            "manifestPath": url.path,
            "manifestExists": FileManager.default.fileExists(atPath: url.path),
            "userRuleCount": userRules.count,
            "effectiveRuleCount": effective.count,
            "userRules": userRules.map { ["name": $0.name, "path": $0.relativePath,
                                          "risk": $0.risk == .safe ? "safe" : "caution"] },
        ])
        return
    }
    line("Cleaning rules — built-in defaults plus your community manifest.")
    line("")
    line("Manifest: \(url.path)")
    line(FileManager.default.fileExists(atPath: url.path)
         ? "  (present — \(userRules.count) valid user rule(s) layered on top)"
         : "  (none yet — copy cleaning-rules.example.json there to add your own)")
    line("Effective rules: \(effective.count)  (\(effective.count - userRules.count) built-in + \(userRules.count) user)")
    if !userRules.isEmpty {
        line("")
        line("Your rules:")
        for r in userRules {
            line("  • \(r.name) — ~/\(r.relativePath)  [\(r.risk == .safe ? "safe" : "caution")]")
        }
    }
    line("")
    line("Schema: a JSON array of { name, path (home-relative), risk: \"safe\"|\"caution\", detail }.")
    line("Paths outside home or containing \"..\" are rejected; every delete still passes the safety gate.")
}

func cmdDocker() {
    let images = DockerReclaimEngine.scan()
    if jsonMode {
        emitJSON([
            "vmImages": images.map { v -> [String: Any] in
                [
                    "runtime": v.runtime, "path": v.url.path,
                    "onDiskBytes": v.onDiskBytes, "onDiskText": v.onDiskText,
                    "apparentBytes": v.apparentBytes, "apparentText": v.apparentText,
                    "sparse": v.isSparse, "denied": v.denied,
                    "blessedFix": v.blessedFix,
                ]
            },
            "count": images.count,
        ])
        return
    }
    line("Container VM disk images (report-only — pruning won't shrink these):")
    if images.isEmpty {
        line("  (no Docker/colima/Podman VM image in the default locations)")
        return
    }
    for v in images {
        line("  • \(v.runtime): \(v.onDiskText) on disk  (of \(v.apparentText) max)\(v.isSparse ? "  ⚠ has dead space — won't auto-shrink" : "")")
        line("      \(v.url.path)")
        line("      fix: \(v.blessedFix)")
    }
}

func cmdSnapshots() {
    let r = SnapshotEngine.listLocalSnapshots()
    if jsonMode {
        emitJSON([
            "toolUnavailable": r.toolUnavailable,
            "snapshots": r.snapshots.map { ["name": $0.name, "age": $0.ageText] },
            "count": r.snapshots.count,
        ])
        return
    }
    if r.toolUnavailable { line("Time Machine snapshots: tmutil unavailable — cannot report."); return }
    line("Local Time Machine snapshots (report-only — sizes not knowable without privileged API):")
    if r.snapshots.isEmpty { line("  (none — macOS prunes these automatically; healthy)"); return }
    for s in r.snapshots { line("  • \(s.dateText)  (\(s.ageText))") }
}

func cmdHistory() {
    let (entries, unreadable) = UndoJournal.load()
    if jsonMode {
        emitJSON([
            "history": entries.map { e -> [String: Any] in
                [
                    "id": e.id.uuidString, "name": e.name,
                    "originalPath": e.originalPath, "bytes": e.bytes,
                    "success": e.success, "context": e.context,
                    "date": ISO8601DateFormatter().string(from: e.date),
                    "restoreState": String(describing: UndoJournal.restoreState(of: e)),
                ]
            },
            "count": entries.count,
            "unreadableLines": unreadable,
        ])
        return
    }
    line("Deletion history (Trash audit journal):")
    if entries.isEmpty { line("  (empty — nothing has been trashed)"); return }
    for e in entries.reversed() {
        let state = UndoJournal.restoreState(of: e)
        let mark = e.success ? "✓" : "✗"
        line("  \(mark) \(e.sizeText.padding(toLength: 10, withPad: " ", startingAt: 0)) \(e.name)  [\(e.context)]")
        line("      \(e.id.uuidString)  — \(state.explanation)")
    }
    if unreadable > 0 { line("  (\(unreadable) journal line(s) were unreadable and skipped)") }
}

func cmdTrash() {
    guard !operands.isEmpty else {
        err("usage: dustpan trash <path>... [--yes]"); exit(2)
    }
    let urls = operands.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }

    // Show verdicts first — the CLI mirrors the GUI's preview-before-delete rule.
    var allowed: [URL] = []
    line("The following will be moved to the Trash (reversible):")
    for u in urls {
        let v = SafeDeleteEngine.verdict(for: u)
        if v.isAllowed || v == .blockedNeedsAdmin {
            let size = fmt(SafeDeleteEngine.size(of: u))
            let note = v == .blockedNeedsAdmin ? "  (macOS will ask for admin authorization)" : ""
            line("  • \(size.padding(toLength: 10, withPad: " ", startingAt: 0)) \(u.path)\(note)")
            allowed.append(u)
        } else {
            line("  ✗ REFUSED \(u.path)  — \(v)")
        }
    }
    guard !allowed.isEmpty else { err("Nothing eligible to trash."); exit(1) }

    if !assumeYes {
        FileHandle.standardOutput.write(Data("Proceed? [y/N] ".utf8))
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        guard answer == "y" || answer == "yes" else { line("Aborted."); exit(0) }
    }

    let outcomes = SafeDeleteEngine.moveToTrash(allowed, context: "CLI")
    var reclaimed: Int64 = 0
    for o in outcomes {
        if o.success { reclaimed += o.reclaimedBytes; line("  ✓ trashed \(o.url.lastPathComponent)") }
        else { line("  ✗ \(o.url.lastPathComponent): \(o.error ?? "failed")") }
    }
    line("Reclaimed \(fmt(reclaimed)) → Trash. `dustpan history` to review or restore.")
}

func cmdRestore() {
    guard let idStr = operands.first, let uuid = UUID(uuidString: idStr) else {
        err("usage: dustpan restore <entry-id>   (get ids from `dustpan history`)"); exit(2)
    }
    let (entries, _) = UndoJournal.load()
    guard let entry = entries.first(where: { $0.id == uuid }) else {
        err("No history entry with id \(idStr)."); exit(1)
    }
    switch UndoJournal.restore(entry) {
    case .success:
        line("Restored \(entry.name) → \(entry.originalPath)")
    case .failure(let e):
        err("Could not restore: \(e)"); exit(1)
    }
}

func cmdHelp() {
    line("""
    dustpan \(DUSTPAN_VERSION) — trust-first macOS storage cleaner (CLI)

    USAGE:  dustpan <command> [--deep] [--json] [--yes]

    REPORT (read-only):
      scan            Storage overview: disk, categories, cleanliness, reclaimable
      caches          Reclaimable developer/app caches        [--deep]
      duplicates      Byte-identical duplicate file groups     [--deep]
      large           Large files                              [--deep]
      clutter         Installers & screenshots (age-sorted)
      docker          Container VM disk images (Docker/colima/Podman)
      apps            Installed applications
      orphans         Leftover files from already-removed apps
      login-items     launchd login items & background jobs
      snapshots       Local Time Machine snapshots
      history         Trash audit journal
      rules           Show cleaning rules (built-in + your community manifest)

    ACT (Trash-only, reversible, verdict()-gated + journaled):
      trash <path>... Move paths to the Trash         (--yes to skip prompt)
      restore <id>    Put a trashed item back          (id from `history`)

    GLOBAL FLAGS:
      --json   Machine-readable output (for CI/cron/scripts)
      --deep   Slower, wider discovery where a command supports it
      --yes    Skip the trash confirmation prompt

    Every number is a real measurement or an em-dash. Nothing is ever
    permanently deleted — Trash only, fully auditable, no telemetry.
    """)
}

// MARK: - Dispatch

switch command {
case "scan":               cmdScan()
case "caches":             cmdCaches()
case "duplicates", "dupes": cmdDuplicates()
case "large":              cmdLarge()
case "clutter":            cmdClutter()
case "docker":             cmdDocker()
case "rules":              cmdRules()
case "apps":               cmdApps()
case "orphans":            cmdOrphans()
case "login-items":        cmdLoginItems()
case "snapshots":          cmdSnapshots()
case "history":            cmdHistory()
case "trash":              cmdTrash()
case "restore":            cmdRestore()
case "version", "--version": line("dustpan \(DUSTPAN_VERSION)")
case "help", "--help", "-h": cmdHelp()
default:
    err("unknown command: \(command)\n"); cmdHelp(); exit(2)
}
