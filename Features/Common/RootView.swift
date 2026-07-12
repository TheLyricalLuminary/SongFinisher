import SwiftUI
import Domain

/// Routes to the main product screen. The permission gate → SongListView shell from
/// docs/ARCHITECTURE.md §6 is a later phase; this goes straight to SessionView, the same
/// way it went straight to the diagnostic tool before SessionView existed.
struct RootView: View {
    let services: AppServices

    @State private var showsDiagnostics = false

    var body: some View {
        NavigationStack {
            SessionView(services: services)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showsDiagnostics = true
                        } label: {
                            Image(systemName: "waveform.path.ecg")
                        }
                        .accessibilityLabel("DSP diagnostic tool")
                    }
                }
        }
        .sheet(isPresented: $showsDiagnostics) {
            DiagnosticCaptureView(services: services)
                // Plain macOS sheets have no built-in close affordance (no Escape,
                // no title bar) — this is the only way out without a toolbar close button.
                .overlay(alignment: .topTrailing) {
                    Button {
                        showsDiagnostics = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white, .black.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                }
        }
    }
}

#Preview {
    RootView(services: .fakes())
}
