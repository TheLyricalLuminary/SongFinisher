import SwiftUI
import Domain

struct RootView: View {
    let services: AppServices

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                Text("Song Finisher")
                    .font(.largeTitle.bold())
                Text("Play a melody. Get lyrics that fit.")
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("")
        }
    }
}

#Preview {
    RootView(services: .fakes())
}
