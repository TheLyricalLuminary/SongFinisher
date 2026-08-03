#if canImport(FoundationModels)
import Foundation
import FoundationModels
import Domain

/// The on-device Apple Intelligence conformance of `LyricProviding`: structured
/// generation via the Foundation Models framework (`LanguageModelSession` +
/// `@Generable`). Nothing leaves the device — the privacy story is architectural,
/// not a policy promise.
///
/// The model is never trusted for objective constraints: syllable counts and stress
/// alignments are recomputed on-device by `SyllableCounter` before ranking
/// (docs/ARCHITECTURE.md §9), exactly as they would be for any remote provider.
///
/// Failure policy: a musician mid-flow should never see an error banner because a
/// guardrail balked at one phrase. Any generation failure (except cancellation) falls
/// back to the deterministic offline assembler, whose candidates are honestly badged
/// `.offline` on the card.
@available(iOS 26.0, macOS 26.0, *)
public struct FoundationModelsLyricProvider: LyricProviding, Sendable {
    public let kind: ProviderKind = .appleIntelligence

    let fallback: OfflineLyricProvider

    public init(fallback: OfflineLyricProvider) {
        self.fallback = fallback
    }

    /// Composition-time gate: the framework can be linked yet the model unavailable
    /// (ineligible hardware, Apple Intelligence disabled, model still downloading).
    public static var isModelAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Kicks off the system model's asset load ahead of the first phrase. Foundation
    /// Models lazy-loads on first request, and that showed up in real sessions as
    /// several seconds of "finding a line that fits…" on the very first phrase — a
    /// cold start indistinguishable on screen from a slow generation. Sessions here
    /// are per-request and stateless, so the warmed session itself is discarded; the
    /// asset load it triggers is system-level and outlives it.
    public func prewarm() async {
        guard Self.isModelAvailable else { return }
        LanguageModelSession(instructions: FoundationModelsPromptBuilder.instructions()).prewarm()
    }

    public func candidates(for spec: PhraseSpec, memory: SessionMemory) async throws(LyricProviderError) -> [LyricCandidate] {
        do {
            // A fresh session per request: providers are stateless Sendable structs
            // (docs/ARCHITECTURE.md §10); all cross-phrase continuity travels in the
            // prompt via SessionMemory, so there is no conversation state to keep.
            let session = LanguageModelSession(instructions: FoundationModelsPromptBuilder.instructions())
            let response = try await session.respond(
                to: FoundationModelsPromptBuilder.prompt(for: spec, memory: memory),
                generating: GeneratedLyricBatch.self
            )
            let candidates = Self.candidates(from: response.content, spec: spec)
            guard !candidates.isEmpty else {
                return try await fallback.candidates(for: spec, memory: memory)
            }
            return candidates
        } catch is CancellationError {
            throw .cancelled
        } catch let error as LyricProviderError {
            throw error
        } catch {
            // Guardrail refusal, context overflow, model unloaded mid-session, etc.
            return try await fallback.candidates(for: spec, memory: memory)
        }
    }

    /// Model output → Domain candidates: trim, drop empties and duplicates, and
    /// recount syllables/stress on-device. Only the two genuinely subjective scores
    /// (emotional fit, memorability) are taken from the model's self-report.
    static func candidates(from batch: GeneratedLyricBatch, spec: PhraseSpec) -> [LyricCandidate] {
        var seen = Set<String>()
        var out: [LyricCandidate] = []
        for line in batch.lines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, seen.insert(text.lowercased()).inserted else { continue }
            let analysis = SyllableCounter.analyze(line: text)
            guard analysis.syllableCount > 0 else { continue }
            out.append(LyricCandidate(
                phraseID: spec.phraseID,
                text: text,
                syllableCount: analysis.syllableCount,
                stressAlignment: analysis.stressPattern,
                provider: .appleIntelligence,
                modelScores: ModelScores(emotionalFit: line.emotionalFit, memorability: line.memorability)
            ))
        }
        return out
    }
}

/// The structured output contract. Guided generation constrains decoding to this
/// shape, so there is no JSON parsing and no malformed-response path.
@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GeneratedLyricBatch {
    @Guide(description: "Exactly 8 distinct candidate lyric lines", .count(8))
    var lines: [GeneratedLyricLine]
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GeneratedLyricLine {
    @Guide(description: "One singable lyric line: plain words only, no quotes, numbering, or stage directions")
    var text: String
    @Guide(description: "Self-assessed fit to the requested emotion, 0 to 1")
    var emotionalFit: Double
    @Guide(description: "Self-assessed memorability as a sung hook, 0 to 1")
    var memorability: Double
}
#endif
