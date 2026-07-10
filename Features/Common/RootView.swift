import SwiftUI
import Domain

/// Temporarily routes straight to the Task 4 DSP diagnostic tool (real-hardware
/// validation of MelodyKit's pitch/onset/segmentation on the Scarlett Solo) while
/// the main product UI (permission gate → SessionView) is still being built.
struct RootView: View {
    let services: AppServices

    var body: some View {
        DiagnosticCaptureView(services: services)
    }
}

#Preview {
    RootView(services: .fakes())
}
