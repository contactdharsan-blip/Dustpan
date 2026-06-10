import SwiftUI
import Observation

/// App-scoped owner of the dashboard measurement. ContentView holds the single
/// instance and passes it down, so navigating away from Overview and back does
/// NOT restart the multi-minute walk — the last snapshot is simply re-rendered.
/// `refresh()` cancels any in-flight run and starts a fresh one.
@MainActor @Observable final class StatsStore {
    var snapshot: StatsSnapshot?
    /// When the last run finished (`isComplete`); drives the "measured HH:mm" pill.
    var completedAt: Date?
    @ObservationIgnored private var task: Task<Void, Never>?

    func refresh() {
        task?.cancel()
        snapshot = nil
        completedAt = nil
        task = Task {
            for await snap in StatsEngine.live() {
                snapshot = snap
                if snap.isComplete { completedAt = .now }
            }
        }
    }
}

/// DashboardView — the storage "Overview" landing screen.
///
/// HONESTY CONTRACT (the product's whole point): every number rendered here is a
/// REAL measurement off `StatsEngine.live()`, or an em-dash "—" while it is
/// still being measured / when it is genuinely unmeasurable. No mocks, no curved
/// scores, no fearmongering. On a nearly-full disk, a calm, honest low score is
/// the correct outcome — we report it matter-of-factly.
///
/// CONCURRENCY: we consume the frozen StatsEngine stream idiomatically via the
/// app-scoped StatsStore above. The engine sizes off the main thread and emits
/// successively-more-complete IMMUTABLE snapshots; we just bind the latest one
/// and render. We do NOT spin our own Task.detached, and we never call
/// diskTotals()/scanDeveloperCaches()/size() directly — the contract routes all
/// of that through `live()`.
///
/// Every contract type used here (StatsSnapshot, CategoryUsage, DiskTotals,
/// CleanlinessScore, StorageCategory) lives in the parallel StatsEngine.swift, and
/// ScannedItem/CleanRisk in SafeDeleteEngine.swift — this file DECLARES NONE of
/// them (the synchronized file group would otherwise duplicate-symbol).
struct DashboardView: View {
    let store: StatsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var snapshot: StatsSnapshot? { store.snapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                ScoreCard(snapshot: snapshot, reduceMotion: reduceMotion)
                KPIGrid(snapshot: snapshot)
                BreakdownCard(snapshot: snapshot, reduceMotion: reduceMotion)
                ReclaimableCard(snapshot: snapshot)
                NotMeasuredNote()
                Spacer(minLength: 0)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            // Settle each progressive snapshot in with the signature spring
            // (instant under Reduce Motion, §5.4).
            .animation(motionSafeSpring(reduceMotion), value: snapshot?.isComplete)
        }
        // Idempotent across re-appearances: only kick off a measurement when the
        // app-scoped store has none yet — sidebar round-trips reuse the snapshot.
        .task {
            if store.snapshot == nil { store.refresh() }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "internaldrive")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Theme.primary)
                .frame(width: 54, height: 54)
                .background(Theme.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).strokeBorder(Theme.primary.opacity(0.25), lineWidth: 1))
                .shadowGlow(Theme.primary, radius: 16, strength: 0.3)

            VStack(alignment: .leading, spacing: 6) {
                Text("Overview").font(Typo.h3).foregroundStyle(Theme.textPrimary)
                Text("An honest picture of your disk. Every number here is measured on your Mac — nothing is estimated or inflated.")
                    .font(.callout).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if snapshot?.isComplete != true {
                    Text("macOS may ask permission for Desktop, Documents and Downloads — Cleanitup only reads folder sizes.")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            // The data is a one-shot snapshot, not a live feed — say when it was
            // measured instead of pretending it's "live".
            PillBadge(text: measuredPillText, tint: Theme.neutral)
            Button("Refresh") { store.refresh() }
                .buttonStyle(GlassButtonStyle())
                .disabled(snapshot != nil && snapshot?.isComplete != true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var measuredPillText: String {
        guard snapshot?.isComplete == true else { return "measuring…" }
        guard let at = store.completedAt else { return "measured" }
        return "measured " + at.formatted(.dateTime.hour().minute())
    }
}

// MARK: - Hero score card (auditable: shows its own inputs)

/// The 0–100 cleanliness score, presented next to the exact inputs that produced
/// it (`score.inputsSummary`) so the number is verifiable by hand — never a black
/// box. Skeleton until `isComplete` makes `score` non-nil; we never show a
/// half-measured score.
private struct ScoreCard: View {
    let snapshot: StatsSnapshot?
    let reduceMotion: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Cleanliness score").typoLabel()

            if let score = snapshot?.score {
                HStack(alignment: .center, spacing: 22) {
                    ScoreDial(value: score.value, reduceMotion: reduceMotion)

                    VStack(alignment: .leading, spacing: 10) {
                        // The inputs the engine used — shown verbatim for audit.
                        ForEach(score.inputsSummary, id: \.self) { line in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "checkmark.seal")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.textTertiary)
                                Text(line)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Text("Score = percent-free minus a small reclaimable penalty (capped at 10 pts). Uncurved on purpose: a near-full disk honestly scores low.")
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                // Still measuring: a calm placeholder, never a fake number.
                HStack(spacing: 22) {
                    SkeletonView(width: 132, height: 132, cornerRadius: Theme.radiusFull)
                    VStack(alignment: .leading, spacing: 12) {
                        SkeletonView(width: 220, height: 14)
                        SkeletonView(width: 180, height: 14)
                        SkeletonView(width: 240, height: 10)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

/// A circular score readout: a ring filled to value/100 over a big tabular number.
/// The fill tint follows the score calmly (no red alarm) — emerald high, neutral
/// low. Ring growth is gated on Reduce Motion.
private struct ScoreDial: View {
    let value: Int
    let reduceMotion: Bool
    @State private var shown = false

    private var fraction: Double { Double(value) / 100 }
    /// Calm, non-alarmist tint ramp — a low score is muted, never red.
    private var tint: Color {
        switch value {
        case 60...: return Theme.primary
        case 30..<60: return Theme.secondary
        default: return Theme.neutral
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 12)
            Circle()
                .trim(from: 0, to: shown ? fraction : 0)
                .stroke(tint, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadowGlow(tint, radius: 14, strength: 0.35)

            VStack(spacing: 0) {
                Text("\(value)")
                    .font(.system(size: 40, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
                Text("of 100")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(width: 132, height: 132)
        .onAppear {
            if reduceMotion { shown = true }
            else { withAnimation(Theme.spring) { shown = true } }
        }
        // Re-trim if a later snapshot ever changes the value.
        .onChange(of: value) { _, _ in
            if reduceMotion { shown = true }
            else { withAnimation(Theme.spring) { shown = true } }
        }
    }
}

// MARK: - Headline KPIs (§3.3 tabular-nums)

/// The headline measurements. Disk totals come from one definition of Used so the
/// numbers reconcile; reclaimable/largest come straight off the snapshot. Each
/// reads "—" via the contract's own formatters while still measuring.
private struct KPIGrid: View {
    let snapshot: StatsSnapshot?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 20, alignment: .leading)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Disk at a glance").typoLabel()
            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                metric(snapshot?.disk?.totalText ?? "—", "Total capacity")
                metric(snapshot?.disk?.freeText ?? "—", "Free space")
                metric(snapshot?.disk?.usedText ?? "—", "Used space")
                metric(percentFreeText, "Percent free")
                metric(snapshot?.isComplete == true
                       ? ByteCountFormatter.string(fromByteCount: snapshot?.reclaimableBytes ?? 0, countStyle: .file)
                       : "—",
                       "Reclaimable (quick scan)")
                metric(snapshot?.isComplete == true ? "\(snapshot?.cacheLocationsFound ?? 0)" : "—",
                       "Reclaimable locations")
                metric(snapshot?.largestCategory?.category.name ?? "—", "Largest category")
                metric(snapshot?.disk?.purgeableText ?? "—", "Purgeable (macOS manages this)")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var percentFreeText: String {
        guard let disk = snapshot?.disk else { return "—" }
        return "\(Int((disk.freeFraction * 100).rounded()))%"
    }

    private func metric(_ value: String, _ label: String) -> some View {
        CountUpMetric(value: value, label: label)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Storage composition (stacked bar + legend)

/// "What your storage is made of" — a horizontal stacked bar plus a legend over
/// the measured categories AND the honest remainder. Percentages are computed
/// against `disk.used` (categories + remainder sum to Used by construction —
/// unless APFS clones push the sum past Used, in which case the remainder shows
/// "—" with a one-line explanation). The remainder is ALWAYS labeled via
/// `snapshot.unaccountedLabel` ("System & other (not itemized)") — never
/// "System Data". Unmeasured rows render a SkeletonView; permission-denied rows
/// show "—"/"≥" plus a "Needs permission" affordance, never a fake number.
private struct BreakdownCard: View {
    let snapshot: StatsSnapshot?
    let reduceMotion: Bool

    /// A stable color ramp for the segments (reused by bar + legend).
    private let palette: [Color] = [
        Theme.primary, Theme.secondary, Theme.primaryLight,
        Theme.primaryDark, Theme.warning,
    ]
    /// 5 base colors over ~20 rows would repeat exactly — each palette cycle
    /// steps the opacity down so every row/segment pair stays visually unique.
    /// ONE helper used by both the bar and the legend so they always match.
    private func color(for index: Int) -> Color {
        palette[index % palette.count].opacity(1.0 - 0.18 * Double(index / palette.count))
    }
    /// The remainder gets the neutral tint — it's "everything else", not an alarm.
    private let remainderTint = Theme.neutral

    private var used: Int64 { snapshot?.disk?.used ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What your storage is made of").typoLabel()

            if let snapshot, let disk = snapshot.disk {
                stackedBar(snapshot: snapshot, used: disk.used)
                legend(snapshot: snapshot, used: disk.used)
                if snapshot.anyPermissionDenied { fdaHint }
            } else {
                // Disk totals unavailable (volume keys missing) or first paint.
                SkeletonView(height: 18, cornerRadius: Theme.radiusFull)
                VStack(spacing: 10) {
                    ForEach(0..<5, id: \.self) { _ in
                        HStack(spacing: 12) {
                            SkeletonView(width: 14, height: 14, cornerRadius: Theme.radiusSm)
                            SkeletonView(width: 120, height: 12)
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

    // MARK: Bar

    @ViewBuilder
    private func stackedBar(snapshot: StatsSnapshot, used: Int64) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            HStack(spacing: 1.5) {
                // Denied categories (bytes == nil) and sub-2pt slivers are dropped
                // from the bar — the legend still lists them — so the total width
                // stays exact instead of being inflated by per-segment floors.
                ForEach(Array(snapshot.categories.enumerated()), id: \.element.id) { index, usage in
                    if let bytes = usage.bytes, used > 0,
                       barWidth(bytes, of: used, in: width) >= 2 {
                        segment(width: barWidth(bytes, of: used, in: width),
                                color: color(for: index))
                    }
                }
                // The honest remainder segment (only once complete; absent when
                // sumExceedsUsed — there is no real remainder to draw then).
                if let remainder = snapshot.unaccountedBytes, used > 0,
                   barWidth(remainder, of: used, in: width) >= 2 {
                    segment(width: barWidth(remainder, of: used, in: width), color: remainderTint)
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .frame(height: 18)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }

    private func barWidth(_ bytes: Int64, of total: Int64, in width: CGFloat) -> CGFloat {
        guard total > 0 else { return 0 }
        return width * CGFloat(Double(bytes) / Double(total))
    }

    private func segment(width: CGFloat, color: Color) -> some View {
        Rectangle().fill(color).frame(width: width)
    }

    // MARK: Legend

    @ViewBuilder
    private func legend(snapshot: StatsSnapshot, used: Int64) -> some View {
        VStack(spacing: 10) {
            ForEach(Array(snapshot.categories.enumerated()), id: \.element.id) { index, usage in
                legendRow(
                    color: color(for: index),
                    name: usage.category.name,
                    systemImage: usage.category.systemImage,
                    bytes: usage.bytes,
                    sizeText: usage.sizeText,
                    // Denied is RESOLVED (shows "—" + badge), not still-sizing.
                    isMeasured: usage.isMeasured || usage.rootDenied,
                    needsPermission: usage.needsPermission,
                    used: used
                )
            }
            // The remainder row — only once complete; same honest Used base.
            if snapshot.isComplete {
                if let remainder = snapshot.unaccountedBytes {
                    legendRow(
                        color: remainderTint,
                        name: snapshot.unaccountedLabel,
                        systemImage: "questionmark.folder",
                        bytes: remainder,
                        sizeText: ByteCountFormatter.string(fromByteCount: remainder, countStyle: .file),
                        isMeasured: true,
                        used: used
                    )
                } else if snapshot.sumExceedsUsed {
                    // Categories sum past Used — show "—" + the honest why,
                    // never a silently-clamped 0.
                    legendRow(
                        color: remainderTint,
                        name: snapshot.unaccountedLabel,
                        systemImage: "questionmark.folder",
                        bytes: nil,
                        sizeText: "—",
                        isMeasured: true,
                        caption: "Categories can sum past Used because APFS clones share disk space",
                        used: used
                    )
                } else if snapshot.anyRootDenied {
                    // A denied root has an unknown real size — the remainder
                    // would silently absorb it under the wrong label.
                    legendRow(
                        color: remainderTint,
                        name: snapshot.unaccountedLabel,
                        systemImage: "questionmark.folder",
                        bytes: nil,
                        sizeText: "—",
                        isMeasured: true,
                        caption: "Can't compute the remainder — it would include folders Cleanitup wasn't allowed to read. Grant access and rescan for exact numbers.",
                        used: used
                    )
                }
            }
        }
    }

    private func legendRow(color: Color, name: String, systemImage: String,
                           bytes: Int64?, sizeText: String, isMeasured: Bool,
                           needsPermission: Bool = false, caption: String? = nil,
                           used: Int64) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(color)
                    .frame(width: 12, height: 12)
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 18)
                Text(name)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if needsPermission { PermissionBadgeButton() }
                Spacer(minLength: 8)

                if isMeasured {
                    Text(percentText(bytes, of: used))
                        .font(.caption.weight(.medium)).monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                    Text(sizeText)
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                        .frame(minWidth: 70, alignment: .trailing)
                } else {
                    // Still sizing this bucket — skeleton, never a fake number.
                    SkeletonView(width: 70, height: 14)
                }
            }
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.leading, 42)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One quiet, non-fearmongering row shown when any bucket hit a permission
    /// wall: exact numbers need Full Disk Access; rescan after granting.
    private var fdaHint: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
            Text("Some folders need Full Disk Access for exact numbers (\"—\" or \"≥\" above). After granting, relaunch Cleanitup to rescan.")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings") { PermissionBadgeButton.openFullDiskAccessSettings() }
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(.top, 4)
    }

    private func percentText(_ bytes: Int64?, of used: Int64) -> String {
        guard let bytes, used > 0 else { return "—" }
        let pct = Double(bytes) / Double(used) * 100
        return pct < 0.1 ? "<0.1%" : String(format: "%.1f%%", pct)
    }
}

/// "Needs permission" pill that deep-links to Privacy & Security → Full Disk
/// Access. Calm affordance, not an alarm: the row already shows an honest
/// "—" / "≥" instead of a fake number.
private struct PermissionBadgeButton: View {
    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    var body: some View {
        Button(action: Self.openFullDiskAccessSettings) {
            PillBadge(text: "Needs permission", tint: Theme.warning)
        }
        .buttonStyle(.plain)
        .help("Open Privacy & Security → Full Disk Access, then relaunch to rescan")
    }
}

// MARK: - Reclaimable now (calm CTA)

/// Surfaces the live `scanDeveloperCaches()` total (carried on the snapshot) with
/// a calm, non-pushy call to action. While sizing/scanning, it shows skeletons;
/// when nothing is reclaimable it says so plainly — no manufactured urgency.
private struct ReclaimableCard: View {
    let snapshot: StatsSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Reclaimable now").typoLabel()
                Spacer()
                if let snapshot, snapshot.isComplete {
                    PillBadge(text: "\(snapshot.cacheLocationsFound) location\(snapshot.cacheLocationsFound == 1 ? "" : "s")",
                              tint: Theme.neutral)
                }
            }

            if let snapshot, snapshot.isComplete {
                let bytes = snapshot.reclaimableBytes
                CountUpMetric(
                    value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file),
                    label: "Known reclaimable locations (quick scan)"
                )
                if bytes > 0 {
                    Text("These are known reclaimable locations (developer caches, package managers, logs, backups) with honest risk labels. You review and confirm everything before anything moves to the Trash.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Nothing reclaimable in the known locations the quick scan checks. Your caches are already tidy.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    SkeletonView(width: 140, height: 24)
                    SkeletonView(height: 12)
                    SkeletonView(width: 220, height: 12)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

// MARK: - Not-measured honesty note

/// The one mandated NOT-measurable headline: Apple's private "System Data" bucket.
/// We cannot reproduce it without private APIs, so we render an em-dash and a
/// quiet note pointing to our honest itemized remainder instead. This is a
/// deliberate honesty element, not an omission.
private struct NotMeasuredNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textTertiary)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Apple's “System Data” bucket")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                    Text("—")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                Text("Not measured — it needs private APIs we won't pretend to have. We show our own itemized “System & other (not itemized)” remainder above instead.")
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
