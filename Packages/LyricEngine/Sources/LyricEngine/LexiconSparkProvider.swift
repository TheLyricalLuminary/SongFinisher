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
        let emotion = spec.requestedEmotionOverride ?? spec.topEmotions.first?.emotion ?? .reflection
        let triggerWords = TriggerWordBank.words(for: emotion)
        var rng = SeededRandom(seed: Self.seed(for: spec, memory: memory, emotion: emotion))

        // Words already used this session are stale as fresh sparks.
        var used = Set(memory.acceptedLines.flatMap { line in
            SyllableCounter.words(in: line.text)
        })

        // Two tiers filled in order, rather than one score with a "curated" constant
        // added on. Statistics alone rank "blockbuster", "heroine" and "brilliantly" as
        // great Joy words — high VADER score, right freshness band — but no songwriter
        // reaches for them; the book's Trigger Word Library is the missing signal. And
        // because every word in that library is already appropriate for the state,
        // ranking *within* it matters far less than variety does: a bonus large enough
        // to guarantee curation wins also freezes the order, so the same six words come
        // back phrase after phrase. Shuffling the curated tier instead keeps curation
        // absolute and still turns the vocabulary over across a session.
        var curated: [(String, POSCategory)] = []
        var statistical: [(text: String, pos: POSCategory, score: Double)] = []
        for i in 0..<store.count {
            let entry = store[i]
            guard entry.syllables >= 1, entry.syllables <= Self.maxSyllables,
                  entry.zipf >= Self.minZipf, entry.zipf <= Self.maxZipf,
                  !entry.pos.isDisjoint(with: .contentWord),
                  !PhraseAssembler.contentSlotStopWords.contains(entry.text),
                  // Sparks are shown to the songwriter as raw material, so they need the
                  // same guards the assembler applies to content slots: never surface
                  // profanity, and never a single letter (the lexicon tags "l" a noun).
                  !PhraseAssembler.excludedContentWords.contains(entry.text),
                  entry.text.count > 1,
                  entry.text.allSatisfy({ $0.isLetter }) else { continue }

            if triggerWords.contains(entry.text) {
                curated.append((entry.text, entry.pos))
            } else {
                let emotionFit = -abs(entry.valence - target)
                let freshness = -abs(entry.zipf - Self.freshnessPeak)
                statistical.append((entry.text, entry.pos, emotionFit + freshness))
            }
        }
        curated.shuffle(using: &rng)
        statistical.sort { $0.score > $1.score }

        var out: [String] = []
        var perPOS: [UInt16: Int] = [:]
        for (text, pos) in curated + statistical.map({ ($0.text, $0.pos) }) {
            guard out.count < Self.imageCount else { break }
            guard !used.contains(text) else { continue }
            let posKey = pos.intersection(.contentWord).rawValue
            let count = perPOS[posKey, default: 0]
            guard count < Self.maxPerPOS else { continue }
            perPOS[posKey] = count + 1
            used.insert(text)
            out.append(text)
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

    /// Deterministic per (phrase, session progress, emotion) so a given phrase yields a
    /// stable spark set, but a later phrase in the same session varies.
    ///
    /// The emotion belongs in the seed because the book's five emotional states cover the
    /// app's eight emotions: melancholy, longing and nostalgia all draw on
    /// `heartbreakHold`, and joy and release both draw on `joyfulRelease`. Seeding on the
    /// phrase alone made those pairs shuffle identically, so "Different Emotion" — a
    /// button the session screen offers — visibly did nothing for five of the eight.
    /// Seeding on the emotion too draws a different sample from the same curated pool,
    /// which keeps faith with the book's mapping while making the control honest.
    private static func seed(for spec: PhraseSpec, memory: SessionMemory, emotion: Emotion) -> UInt64 {
        var s = Seeding.fnv(spec.phraseID.uuidString)
        s ^= Seeding.fnv("sparks:\(memory.acceptedLines.count):\(memory.rejected.count):\(emotion.rawValue)")
        return s
    }
}
