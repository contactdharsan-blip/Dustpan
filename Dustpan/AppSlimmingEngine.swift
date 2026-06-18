import Foundation

// v1.1 — app "slimming": reclaim space by Trashing UNUSED localization
// resources (Contents/Resources/<lang>.lproj) from a .app bundle.
//
// WHY this is honest and safe:
//   • A Mac ships dozens of UI translations per app you will never read. The
//     ones for languages you don't use are dead weight on disk. We measure
//     exactly what each removable .lproj costs (allocated bytes, denial-aware)
//     and only ever propose Trashing the ones whose language you don't keep.
//   • "When unsure, KEEP." Deleting a language the app actually renders breaks
//     its UI, so the kept set is deliberately generous: Base + en/English +
//     every preferred language AND its primary subtag. We would rather leave a
//     few megabytes than blank a menu.
//   • We touch ONLY the main bundle's Contents/Resources/*.lproj. We never
//     recurse into nested .framework/.app/helper bundles — their localizations
//     are the framework's business, and walking them invites accidents.
//   • TRADEOFF the user must own: removing localizations BREAKS the bundle's
//     code signature seal (the on-disk contents no longer match the sealed
//     manifest). The app still runs, but `codesign --verify` will fail and a
//     future Apple-signed update may refuse to patch it and re-download whole.
//     We say so; we don't pretend the change is invisible.
//   • The gate is the single source of truth: `actionable` is derived straight
//     from SafeDeleteEngine.verdict(), and slim() routes every removal through
//     moveToTrash() — so a /Applications bundle (verdict .blockedSystemPath)
//     is refused identically whether reached from the GUI, the CLI, or here.
//     Home-scoped (~/Applications) bundles are allowed.
//
// Foundation-only (no SwiftUI), like DockerReclaimEngine — testable standalone
// via swiftc + a main.swift of assertions, and it auto-joins the Xcode target.

/// One app we could slim. `reclaimableBytes` is the summed on-disk cost of the
/// removable .lproj only (kept languages excluded). `denied` means
/// Contents/Resources was unreadable — render "—", never a fabricated 0.
/// `actionable` reflects whether verdict() would actually let us Trash them.
struct SlimmableApp: Identifiable {
    let id: String              // bundle path (stable id)
    let name: String            // bundle filename minus ".app"
    let url: URL                // the .app bundle
    let reclaimableBytes: Int64 // sum of removable .lproj on-disk size
    let removable: [URL]        // the .lproj dirs we would Trash (kept langs excluded)
    let totalLproj: Int         // how many .lproj exist in Contents/Resources (context)
    let denied: Bool            // Contents/Resources unreadable -> render "—", never fake 0
    let actionable: Bool        // verdict() ALLOWS Trashing them (true only for home-scoped bundles)

    /// Reclaimable size, or "—" when Resources was unreadable.
    var reclaimableText: String {
        denied ? "—" : ByteCountFormatter.string(fromByteCount: reclaimableBytes, countStyle: .file)
    }
}

enum AppSlimmingEngine {

    /// Where third-party apps live. We scan both the system-wide /Applications
    /// (report-only — verdict blocks it) and the user's ~/Applications
    /// (actionable). Missing locations are skipped, not invented as empty.
    static var defaultLocations: [URL] {
        let fm = FileManager.default
        let candidates = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
        return candidates.filter { fm.fileExists(atPath: $0.path) }
    }

    /// The languages we KEEP (never remove). Deliberately generous — "when
    /// unsure, KEEP". Always includes Base + en/English; plus every preferred
    /// language tag and its primary subtag (e.g. "en-US" → also "en";
    /// "zh-Hans" → "zh-Hans" and "zh"). Stored lowercased for case-insensitive
    /// comparison against an .lproj stem.
    static func keptLanguages(preferred: [String] = Locale.preferredLanguages) -> Set<String> {
        var kept: Set<String> = ["base", "en", "english"]
        for tag in preferred {
            let lower = tag.lowercased()
            guard !lower.isEmpty else { continue }
            kept.insert(lower)
            // Primary subtag: the segment before the first "-" (e.g. en-US → en,
            // zh-Hans → zh). Keep it too so a region/script variant never strands
            // the base language as "removable".
            if let dash = lower.firstIndex(of: "-") {
                let primary = String(lower[lower.startIndex..<dash])
                if !primary.isEmpty { kept.insert(primary) }
            }
        }
        return kept
    }

    /// Inspect ONE bundle's Contents/Resources and report what could be slimmed.
    /// Pure and side-effect free (just reads + sizes) so the harness can drive
    /// it deterministically. An unreadable Resources dir ⇒ denied ("—"), never 0.
    static func report(bundle: URL, kept: Set<String>) -> SlimmableApp {
        let fm = FileManager.default
        let resources = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
        let name = bundle.deletingPathExtension().lastPathComponent
        let id = bundle.path

        // Read only the immediate children of Resources — NEVER recurse into
        // nested bundles. A read failure on an existing Resources dir is denial.
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil, options: [])
        } catch {
            let denied = SafeDeleteEngine.isPermissionError(error)
            // No Resources dir at all (not a denial) ⇒ nothing to slim, not denied.
            return SlimmableApp(id: id, name: name, url: bundle,
                                reclaimableBytes: 0, removable: [], totalLproj: 0,
                                denied: denied, actionable: false)
        }

        let lprojs = entries.filter { $0.pathExtension == "lproj" }
        // Removable = its stem (filename minus ".lproj") is NOT a kept language.
        let removable = lprojs.filter { url in
            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            return !kept.contains(stem)
        }

        let reclaimableBytes = removable.reduce(Int64(0)) { $0 + SafeDeleteEngine.size(of: $1) }

        // SINGLE source of truth for "can we act": the gate. actionable only when
        // we have something to remove AND verdict() allows Trashing it. This is
        // the same verdict() the GUI/CLI consult, so they cannot drift.
        let actionable = !removable.isEmpty
            && SafeDeleteEngine.verdict(for: removable.first ?? bundle).isAllowed

        return SlimmableApp(id: id, name: name, url: bundle,
                            reclaimableBytes: reclaimableBytes,
                            removable: removable, totalLproj: lprojs.count,
                            denied: false, actionable: actionable)
    }

    /// Scan the given locations for slimmable apps. Lists a bundle ONLY if it has
    /// removable .lproj OR its Resources was denied — a clean or missing app is
    /// never a 0-byte row. Sorted by reclaimable size, biggest first.
    static func scan(locations: [URL] = defaultLocations,
                     preferred: [String] = Locale.preferredLanguages) -> [SlimmableApp] {
        let fm = FileManager.default
        let kept = keptLanguages(preferred: preferred)
        var found: [SlimmableApp] = []
        for location in locations {
            guard let entries = try? fm.contentsOfDirectory(
                at: location, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for bundle in entries where bundle.pathExtension == "app" {
                let app = report(bundle: bundle, kept: kept)
                if !app.removable.isEmpty || app.denied { found.append(app) }
            }
        }
        return found.sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }

    /// Trash every removable .lproj for `app`. We deliberately do NOT pre-filter
    /// on `actionable`: moveToTrash() runs verdict() itself as the backstop, so a
    /// non-actionable (e.g. /Applications) bundle is refused at the gate and that
    /// refusal is returned (success:false, nothing deleted). Returns one outcome
    /// per removable URL — callers see exactly what happened.
    @discardableResult
    static func slim(_ app: SlimmableApp, context: String = "App slimming") -> [TrashOutcome] {
        app.removable.map { url in
            SafeDeleteEngine.moveToTrash(url, name: url.lastPathComponent, context: context)
        }
    }
}
