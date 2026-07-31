import SwiftUI

/// First-run introduction: three short screens covering the pitch, the on-device privacy
/// story, and how to start. Shown once, gated by `RootView`'s `hasCompletedOnboarding` flag.
/// Pages are shown one at a time with a manual index rather than `TabView(.page)`, since this
/// view is also compiled into the macOS hardware-validation target, where the `.page` tab
/// style doesn't exist.
struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var page = 0

    private static let pages: [OnboardingPage] = [
        OnboardingPage(
            systemImage: "waveform",
            title: "Play a melody. Get lyrics that fit.",
            message: "Hum, sing, or plug in an instrument — Song Finisher listens to the shape of what you play and suggests lines that match its rhythm and mood."
        ),
        OnboardingPage(
            systemImage: "lock.shield",
            title: "Everything happens on your device",
            message: "Your melody is analyzed locally, in real time. Nothing is uploaded, and audio is never stored — only the lyrics you choose to keep."
        ),
        OnboardingPage(
            systemImage: "music.mic",
            title: "Start with any phrase",
            message: "Tap the mic and play a few bars. As soon as a phrase ends, you'll get lyric ideas sized to fit its syllables and stress."
        ),
    ]

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            OnboardingPageView(page: Self.pages[page])
                .id(page)
                .transition(.opacity)

            Spacer()

            HStack(spacing: 8) {
                ForEach(Self.pages.indices, id: \.self) { index in
                    Circle()
                        .fill(index == page ? Color.brand : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityHidden(true)

            Button(action: advance) {
                Text(isLastPage ? "Get Started" : "Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(.brand)
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
            .accessibilityLabel(isLastPage ? "Get Started" : "Continue to next screen")
        }
        .appBackground()
        .animation(.easeInOut, value: page)
    }

    private var isLastPage: Bool { page == Self.pages.count - 1 }

    private func advance() {
        if isLastPage {
            onFinish()
        } else {
            page += 1
        }
    }
}

private struct OnboardingPage {
    let systemImage: String
    let title: String
    let message: String
}

private struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: page.systemImage)
                .font(.system(size: 60, weight: .medium))
                .foregroundStyle(Color.brand)
                .frame(height: 80)

            Text(page.title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)

            Text(page.message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 36)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    OnboardingView(onFinish: {})
}
