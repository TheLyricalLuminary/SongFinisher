import SwiftUI

/// The app's brand palette, defined once so every screen pulls from the same values.
/// `brand` mirrors the AccentColor asset — views that need the color in code (gradients,
/// Canvas) can't read an asset-catalog accent on both platforms, so the values live here
/// and the asset is generated to match.
extension Color {
    /// Slate indigo — the identity color (mic button, accents, onboarding).
    static let brand = Color(red: 0.35, green: 0.4, blue: 0.55)

    /// A deeper shade of `brand` for gradient bottoms and pressed states.
    static let brandDeep = Color(red: 0.24, green: 0.28, blue: 0.42)
}

/// The standard full-screen backdrop: brand-tinted in light mode, near-black indigo in
/// dark mode. Applied via `.appBackground()` so the tint is one modifier everywhere.
private struct AppBackgroundModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(backgroundColor.ignoresSafeArea())
    }

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color(.sRGB, red: 0.051, green: 0.059, blue: 0.102)
            : Color(.sRGB, red: 0.956, green: 0.96, blue: 0.98)
    }
}

extension View {
    func appBackground() -> some View {
        modifier(AppBackgroundModifier())
    }
}
