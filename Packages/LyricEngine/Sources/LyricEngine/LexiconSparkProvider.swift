import Foundation
import Domain

/// The `SparkProviding` conformance: surfaces evocative words and rhymes from the
/// bundled lexicon. This is deliberately *not* a line generator — it hands the
/// songwriter raw material (strong words that fit the feeling and beat, rhymes for
/// their last line) and lets them write the line. A word-level assembler can't
/// guarantee meaning; a curated set of evocative single words is meaningful by
/// construction, so this is what the offline tier can honestly offer.
public struct LexiconSparkProvider: SparkProviding, Sendable {
    let store: LexiconStore

    /// Words below this Zipf are too obscure to be useful; above it, too plain
    /// ("thing", "get", "day"). The band in between is where evocative, singable
    /// vocabulary lives.
    static let minZipf = 2.8
    static let maxZipf = 5.0
    /// Freshness peak: words near this Zipf are preferred (known but not worn out).
    static let freshnessPeak = 3.6
    static let maxSyllables = 3
    static let imageCount = 6
    static let rhymeCount = 6
    /// No more than this many images may share a primary part of speech, so the set
    /// is a mix of nouns / verbs / adjectives rather than six adjectives.
    static let maxPerPOS = 3

    public init(store: LexiconStore) {
        self.store = store
    }

    public static func bundled() throws -> LexiconSparkProvider {
        LexiconSparkProvider(store: try LexiconStore.bundled())
    }

    public func sparks(for spec: PhraseSpec, memory: SessionMemory) -> WordSparks {
        WordSparks(
            images: imageWords(for: spec, memory: memory),
            rhymes: rhymeWords(for: memory)
        )
    }

    // MARK: - Evocative words

    private func imageWords(for spec: PhraseSpec, memory: SessionMemory) -> [String] {
        let target = PhraseAssembler.targetValence(for: spec)
        var rng = SeededRandom(seed: Self.seed(for: spec, memory: memory))

        // Words already used this session are stale as fresh sparks.
        var used = Set(memory.acceptedLines.flatMap { line in
            SyllableCounter.words(in: line.text)
        })

        var scored: [(text: String, pos: POSCategory, score: Double)] = []
        for i in 0..<store.count {
            let entry = store[i]
            guard entry.syllables >= 1, entry.syllables <= Self.maxSyllables,
                  entry.zipf >= Self.minZipf, entry.zipf <= Self.maxZipf,
                  !entry.pos.isDisjoint(with: .contentWord),
                  !PhraseAssembler.contentSlotStopWords.contains(entry.text),
                  entry.text.allSatisfy({ $0.isLetter }) else { continue }

            let emotionFit = -abs(entry.valence - target)
            let freshness = -abs(entry.zipf - Self.freshnessPeak)
            let jitter = Double(rng.next() % 100) / 250.0
            scored.append((entry.text, entry.pos, emotionFit + freshness + jitter))
        }
        scored.sort { $0.score > $1.score }

        var out: [String] = []
        var perPOS: [UInt16: Int] = [:]
        for candidate in scored {
            guard out.count < Self.imageCount else { break }
            guard !used.contains(candidate.text) else { continue }
            let posKey = candidate.pos.intersection(.contentWord).rawValue
            let count = perPOS[posKey, default: 0]
            guard count < Self.maxPerPOS else { continue }
            perPOS[posKey] = count + 1
            used.insert(candidate.text)
            out.append(candidate.text)
        }
        return out
    }

    // MARK: - Rhymes

    private func rhymeWords(for memory: SessionMemory) -> [String] {
        guard let lastLine = memory.acceptedLines.last,
              let lastWord = SyllableCounter.words(in: lastLine.text).last,
              let seed = store.lookup(lastWord), seed.rhymeKey != 0 else {
            return []
        }

        var scored: [(text: String, score: Double)] = []
        for i in 0..<store.count {
            let entry = store[i]
            guard entry.rhymeKey == seed.rhymeKey, entry.text != seed.text,
                  entry.zipf >= Self.minZipf, entry.zipf <= Self.maxZipf,
                  entry.text.allSatisfy({ $0.isLetter }) else { continue }
            // Prefer content-word rhymes, then freshness.
            let contentBonus = entry.pos.isDisjoint(with: .contentWord) ? 0.0 : 1.0
            scored.append((entry.text, contentBonus - abs(entry.zipf - Self.freshnessPeak)))
        }
        scored.sort { $0.score > $1.score }
        return Array(scored.prefix(Self.rhymeCount).map(\.text))
    }

    /// Deterministic per (phrase, session progress) so a given phrase yields a stable
    /// spark set, but a later phrase in the same session varies.
    private static func seed(for spec: PhraseSpec, memory: SessionMemory) -> UInt64 {
        var s = Seeding.fnv(spec.phraseID.uuidString)
        s ^= Seeding.fnv("sparks:\(memory.acceptedLines.count):\(memory.rejected.count)")
        return s
    }
}
