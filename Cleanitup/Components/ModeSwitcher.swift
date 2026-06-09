import SwiftUI

/// Controls & badges (DESIGN §7.4, §7.6, §2.5).

// MARK: - Status kinds (§2.5)

/// The semantic quality scale that drives every Safe/Caution risk label.
enum StatusKind {
    case safe, caution, neutral, info

    var tint: Color {
        switch self {
        case .safe: return Theme.success
        case .caution: return Theme.warning
        case .neutral: return Theme.neutral
        case .info: return Theme.primary
        }
    }

    var label: String {
        switch self {
        case .safe: return "Safe"
        case .caution: return "Caution"
        case .neutral: return "Neutral"
        case .info: return "Info"
        }
    }
}

// MARK: - Status badge (§7.6)

/// Low-alpha tinted pill carrying a status/risk label — uppercase + tracked.
struct StatusBadge: View {
    let kind: StatusKind
    var text: String? = nil

    var body: some View {
        Text(text ?? kind.label)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(kind.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(kind.tint.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(kind.tint.opacity(0.25), lineWidth: 1))
    }
}

// MARK: - Segmented mode switcher (§7.4)

/// A glass track with a "liquid" glass indicator that springs between options
/// (the §7.4 rule: animate the indicator's position, not the labels). The slide
/// is driven by `matchedGeometryEffect`; under Reduce Motion the selection snaps.
struct ModeSwitcher<Option: Hashable>: View {
    let options: [Option]
    let title: (Option) -> String
    @Binding var selection: Option

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var indicatorNS

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Text(title(option))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background {
                        if isSelected {
                            let pill = RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
                            pill
                                .fill(.ultraThinMaterial)
                                .overlay(pill.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                                .matchedGeometryEffect(id: "indicator", in: indicatorNS)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if reduceMotion { selection = option }
                        else { withAnimation(Theme.spring) { selection = option } }
                    }
            }
        }
        .padding(4)
        .background(
            Color.white.opacity(0.04),
            in: RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
    }
}

// MARK: - Preview

#Preview {
    struct Host: View {
        @State private var mode = "Quick"
        var body: some View {
            ZStack {
                Theme.bgPrimary.ignoresSafeArea()
                VStack(spacing: 20) {
                    ModeSwitcher(options: ["Quick", "Deep"], title: { $0 }, selection: $mode)
                        .frame(width: 240)
                    HStack(spacing: 8) {
                        StatusBadge(kind: .safe)
                        StatusBadge(kind: .caution)
                        StatusBadge(kind: .neutral)
                    }
                }
                .padding(40)
            }
        }
    }
    return Host()
}
