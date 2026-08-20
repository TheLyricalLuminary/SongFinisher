import Foundation
import Domain

/// Builds the instructions and per-phrase prompt for the on-device Foundation Models
/// provider. Pure string assembly — no framework imports — so prompt content stays unit
/// testable on any platform and golden-testable like the DSP fixtures
/// (docs/ARCHITECTURE.md §11).
enum FoundationModelsPromptBuilder {

    /// Session-stable role and rules. Kept separate from the per-phrase prompt so the
    /// runtime treats it as trusted instructions rather than as user input, and so
    /// `ModelWarmer` can prewarm against exactly the instructions requests will use.
    static func instructions() -> String {
        """
        You are a lyric-writing collaborator inside a songwriting app. The singer just \
        performed a musical phrase; you write candidate lyric lines that can be sung on \
        that exact phrase.

        Rules:
        - Write natural, singable lines with concrete imagery. Avoid clichés and filler.
        - Match the requested syllable count as exactly as possible.
        - Put naturally stressed syllables where the stress pattern marks S; unstressed \
        syllables where it marks w.
        - Where a sustained note is flagged, prefer an open vowel (ah, oh, ay, ee) on \
        that syllable so it can be held.
        - Stay consistent with the song's accepted lines, themes, and emotion.
        - Never produce a line the singer has already rejected, or a trivial rewording \
        of one.
        - Each candidate must be distinct in imagery, not just word order.
        """
    }

    /// The per-phrase request: the spec's constraints plus the capped session memory
    /// (docs/ARCHITECTURE.md §9 memory caps keep this small and cache-friendly).
    static func prompt(for spec: PhraseSpec, memory: SessionMemory) -> String {
        var sections: [String] = []

        var phrase = "Write 8 candidate lyric lines for this phrase.\n\nPHRASE:\n"
        let budget = spec.budget
        if budget.tolerance > 0 {
            phrase += "- Syllables: \(budget.target) (acceptable: \(budget.range.lowerBound)–\(budget.range.upperBound))\n"
        } else {
            phrase += "- Syllables: exactly \(budget.target)\n"
        }
        if !budget.stressMap.pattern.isEmpty {
            phrase += "- Stress pattern: \(budget.stressMap.display)  (S = stressed, w = unstressed)\n"
        }
        let emotion: String
        if let override = spec.requestedEmotionOverride {
            emotion = override.rawValue
        } else {
            emotion = spec.topEmotions.map { "\($0.emotion.rawValue) (\(String(format: "%.2f", $0.confidence)))" }
                .joined(separator: ", ")
        }
        if !emotion.isEmpty { phrase += "- Emotion: \(emotion)\n" }
        if spec.tempoBPM > 0, spec.tempoConfidence > 0.35 {
            phrase += "- Tempo: \(Int(spec.tempoBPM.rounded())) BPM\n"
        }
        phrase += "- Melodic contour: \(spec.contourShape.rawValue)\n"
        if !spec.longNoteSlots.isEmpty {
            let slots = spec.longNoteSlots.map { String($0 + 1) }.joined(separator: ", ")
            phrase += "- Sustained notes on syllable(s) \(slots): favor open vowels there.\n"
        }
        sections.append(phrase)

        var song = ""
        let accepted = memory.promptAcceptedLines
        if !accepted.isEmpty {
            song += "Accepted lines so far:\n" + accepted.map { "- \($0.text)" }.joined(separator: "\n") + "\n"
        }
        if let hook = memory.hookLine { song += "Hook: \(hook)\n" }
        if !memory.promptThemes.isEmpty { song += "Themes: \(memory.promptThemes.joined(separator: ", "))\n" }
        if let dominant = memory.dominantEmotion { song += "Dominant emotion: \(dominant.rawValue)\n" }
        if !song.isEmpty { sections.append("SONG SO FAR:\n" + song) }

        let rejected = memory.promptRejected
        if !rejected.isEmpty {
            sections.append("DO NOT produce these rejected lines or close variants:\n"
                + rejected.map { "- \($0.text)" }.joined(separator: "\n"))
        }

        if let seed = spec.variationSeedText {
            sections.append("The singer liked this line — stay close to its imagery and voice:\n\"\(seed)\"")
        }

        return sections.joined(separator: "\n")
    }
}
