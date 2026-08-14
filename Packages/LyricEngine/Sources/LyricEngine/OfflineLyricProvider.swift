import Foundation
import Domain

/// The deterministic offline `LyricProviding` conformance (Task 2). Generates by
/// constraint-satisfaction over the bundled lexicon — no network, no LLM. Answers in
/// well under the phrase's suggestion budget and always returns at least one
/// candidate for any 1–12 syllable phrase, widening within the spec's own tolerance
/// before giving up (mirrors the honest-degradation contract already used for the
/// syllable budget itself).
public struct OfflineLyricProvider: LyricProviding, Sendable {
    public let kind: ProviderKind = .offline

    let store: LexiconStore
    let index: StressPatternIndex
    let assembler: PhraseAssembler

    public init(store: LexiconStore) {
        self.store = store
        self.index = StressPatternIndex(store: store)
        self.assembler = PhraseAssembler(store: store, index: index)
    }

    /// Loads the bundled lexicon (memory-mapped) and builds the index.
    public static func bundled() throws -> OfflineLyricProvider {
        OfflineLyricProvider(store: try LexiconStore.bundled())
    }

    public func candidates(for spec: PhraseSpec, memory: SessionMemory) async throws(LyricProviderError) -> [LyricCandidate] {
        let seed = Self.seed(for: spec, memory: memory)
        let target = max(1, spec.budget.target)

        var pool: [AssembledLine] = []
        var tried = Set<Int>()
        for delta in Self.searchOrder(tolerance: spec.budget.tolerance) {
            let n = target + delta
            guard n >= 1 else { continue }
            tried.insert(n)
            pool.append(contentsOf: assembler.assemble(
                spec: spec,
                syllableTarget: n,
                seed: seed &+ UInt64(bitPattern: Int64(delta)),
                poolTarget: 60
            ))
            if pool.count >= 60 { break }
        }

        // Last resort: widen past the phrase's own tolerance rather than break the
        // documented "always returns at least one candidate" contract. Same
        // honest-degradation idea as the tolerance widening itself, one step further.
        //
        // This used to run routinely, because the shortest template frame needed three
        // syllables and a confident 1–2-syllable budget — one strum on Sparse density, a
        // two-note hum — starved with nothing upstream wrong. It then answered a different
        // question than the one asked, silently, handing back a three-syllable line. The
        // bank now covers 1–2 directly (`Templates.swift`), so reaching this is a real
        // coverage gap rather than a known hole being papered over.
        if pool.isEmpty {
            for n in 1...12 where !tried.contains(n) {
                pool.append(contentsOf: assembler.assemble(
                    spec: spec,
                    syllableTarget: n,
                    seed: seed &+ UInt64(bitPattern: Int64(n - target)),
                    poolTarget: 60
                ))
                if !pool.isEmpty { break }
            }
        }

        guard !pool.isEmpty else {
            throw LyricProviderError.invalidResponse("offline assembler produced no candidates for a \(target)-syllable budget")
        }

        let picked: [AssembledLine]
        if let seedText = spec.variationSeedText {
            picked = Self.selectVariations(of: seedText, from: pool, count: 5)
        } else {
            picked = SuggestionRanker.select(from: pool, count: 5)
        }

        return picked.map { line in
            LyricCandidate(
                phraseID: spec.phraseID,
                text: line.text,
                syllableCount: line.syllables,
                stressAlignment: line.stressPattern,
                provider: .offline,
                repaired: false,
                modelScores: ModelScores(emotionalFit: line.emotionScore, memorability: 0.5)
            )
        }
    }

    /// Deterministic per (phrase, regenerate-count, emotion-override, variation-seed).
    /// `memory.rejected.count` grows by one on every Regenerate — the same counter the
    /// architecture already threads through the session — so repeated taps on the same
    /// phrase walk to fresh candidates without any new protocol surface.
    static func seed(for spec: PhraseSpec, memory: SessionMemory) -> UInt64 {
        var s = Seeding.fnv(spec.phraseID.uuidString)
        s ^= Seeding.fnv("attempt:\(memory.rejected.count)")
        if let override = spec.requestedEmotionOverride { s ^= Seeding.fnv("emotion:\(override.rawValue)") }
        if let seedText = spec.variationSeedText { s ^= Seeding.fnv("variation:\(seedText)") }
        return s
    }

    /// 0, then ±1, ±2, … out to `tolerance` — the same range `SyllableBudget.contains`
    /// accepts, searched center-out so the exact target is always tried first.
    static func searchOrder(tolerance: Int) -> [Int] {
        var order = [0]
        guard tolerance > 0 else { return order }
        for d in 1...tolerance { order.append(d); order.append(-d) }
        return order
    }

    /// "More Like This": rank by quality plus content-word overlap with the exemplar,
    /// instead of MMR's diversity penalty — the whole point is staying close.
    static func selectVariations(of seedText: String, from pool: [AssembledLine], count: Int) -> [AssembledLine] {
        let seedWords = Set(seedText.lowercased().split(separator: " ").map(String.init))
        let ranked = pool.sorted { a, b in
            (SuggestionRanker.quality(a) + overlapBonus(a, seedWords))
                > (SuggestionRanker.quality(b) + overlapBonus(b, seedWords))
        }
        return Array(ranked.prefix(count))
    }

    private static func overlapBonus(_ line: AssembledLine, _ seedWords: Set<String>) -> Double {
        guard !seedWords.isEmpty else { return 0 }
        return Double(line.contentWords.intersection(seedWords).count) * 0.15
    }
}
