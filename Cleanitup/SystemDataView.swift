import SwiftUI

// A1 — "System Data, explained". The #1 storage confusion on every Mac forum:
// Settings > Storage shows a giant opaque "System Data" number with no
// breakdown. This view reconstructs that bucket from OUR measurements: the
// StatsEngine categories macOS lumps under System Data, itemized, each with a
// plain explanation and a pointer to the surface that can act on it.
//
// HONESTY CONTRACT (D10, resolved 2026-06-10): we reconcile against the
// verifiable used-bytes ground truth (URLResourceValues — same as `df`),
// NEVER against Apple's Storage-pane numbers (private API, cached, shifting).
// The unindexed remainder is shown explicitly; divergence from Apple's pane is
// documented on screen as a feature, not hidden.
//
// Pure presentation layer: reuses the app-scoped StatsStore measurement.
// This file declares no measurement logic and never calls the engines directly.

/// Which side of Apple's Storage pane a category lands on, plus the
/// plain-language story for the System-Data side.
private struct SystemDataInfo {
    let what: String          // one line: what actually lives here
    let actSurface: String?   // Cleanitup surface that can act, nil = macOS-managed
}

/// StatsEngine category IDs that Apple's Storage pane lumps into "System Data"
/// (everything it can't attribute to a named, user-facing bucket).
private let systemDataSide: [String: SystemDataInfo] = [
    "caches":           .init(what: "App-rebuilt caches — regenerated automatically on next launch.",
                              actSurface: "Developer Caches (Deep scan)"),
    "logs":             .init(what: "Diagnostic logs apps recreate; past history is the only loss.",
                              actSurface: "Developer Caches"),
    "developer":        .init(what: "Xcode, simulators, device support, toolchains — the usual giant.",
                              actSurface: "Developer Caches"),
    "containers":       .init(what: "Sandboxed app data. Leftovers linger here after app deletion.",
                              actSurface: "App Uninstaller / Orphaned Files"),
    "group-containers": .init(what: "Data shared across an app suite (e.g. an office or chat suite).",
                              actSurface: nil),
    "app-support":      .init(what: "Per-app working data; a classic home for leftovers.",
                              actSurface: "App Uninstaller / Orphaned Files"),
    "library-other":    .init(what: "Fonts, preferences, keychains, extensions — mostly macOS-managed.",
                              actSurface: nil),
    "sys-library":      .init(what: "/Library — shared system-wide support files. Read-only here.",
                              actSurface: nil),
    "sys-other":        .init(what: "macOS services, /private/var, swap & sleep images. Read-only here.",
                              actSurface: nil),
]

struct SystemDataView: View {
    let store: StatsStore
    /// nil = still listing; populated = the tmutil report (A3, report-only).
    @State private var snapshotReport: SnapshotReport?

    private var snapshot: StatsSnapshot? { store.snapshot }

    private var systemDataUsages: [CategoryUsage] {
        (snapshot?.categories ?? [])
            .filter { systemDataSide.keys.contains($0.category.id) }
            .sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
    }
    private var finderVisibleUsages: [CategoryUsage] {
        (snapshot?.categories ?? []).filter { !systemDataSide.keys.contains($0.category.id) }
    }

    /// Our System-Data-side estimate: lumped categories + the honest remainder.
    /// nil until complete, and nil whenever the remainder itself can't be
    /// computed honestly (denied roots / clone overshoot) — partial sums never
    /// masquerade as the full story.
    private var estimateBytes: Int64? {
        guard let snapshot, snapshot.isComplete,
              let remainder = snapshot.unaccountedBytes else { return nil }
        let lumped = systemDataUsages.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
        return lumped + remainder
    }

    /// Share of Used that our categories itemize (the D10 coverage number).
    private var coverageText: String {
        guard let snapshot, snapshot.isComplete, let disk = snapshot.disk,
              disk.used > 0, !snapshot.anyRootDenied else { return "—" }
        let pct = Double(snapshot.measuredCategoryBytes) / Double(disk.used) * 100
        return String(format: "%.0f%%", min(pct, 100))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                reconciliationCard
                breakdownCard
                snapshotsCard
                divergenceNote
                Spacer(minLength: 0)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        // Same idempotent pattern as DashboardView: reuse the app-scoped
        // measurement; only start one if nothing has ever run.
        .task {
            if store.snapshot == nil { store.refresh() }
            if snapshotReport == nil {
                snapshotReport = await Task.detached(priority: .utility) {
                    SnapshotEngine.listLocalSnapshots()
                }.value
            }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Theme.primary)
                .frame(width: 54, height: 54)
                .background(Theme.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).strokeBorder(Theme.primary.opacity(0.25), lineWidth: 1))
                .shadowGlow(Theme.primary, radius: 16, strength: 0.3)
            VStack(alignment: .leading, spacing: 6) {
                Text("System Data, explained").font(Typo.h3).foregroundStyle(Theme.textPrimary)
                Text("What macOS hides behind its biggest, vaguest storage label — itemized from real measurements on your Mac.")
                    .font(.callout).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            PillBadge(text: snapshot?.isComplete == true ? "measured" : "measuring…", tint: Theme.neutral)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: Reconciliation against ground truth

    private var reconciliationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("The honest arithmetic").typoLabel()
            if let snapshot, let disk = snapshot.disk {
                let finderBytes = finderVisibleUsages.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
                HStack(spacing: 28) {
                    CountUpMetric(value: disk.usedText, label: "Used (ground truth)")
                    CountUpMetric(
                        value: snapshot.isComplete
                            ? ByteCountFormatter.string(fromByteCount: finderBytes, countStyle: .file) : "—",
                        label: "Stuff Finder shows you")
                    CountUpMetric(
                        value: estimateBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—",
                        label: "“System Data” side (our estimate)")
                    CountUpMetric(value: coverageText, label: "Of Used we itemized")
                }
                Text("Used space comes from the same volume statistics `df` reads — verify it yourself in Terminal. The two halves plus the unindexed slice below sum back to Used; nothing is estimated or inflated."
                     + (snapshot.disk?.purgeable != nil
                        ? " Purgeable space (\(disk.purgeableText)) overlaps these numbers — macOS frees it on demand."
                        : ""))
                    .font(.caption).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 28) {
                    SkeletonView(width: 120, height: 24)
                    SkeletonView(width: 120, height: 24)
                    SkeletonView(width: 120, height: 24)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: The itemized System-Data side

    private var breakdownCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What's actually in there").typoLabel()
            if let snapshot {
                VStack(spacing: 10) {
                    ForEach(systemDataUsages) { usage in
                        row(usage: usage, info: systemDataSide[usage.category.id])
                    }
                    // The unindexed slice — always shown, never laundered into a
                    // named bucket (D10: tolerance + honest bucket).
                    if snapshot.isComplete {
                        remainderRow(snapshot: snapshot)
                    }
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(0..<6, id: \.self) { _ in
                        HStack(spacing: 12) {
                            SkeletonView(width: 14, height: 14, cornerRadius: Theme.radiusSm)
                            SkeletonView(width: 160, height: 12)
                            Spacer()
                            SkeletonView(width: 64, height: 12)
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func row(usage: CategoryUsage, info: SystemDataInfo?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Image(systemName: usage.category.systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 18)
                Text(usage.category.name)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if usage.isMeasured || usage.rootDenied {
                    Text(usage.sizeText)
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                        .frame(minWidth: 70, alignment: .trailing)
                } else {
                    SkeletonView(width: 70, height: 14)
                }
            }
            if let info {
                Text(info.what + (info.actSurface.map { " Act on it: \($0)." } ?? " macOS manages this — Cleanitup leaves it alone."))
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.leading, 30)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func remainderRow(snapshot: StatsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Image(systemName: "questionmark.folder")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 18)
                Text("Unindexed (we honestly don't know)")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Text(snapshot.unaccountedBytes.map {
                    ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                } ?? "—")
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                    .frame(minWidth: 70, alignment: .trailing)
            }
            Text(remainderCaption(snapshot))
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .padding(.leading, 30)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private func remainderCaption(_ snapshot: StatsSnapshot) -> String {
        if snapshot.unaccountedBytes != nil {
            return "Sealed system volume, snapshots, and whatever our categories don't reach. Anyone telling you they itemized 100% is guessing."
        }
        if snapshot.sumExceedsUsed {
            return "Categories sum past Used — APFS clones share disk blocks, so a remainder can't be computed honestly here."
        }
        return "Can't compute — some folders were unreadable without Full Disk Access, and their unknown size would hide inside this number."
    }

    // MARK: A3 — local Time Machine snapshots (report-only)

    private var snapshotsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Local Time Machine snapshots").typoLabel()
                Spacer()
                PillBadge(text: "report-only", tint: Theme.neutral)
            }

            if let report = snapshotReport {
                if report.toolUnavailable {
                    // tmutil failed — say so; an error is never an empty list.
                    Text("Couldn't ask macOS about snapshots (tmutil unavailable or returned an error).")
                        .font(.subheadline).foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else if report.snapshots.isEmpty {
                    Text("No local snapshots right now. macOS creates them hourly while Time Machine is on and deletes them automatically within about 24 hours — an empty list here is normal and healthy.")
                        .font(.subheadline).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 8) {
                        ForEach(report.snapshots) { snap in
                            HStack(spacing: 12) {
                                Image(systemName: "clock.badge.checkmark")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.textTertiary)
                                    .frame(width: 18)
                                Text(snap.dateText)
                                    .font(.subheadline).foregroundStyle(Theme.textPrimary)
                                Text(snap.ageText)
                                    .font(.caption).foregroundStyle(Theme.textTertiary)
                                Spacer(minLength: 8)
                                // macOS exposes no per-snapshot size without
                                // privileged APIs — em-dash, never a guess.
                                Text("—")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                    }
                    Text("Snapshot space reports as purgeable above — macOS reclaims it on demand and expires each snapshot within ~24 hours. Per-snapshot sizes need privileged APIs, so we show “—” rather than guess. Cleanitup doesn't delete snapshots today; that action isn't Trash-reversible.")
                        .font(.caption).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                SkeletonView(height: 14)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: Divergence disclosure (the D10 feature)

    private var divergenceNote: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textTertiary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Why this won't match Settings > Storage byte-for-byte")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                Text("Apple's pane uses private accounting, caches stale values, and moves purgeable space between buckets while you watch. We measure live from the filesystem instead — the same numbers `du` and `df` give you, which means you can check our math. When the two disagree, trust the one you can verify.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: Theme.radiusXl)
    }
}
