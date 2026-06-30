import SwiftUI

/// Shared visual building blocks, styled for macOS 26 (Tahoe). Where the new Liquid Glass APIs
/// exist we use them; on earlier systems we fall back to standard materials/controls so the app
/// still builds and looks right below the 26 deployment floor.

// MARK: - Glass / material card

private struct CardBackground: ViewModifier {
    var cornerRadius: CGFloat = 12
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.padding(10).glassEffect(in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

extension View {
    /// A subtly elevated card — Liquid Glass on Tahoe, material elsewhere.
    func cardBackground(cornerRadius: CGFloat = 12) -> some View {
        modifier(CardBackground(cornerRadius: cornerRadius))
    }
}

// MARK: - Button styles with graceful fallback

private struct ProminentGlassButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

private struct GlassButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

extension View {
    func prominentGlassButton() -> some View { modifier(ProminentGlassButton()) }
    func glassButton() -> some View { modifier(GlassButton()) }
}

// MARK: - Section header

/// A compact, HIG-style group header: small uppercase caption with a leading symbol.
struct SectionHeader: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            Text(title.uppercased())
                .tracking(0.6)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
    }
}

// MARK: - App icon badge

/// The rounded, accent-tinted app glyph used in the popover header.
struct AppGlyph: View {
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(Color.accentColor.gradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "rectangle.grid.2x2.fill")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .shadow(color: .accentColor.opacity(0.25), radius: 3, y: 1)
    }
}
