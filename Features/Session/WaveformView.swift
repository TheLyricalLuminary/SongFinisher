import SwiftUI

/// Live amplitude history, rendered as a scrolling bar meter (docs/ARCHITECTURE.md §6:
/// "TimelineView + Canvas, 30 fps"). The DSP layer only exposes energy/voicing per 10 ms
/// frame, not raw samples, so this reads as a level history rather than a true oscilloscope.
struct WaveformView: View {
    let energyHistory: [Float]
    let isVoiced: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
            Canvas { context, size in
                guard !energyHistory.isEmpty else { return }
                let barColor = isVoiced ? Color.accentColor : Color.secondary.opacity(0.5)
                let count = energyHistory.count
                let slot = size.width / CGFloat(Self.maxBars)
                let barWidth = max(1.5, slot * 0.6)
                let startIndex = max(0, count - Self.maxBars)

                for i in startIndex..<count {
                    let level = min(1, CGFloat(energyHistory[i]) * 8)
                    let barHeight = max(2, level * size.height)
                    let x = CGFloat(i - startIndex) * slot + (slot - barWidth) / 2
                    let rect = CGRect(x: x, y: (size.height - barHeight) / 2, width: barWidth, height: barHeight)
                    context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(barColor))
                }
            }
        }
        .frame(height: 64)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Input level")
        .accessibilityValue(isVoiced ? "hearing your melody" : "quiet")
    }

    private static let maxBars = 80
}

#Preview {
    WaveformView(energyHistory: (0..<80).map { i in Float(abs(sin(Double(i) * 0.2))) * 0.1 }, isVoiced: true)
        .padding()
}
