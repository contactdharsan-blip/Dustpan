import SwiftUI

/// Buttons & inputs (DESIGN §7.3, §7.5). All reuse the DesignSystem `Theme`
/// tokens, the §4.3 accent glow (`.shadowGlow`), and the signature spring press.
///
/// Note: `ButtonStyle` structs don't receive the SwiftUI environment, so press
/// feedback uses the spring unconditionally (a momentary scale, not an enter/exit
/// transition — outside the §5.4 reduce-motion mandate, which targets
/// appear/disappear and looping motion).

// MARK: - Primary button (§7.3)

/// Gradient emerald fill + accent glow, springy `scale(0.96)` press.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .foregroundStyle(Color(hex: 0x052E22))   // dark ink for contrast on bright emerald
            .padding(.horizontal, 20)
            .padding(.vertical, 11)
            .background(
                LinearGradient(
                    colors: [Theme.primary, Theme.primaryDark],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous)
            )
            .shadowGlow(Theme.primary, radius: configuration.isPressed ? 10 : 16, strength: 0.45)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Theme.spring, value: configuration.isPressed)
    }
}

// MARK: - Glass / secondary button (§7.3)

/// Frosted glass fill, hairline edge, same radius + spring press.
struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous)
        return configuration.label
            .font(.headline.weight(.medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 20)
            .padding(.vertical, 11)
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Theme.spring, value: configuration.isPressed)
    }
}

// MARK: - Glass text field (§7.5)

/// Glass fill with an accent focus ring + soft glow when focused.
struct GlassTextField: View {
    let placeholder: String
    @Binding var text: String

    @FocusState private var focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous)
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textTertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: shape)
        .overlay(
            shape.strokeBorder(
                focused ? Theme.primary.opacity(0.85) : Color.white.opacity(0.14),
                lineWidth: 1
            )
        )
        .shadowGlow(Theme.primary, radius: focused ? 12 : 0, strength: focused ? 0.30 : 0)
        .focused($focused)
        .animation(Theme.base, value: focused)
    }
}

// MARK: - Preview

#Preview {
    struct Host: View {
        @State private var query = ""
        var body: some View {
            ZStack {
                Theme.bgPrimary.ignoresSafeArea()
                VStack(spacing: 20) {
                    Button("Move to Trash") {}.buttonStyle(PrimaryButtonStyle())
                    Button("Rescan") {}.buttonStyle(GlassButtonStyle())
                    GlassTextField(placeholder: "Filter results", text: $query)
                }
                .padding(40)
                .frame(width: 360)
            }
        }
    }
    return Host()
}
