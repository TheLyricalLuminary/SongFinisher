import Foundation
import Domain
@testable import LyricEngine

/// Shared fixtures: the bundled lexicon loads once per process (it's read-only and
/// large enough that reloading per-test would slow the suite for no benefit).
enum Fixtures {
    static let store: LexiconStore = {
        do {
            return try LexiconStore.bundled()
        } catch {
            fatalError("failed to load bundled lexicon in tests: \(error)")
        }
    }()

    static let index = StressPatternIndex(store: store)
    static let assembler = PhraseAssembler(store: store, index: index)

    static func spec(
        syllables: Int,
        stress: String,
        emotion: Emotion = .longing,
        tolerance: Int = 1,
        longSlots: [Int] = [],
        variationSeedText: String? = nil,
        emotionOverride: Emotion? = nil,
        phraseID: UUID = UUID()
    ) -> PhraseSpec {
        let map = StressMap.parse(stress) ?? StressMap(pattern: Array(repeating: .weak, count: syllables))
        return PhraseSpec(
            phraseID: phraseID,
            budget: SyllableBudget(target: syllables, tolerance: tolerance, stressMap: map),
            emotions: [EmotionScore(emotion: emotion, confidence: 1.0)],
            tempoBPM: 92, tempoConfidence: 0.8, contourShape: .falling,
            noteDurationsMs: Array(repeating: 400, count: syllables),
            longNoteSlots: longSlots,
            phraseDuration: Double(syllables) * 0.4,
            requestedEmotionOverride: emotionOverride,
            variationSeedText: variationSeedText
        )
    }
}
