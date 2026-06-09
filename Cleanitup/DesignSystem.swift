import SwiftUI

/// Cleanitup's design language — a SwiftUI translation of Biopath's
/// "Dark Liquid-Glass" system (DESIGN.md): near-black canvas, one themeable
/// emerald→teal accent, frosted glass surfaces, ambient glow, spring-overshoot
/// motion. Web tokens (CSS vars / Tailwind) map to native equivalents here.
///
/// Font note: the source system uses Bricolage Grotesque / General Sans (web
/// fonts). We use the native San Francisco system font following the same
/// scale/weight intent rather than bundling font files.
enum Theme {
    // MARK: Canvas & surfaces (§2.1)
    static let bgPrimary = Color(hex: 0x030712)
    static let bgSecondary = Color(hex: 0x111827)
    static let bgTertiary = Color(hex: 0x1F2937)

    // MARK: Accent ramp — emerald → teal (§2.4)
    static let primary = Color(hex: 0x34D399)       // emerald 400
    static let primaryDark = Color(hex: 0x059669)   // emerald 600
    static let primaryLight = Color(hex: 0x6EE7B7)  // emerald 300
    static let secondary = Color(hex: 0x38BDF8)      // sky/teal

    // MARK: Text (§2.3)
    static let textPrimary = Color(hex: 0xF8FAFC)
    static let textSecondary = Color(hex: 0xCBD5E1)
    static let textTertiary = Color(hex: 0x94A3B8)

    // MARK: Semantic status (§2.5) — drives the Safe/Caution risk labels
    static let success = Color(hex: 0x10B981)
    static let warning = Color(hex: 0xF59E0B)
    static let error = Color(hex: 0xEF4444)
    static let alert = Color(hex: 0xF87171)    // §2.5 soft alert
    static let neutral = Color(hex: 0x6B7280)  // §2.5 completes success→warning→neutral scale

    // MARK: Radius (§4.2)
    static let radiusSm: CGFloat = 8
    static let radiusMd: CGFloat = 12
    static let radiusLg: CGFloat = 16
    static let radiusXl: CGFloat = 20
    static let radius2xl: CGFloat = 24
    static let radiusFull: CGFloat = 9999

    // MARK: Motion (§5) — the signature spring overshoots, like the web curve
    /// Reserve for hero/primary interactions (matches Motion damping 25 / stiffness 300).
    static let spring = Animation.spring(response: 0.45, dampingFraction: 0.7)
    /// Crisp, non-bouncy — for small/frequent surfaces (the §5.2 dropdown rule).
    static let base = Animation.easeInOut(duration: 0.25)
}

extension Color {
    /// Build an sRGB color from a 0xRRGGBB literal — mirrors the web hex tokens.
    init(hex: UInt, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

// MARK: - Glass surface (§7.1)

/// The primary surface treatment: frosted material, hairline lit edge, soft
/// shadow. `.ultraThinMaterial` is SwiftUI's native `backdrop-filter: blur()`.
struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = Theme.radius2xl

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            // top "lit glass edge" highlight (the §7.1 inset 0 1px 0)
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.16), .clear],
                        startPoint: .top, endPoint: .center
                    ),
                    lineWidth: 1
                )
            )
            .shadow(color: .black.opacity(0.3), radius: 16, x: 0, y: 8)
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = Theme.radius2xl) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius))
    }
}

// MARK: - Ambient background (§6)

/// Two depth layers create the "alive" dark canvas: a fixed near-black wash with
/// ultra-subtle, same-family radial glows that slowly drift. Opacity kept ≤ 0.10.
struct AmbientBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false

    var body: some View {
        ZStack {
            Theme.bgPrimary
            glow(Theme.primary.opacity(0.10), center: .init(x: 0.18, y: 0.48))
                .offset(x: drift ? 18 : -18, y: drift ? -12 : 12)
            glow(Theme.secondary.opacity(0.07), center: .init(x: 0.86, y: 0.16))
                .offset(x: drift ? -14 : 14, y: drift ? 10 : -10)
            glow(Theme.primaryLight.opacity(0.05), center: .init(x: 0.5, y: 0.92))
        }
        .ignoresSafeArea()
        .onAppear {
            // §5.4: looping ambient motion is disabled under Reduce Motion.
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 28).repeatForever(autoreverses: true)) {
                drift = true
            }
        }
    }

    private func glow(_ color: Color, center: UnitPoint) -> some View {
        RadialGradient(colors: [color, .clear], center: center, startRadius: 0, endRadius: 520)
            .blendMode(.screen)
    }
}

// MARK: - Shadows & typography helpers (§4.3, §3.3)

extension View {
    /// §4.3 `--shadow-glow` / `--shadow-interactive`: a soft, same-family accent halo.
    func shadowGlow(_ color: Color = Theme.primary, radius: CGFloat = 20, strength: Double = 0.4) -> some View {
        shadow(color: color.opacity(strength), radius: radius, x: 0, y: 0)
    }

    /// §3.3 `typo-label`: uppercase, tracked, tertiary — for eyebrow/section labels.
    func typoLabel() -> some View {
        self.font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(Theme.textTertiary)
    }
}

/// §3.3 type roles mapped to San Francisco (see the font note above).
enum Typo {
    static let metric = Font.system(.title2, weight: .bold)   // pair with .monospacedDigit()
    static let h3 = Font.title3.weight(.semibold)
    static let cardHeading = Font.headline.weight(.medium)
    static let mono = Font.system(.caption, design: .monospaced)
}

/// §5.4 helper: the signature spring, or `nil` (instant) under Reduce Motion.
/// Read `@Environment(\.accessibilityReduceMotion)` at the call site and pass it in.
func motionSafeSpring(_ reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : Theme.spring
}

// MARK: - Pill badge (§7.6)

/// Low-alpha tinted pill with an uppercase label — the §7.6 badge recipe.
struct PillBadge: View {
    let text: String
    var tint: Color = Theme.primary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.25), lineWidth: 1))
    }
}
