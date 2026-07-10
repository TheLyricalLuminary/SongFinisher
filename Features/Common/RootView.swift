import SwiftUI
import Domain

/// Routes to `SessionView`, the main "Listening…" screen (docs/ARCHITECTURE.md §6,
/// Phase 4's offline loop: capture → phrase → prosody → offline lyrics → ranking).
/// `DiagnosticCaptureView` — the Task 4 real-hardware validation tool this was built
/// alongside — stays reachable in DEBUG builds only, for judging raw DSP quality
/// without any lyric generation in the loop.
struct RootView: View {
    let services: AppServices
    #if DEBUG
    @State private var showDiagnostics = false
    #endif

    var body: some View {
        #if DEBUG
        ZStack(alignment: .topTrailing) {
            if showDiagnostics {
                DiagnosticCaptureView(services: services)
            } else {
                SessionView(services: services)
            }
            Button {
                showDiagnostics.toggle()
            } label: {
                Image(systemName: "wrench.and.screwdriver")
                    .padding(8)
                    .background(.thinMaterial, in: Circle())
            }
            .padding()
            .accessibilityLabel(showDiagnostics ? "Show session view" : "Show DSP diagnostics")
        }
        #else
        SessionView(services: services)
        #endif
    }
}

#Preview {
    RootView(services: .fakes())
}
