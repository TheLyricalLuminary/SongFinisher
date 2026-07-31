import SwiftUI
import Domain

/// The app's root (docs/ARCHITECTURE.md §6): the song library is home, and everything —
/// starting a session, reopening a draft, reading the finished sheet, the DSP diagnostics
/// tool — hangs off it. `SongListView` owns the `NavigationStack` and routing; this stays a
/// thin seam so the composition root has a single view to hand `services` to. The one
/// exception is first-run onboarding, gated here since it has to intercept every route.
struct RootView: View {
    let services: AppServices
    /// `nil` = unmetered (previews, Mac validation builds without a store).
    var proStore: ProStore? = nil

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        if hasCompletedOnboarding {
            SongListView(services: services, proStore: proStore)
        } else {
            OnboardingView(onFinish: { hasCompletedOnboarding = true })
        }
    }
}

#Preview {
    RootView(services: .fakes())
}
