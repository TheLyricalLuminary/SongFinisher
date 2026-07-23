import Foundation
import Domain
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device generation via Apple's Foundation Models framework (iOS/macOS 26+, and only on
/// Apple-Intelligence-eligible hardware with the feature enabled). Wraps `OfflineLyricProvider`
/// as a fallback — older devices, disabled Apple Intelligence, or any generation failure all
/// degrade to the deterministic template engine rather than surfacing an error, the same
/// honest-degradation contract the rest of the pipeline already follows. Downstream, nothing
/// changes: `CandidateRanker` recomputes syllables/stress on-device for every candidate
/// regardless of provider (docs/ARCHITECTURE.md §9), so a generated line is trusted exactly as
/// much as a templated one.
public struct OnDeviceLyricProvider: LyricProviding, Sendable {
    public let kind: ProviderKind = .onDevice

    private let fallback: OfflineLyricProvider

    public init(fallback: OfflineLyricProvider) {
        self.fallback = fallback
    }

    public func candidates(for spec: PhraseSpec, memory: SessionMemory) async throws(LyricProviderError) -> [LyricCandidate] {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *),
           let generated = try? await Self.generateOnDevice(spec: spec, memory: memory),
           !generated.isEmpty {
            return generated
        }
        #endif
        return try await fallback.candidates(for: spec, memory: memory)
    }

    // MARK: - Prompt building
    //
    // Pure string-building over `Domain` types only — no FoundationModels symbols — so this
    // stays testable on any OS/hardware, independent of Apple Intelligence availability.

    static let instructions = """
    You are a concise songwriting collaborator. Given a musical phrase's shape — its syllable \
    count, stress pattern, tempo, and emotional tone — write short, singable lyric lines that \
    fit that shape exactly. Prefer plain, concrete, contemporary language over clichés. Output \
    only the line itself: no quotation marks, no line numbers, no explanations.
    """

    static func buildPrompt(spec: PhraseSpec, memory: SessionMemory) -> String {
        var lines: [String] = []
        lines.append("Write 5 distinct candidate lyric lines for one musical phrase.")
        lines.append("Target syllable count: \(spec.budget.target) (tolerance ±\(spec.budget.tolerance)).")
        lines.append("Stress pattern (S = strong, w = weak): \(spec.budget.stressMap.pattern.map(\.rawValue).joined()).")
        lines.append("Tempo: \(Int(spec.tempoBPM.rounded())) BPM, melodic contour: \(spec.contourShape.rawValue).")

        if let emotion = spec.requestedEmotionOverride {
            lines.append("Requested emotion: \(emotion.rawValue).")
        } else if let top = spec.topEmotions.first {
            lines.append("Dominant emotion of this phrase: \(top.emotion.rawValue).")
        }

        if let chord = spec.chord, chord.isReliable {
            let lean = chord.quality.isMinorLike ? "minor-leaning" : "major-leaning"
            lines.append("Harmony under this phrase: \(chord.displayName) (\(lean)).")
        }

        if let seedText = spec.variationSeedText {
            lines.append("Stay close in imagery and theme to this line: \"\(seedText)\".")
        }

        if !memory.promptThemes.isEmpty {
            lines.append("Recurring themes in this song so far: \(memory.promptThemes.joined(separator: ", ")).")
        }
        if let dominant = memory.dominantEmotion {
            lines.append("The song's overall emotional register so far: \(dominant.rawValue).")
        }
        if !memory.promptAcceptedLines.isEmpty {
            let accepted = memory.promptAcceptedLines.map { "\"\($0.text)\"" }.joined(separator: "; ")
            lines.append("Lines already accepted in this song — stay consistent with their voice: \(accepted).")
        }
        if !memory.promptRejected.isEmpty {
            let rejected = memory.promptRejected.map { "\"\($0.text)\"" }.joined(separator: "; ")
            lines.append("Lines already rejected — do not repeat these or very similar phrasing: \(rejected).")
        }

        return lines.joined(separator: "\n")
    }
}

#if canImport(FoundationModels)

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GeneratedLyricLine {
    @Guide(description: "A single singable lyric line — plain text, no quotation marks, no line numbers")
    var text: String
    @Guide(description: "How well this line matches the requested emotional tone, 0.0 (not at all) to 1.0 (perfectly)")
    var emotionalFit: Double
    @Guide(description: "How memorable and hooky this line is on its own, 0.0 to 1.0")
    var memorability: Double
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GeneratedLyricBatch {
    @Guide(description: "Exactly 5 distinct candidate lyric lines for the same musical phrase")
    var lines: [GeneratedLyricLine]
}

@available(iOS 26.0, macOS 26.0, *)
extension OnDeviceLyricProvider {
    static func generateOnDevice(spec: PhraseSpec, memory: SessionMemory) async throws -> [LyricCandidate] {
        guard case .available = SystemLanguageModel.default.availability else { return [] }

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: buildPrompt(spec: spec, memory: memory), generating: GeneratedLyricBatch.self)

        return response.content.lines.compactMap { line in
            let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let analysis = SyllableCounter.analyze(line: trimmed)
            return LyricCandidate(
                phraseID: spec.phraseID,
                text: trimmed,
                syllableCount: analysis.syllableCount,
                stressAlignment: analysis.stressPattern,
                provider: .onDevice,
                repaired: false,
                modelScores: ModelScores(emotionalFit: line.emotionalFit, memorability: line.memorability)
            )
        }
    }
}

#endif
