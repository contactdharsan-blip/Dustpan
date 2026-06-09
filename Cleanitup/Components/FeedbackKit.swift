import SwiftUI

/// FeedbackKit — the async-feedback bucket the app otherwise lacks (DESIGN §7.0).
///
/// These components back the four-state contract that every async boundary owes
/// the user (§7.0): `loading` (Skeleton) → `data` → `empty` (EmptyState) →
/// `error` (Toast). Plus a tabular-nums `CountUpMetric` for the size/count KPIs
/// (§3.3). Everything here reuses the DesignSystem-owned `Theme` tokens and the
/// `.glassCard()` modifier; nothing is redefined, and no type from a sibling
/// component file is referenced.
///
/// Motion is self-gated against `accessibilityReduceMotion` (§5.4): each animated
/// component reads the environment directly and falls back to a static / instant
/// render — there is no shared helper.

// MARK: - Skeleton (§7.0 loading leg, §5.5 shimmer)

/// A shimmering placeholder block for the `loading` state. A base fill with a
/// brighter band that sweeps left→right on a `repeatForever` loop — the native
/// equivalent of the web `shimmer` keyframe (§5.5).
///
/// §5.4 (required): when reduce-motion is on, we render ONLY the static base
/// fill and never start the repeating animation.
struct SkeletonView: View {
    var width: CGFloat? = nil
    var height: CGFloat
    var cornerRadius: CGFloat = Theme.radiusMd

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = -1

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(Color.white.opacity(0.06)) // §5.5 skeleton base
            .frame(width: width, height: height)
            .overlay {
                // Moving highlight band — only present when motion is allowed.
                if !reduceMotion {
                    GeometryReader { geo in
                        let w = geo.size.width
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(0.10), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        // Band is ~half the width and slides fully across.
                        .frame(width: w * 0.6)
                        .offset(x: offset * w)
                    }
                }
            }
            .clipShape(shape)
            .onAppear {
                guard !reduceMotion else { return } // §5.4 self-gate
                offset = -1
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    offset = 1.6 // run the band off the trailing edge
                }
            }
    }
}

// MARK: - Empty state (§7.0 empty leg)

/// The styled `empty` leg of the four-state contract (§7.0): a centered glass
/// card with a muted SF Symbol, title, message, and an optional action.
///
/// To keep this file dependency-free, the action is taken as a trailing closure
/// (`action`) plus a label (`actionTitle`); the integrator passes the
/// `.cleanGlass`-styled call site. We deliberately do NOT reference that button
/// style here so FeedbackKit has zero forward dependency.
struct EmptyStateView: View {
    let title: String
    let message: String
    let systemImage: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(Theme.textTertiary) // muted per §2.3

            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    // Integrator may re-skin; we keep a sensible glass-tinted
                    // default so the leg looks finished without a forward ref.
                    .font(.subheadline.weight(.semibold))
                    .tint(Theme.primary)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: 360)
        .padding(28)
        .glassCard(cornerRadius: Theme.radiusXl) // reuse DesignSystem modifier
    }
}

// MARK: - Toast (§7.0 error/done leg, §5.2 toastVariants)

/// Maps a toast intent to its semantic tint + SF Symbol (§2.5 status colors).
enum ToastStyle {
    case success
    case warning
    case error
    case info

    var tint: Color {
        switch self {
        case .success: return Theme.success
        case .warning: return Theme.warning
        case .error:   return Theme.error
        case .info:    return Theme.primary
        }
    }

    var systemImage: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.octagon.fill"
        case .info:    return "info.circle.fill"
        }
    }
}

/// A glass pill notification: tinted icon + message on a frosted capsule.
struct ToastView: View {
    let message: String
    var style: ToastStyle = .info

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: style.systemImage)
                .foregroundStyle(style.tint)
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .glassCard(cornerRadius: Theme.radiusFull) // capsule-shaped glass pill
    }
}

/// Self-contained presenter: overlays a `ToastView` at the top, entering with
/// y:-20→0 + fade on `Theme.spring` and auto-dismissing after ~2.5s (§5.2
/// `toastVariants`). It does NOT edit ContentView — the integrator attaches
/// `.toast(...)` at the ContentView root.
///
/// §5.4: enter/exit collapse to instant when reduce-motion is on.
struct ToastPresenter: ViewModifier {
    @Binding var message: String?
    var style: ToastStyle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dismissTask: Task<Void, Never>? = nil

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let message {
                    ToastView(message: message, style: style)
                        .padding(.top, 16)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .move(edge: .top).combined(with: .opacity)
                        )
                        .onAppear { scheduleDismiss() }
                        .id(message) // restart timing when the message changes
                }
            }
            // Drive enter/exit. Instant when reduce-motion is on (§5.4).
            .animation(reduceMotion ? nil : Theme.spring, value: message)
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000) // ~2.5s
            guard !Task.isCancelled else { return }
            message = nil
        }
    }
}

extension View {
    /// Attach at a root view: `.toast(message: $toastMessage, style: .success)`.
    func toast(message: Binding<String?>, style: ToastStyle = .info) -> some View {
        modifier(ToastPresenter(message: message, style: style))
    }
}

// MARK: - CountUpMetric (§3.3 tabular-nums KPI)

/// A KPI readout: a bold, monospaced-digit number over an uppercase tracked
/// label. `.monospacedDigit()` satisfies the §3.3 `tabular-nums` rule (digits
/// don't jitter), and `.contentTransition(.numericText())` animates the value
/// as it changes (e.g. a reclaimed-bytes counter ticking up).
///
/// The caller supplies the already-formatted string (use `ByteCountFormatter`
/// for sizes) so this view has zero formatting/typography forward dependency.
struct CountUpMetric: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(.title2, weight: .bold))
                .monospacedDigit() // §3.3 tabular-nums
                .foregroundStyle(Theme.textPrimary)
                .contentTransition(.numericText()) // animate on change

            Text(label)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(Theme.textTertiary)
        }
    }
}

// MARK: - Preview

#Preview {
    struct PreviewHost: View {
        @State private var toast: String? = "Cleanup complete — 1.2 GB reclaimed"
        @State private var bytes: Int64 = 1_288_490_188

        var body: some View {
            ZStack {
                Theme.bgPrimary.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 24) {
                        // Loading leg
                        VStack(alignment: .leading, spacing: 10) {
                            SkeletonView(width: 220, height: 18)
                            SkeletonView(height: 14)
                            SkeletonView(width: 160, height: 14)
                        }
                        .padding()
                        .glassCard()

                        // Empty leg
                        EmptyStateView(
                            title: "Nothing to clean",
                            message: "Your caches are already tidy. Run a scan to look again.",
                            systemImage: "sparkles",
                            actionTitle: "Run a scan",
                            action: { }
                        )

                        // Metrics (§3.3)
                        HStack(spacing: 32) {
                            CountUpMetric(
                                value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file),
                                label: "Reclaimable"
                            )
                            CountUpMetric(value: "127", label: "Items")
                        }
                        .padding()
                        .glassCard()

                        // Toast styles
                        VStack(spacing: 12) {
                            ToastView(message: "Saved", style: .success)
                            ToastView(message: "Low disk space", style: .warning)
                            ToastView(message: "Couldn't delete file", style: .error)
                            ToastView(message: "Scan running…", style: .info)
                        }
                    }
                    .padding(24)
                }
            }
            .frame(width: 460, height: 760)
            .toast(message: $toast, style: .success) // live presenter
        }
    }
    return PreviewHost()
}
