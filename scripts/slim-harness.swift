import Foundation

// Standalone assertion harness for AppSlimmingEngine. No XCTest — a @main entry
// (so swiftc accepts it under this non-"main.swift" filename — do NOT rename it
// to main.swift, that re-bans @main), prints PASS/FAIL per check and
// ALL PASS / FAILURES: n, exits non-zero on any failure. Lives in scripts/ (not
// Dustpan/) so the app target's synchronized folder group never compiles it.
// Run:
//   swiftc -o /tmp/slimt/run Dustpan/AppSlimmingEngine.swift \
//     Dustpan/SafeDeleteEngine.swift Dustpan/ExclusionList.swift \
//     Dustpan/UndoJournal.swift scripts/slim-harness.swift && /tmp/slimt/run

@main
struct SlimHarness {
    static var failures = 0
    static func check(_ cond: Bool, _ msg: String) {
        if cond { print("PASS \(msg)") }
        else { print("FAIL \(msg)"); failures += 1 }
    }

    static let fm = FileManager.default

    // Build a .app/Contents/Resources with the given lproj language dirs, each a
    // directory holding one small file (so size(of:) > 0).
    static func makeBundle(at appURL: URL, langs: [String]) throws {
        let resources = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        for lang in langs {
            let lproj = resources.appendingPathComponent("\(lang).lproj", isDirectory: true)
            try fm.createDirectory(at: lproj, withIntermediateDirectories: true)
            let file = lproj.appendingPathComponent("Localizable.strings")
            try "\"key\" = \"value for \(lang)\";\n".data(using: .utf8)!.write(to: file)
        }
    }

    static func stems(_ urls: [URL]) -> Set<String> {
        Set(urls.map { $0.lastPathComponent })
    }

    static func main() {
        // ---- 1. keptLanguages generosity ------------------------------------
        let kept = AppSlimmingEngine.keptLanguages(preferred: ["en-US"])
        check(kept.contains("base"), "keptLanguages contains Base")
        check(kept.contains("en"), "keptLanguages contains en (primary subtag of en-US)")
        check(kept.contains("english"), "keptLanguages contains English")

        // ---- 2. HOME bundle: actionable, fr/de removable --------------------
        let homeRoot = fm.homeDirectoryForCurrentUser.appendingPathComponent(".dustpan-slim-harness", isDirectory: true)
        let homeApp = homeRoot.appendingPathComponent("HomeApp.app", isDirectory: true)
        let sysRoot = URL(fileURLWithPath: "/tmp/dustpan-slim-harness", isDirectory: true)
        let sysApp = sysRoot.appendingPathComponent("SysApp.app", isDirectory: true)

        // teardown any stale state first
        try? fm.removeItem(at: homeRoot)
        try? fm.removeItem(at: sysRoot)

        do {
            try makeBundle(at: homeApp, langs: ["Base", "en", "fr", "de"])
            let report = AppSlimmingEngine.report(bundle: homeApp, kept: kept)
            check(stems(report.removable) == ["fr.lproj", "de.lproj"], "HOME removable == {fr,de}.lproj")
            check(report.totalLproj == 4, "HOME totalLproj == 4")
            check(report.reclaimableBytes > 0, "HOME reclaimableBytes > 0")
            check(report.actionable == true, "HOME actionable == true")
        } catch {
            print("FAIL HOME bundle setup: \(error)"); failures += 1
        }

        // ---- 3. /tmp bundle: NOT actionable (verdict refuses /private/tmp) --
        do {
            try makeBundle(at: sysApp, langs: ["Base", "en", "fr", "de"])
            let report = AppSlimmingEngine.report(bundle: sysApp, kept: kept)
            check(stems(report.removable) == ["fr.lproj", "de.lproj"], "SYS removable == {fr,de}.lproj")
            check(report.actionable == false, "SYS actionable == false (verdict refuses /tmp)")

            // ---- 4. slim() on non-actionable refuses; fr/de still exist -----
            let outcomes = AppSlimmingEngine.slim(report)
            check(!outcomes.isEmpty && outcomes.allSatisfy { !$0.success }, "SYS slim() all refused (success==false)")
            let sysRes = sysApp.appendingPathComponent("Contents/Resources", isDirectory: true)
            check(fm.fileExists(atPath: sysRes.appendingPathComponent("fr.lproj").path), "SYS fr.lproj still exists")
            check(fm.fileExists(atPath: sysRes.appendingPathComponent("de.lproj").path), "SYS de.lproj still exists")
        } catch {
            print("FAIL SYS bundle setup: \(error)"); failures += 1
        }

        // ---- 5. slim() on HOME actually Trashes fr/de; Base/en remain -------
        do {
            let report = AppSlimmingEngine.report(bundle: homeApp, kept: kept)
            let outcomes = AppSlimmingEngine.slim(report)
            check(!outcomes.isEmpty && outcomes.allSatisfy { $0.success }, "HOME slim() all succeeded (success==true)")
            let homeRes = homeApp.appendingPathComponent("Contents/Resources", isDirectory: true)
            check(fm.fileExists(atPath: homeRes.appendingPathComponent("Base.lproj").path), "HOME Base.lproj remains")
            check(fm.fileExists(atPath: homeRes.appendingPathComponent("en.lproj").path), "HOME en.lproj remains")
            check(!fm.fileExists(atPath: homeRes.appendingPathComponent("fr.lproj").path), "HOME fr.lproj gone")
            check(!fm.fileExists(atPath: homeRes.appendingPathComponent("de.lproj").path), "HOME de.lproj gone")
        }

        // ---- teardown -------------------------------------------------------
        try? fm.removeItem(at: homeRoot)
        try? fm.removeItem(at: sysRoot)

        if failures == 0 { print("ALL PASS"); exit(0) }
        else { print("FAILURES: \(failures)"); exit(1) }
    }
}
