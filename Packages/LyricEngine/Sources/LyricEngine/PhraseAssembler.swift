import Foundation
import Domain

/// A fully assembled candidate line with its per-axis scores.
public struct AssembledLine: Sendable, Equatable {
    public let text: String
    public let syllables: Int
    public let stressPattern: [Stress]   // as pronounced, per the lexicon
    public let prosodyScore: Double      // 0…1: stress/vowel/cluster fit to the PhraseSpec
    public let fluencyScore: Double      // 0…1: word-frequency prior
    public let emotionScore: Double      // 0…1: valence distance to the target emotion
    public let contentWords: Set<String>
}

/// Constraint-satisfaction lyric assembly (Phase 4 Task 2): fills POS templates
/// left-to-right with beam search so the concatenated stress aligns to the
/// PhraseSpec stress map. Deterministic given a seed.
public struct PhraseAssembler: Sendable {
    let store: LexiconStore
    let index: StressPatternIndex

    static let beamWidth = 12
    static let candidatesPerSlot = 24    // top-Zipf slice examined per slot expansion
    /// Random picks drawn from *beyond* the top-Zipf head of each bucket, so evocative
    /// mid- and lower-frequency words reach the beam instead of only the most common
    /// (and most clichéd) ones sitting at the top.
    static let extraReach = 12
    /// The Zipf value scored as most "evocative": common enough to sing, uncommon
    /// enough not to be worn out ("the", "get", "thing"). Both very common and obscure
    /// words score below this.
    static let evocativePeak = 3.8
    static let fastNoteMs = 180

    /// Function words that must never fill a *content* slot (noun / plural noun /
    /// verb / adjective / adverb). The Moby POS data tags many of these with a content
    /// category too — "a" is tagged a noun (the letter, the grade, the note), "your" an
    /// adjective — and because they are the highest-frequency words in English they sit
    /// at the top of every Zipf-sorted bucket. Without this guard the beam fills a noun
    /// slot with "a" and an adjective slot with a determiner, collapsing a "lyric" into
    /// word salad like "during your several a". Closed-class literals in templates
    /// (subjects, articles, enders) are unaffected — only open-class POS slots filter.
    static let contentSlotStopWords: Set<String> = [
        "a", "a's", "an", "the", "and", "or", "but", "nor", "so", "yet",
        "of", "to", "in", "on", "at", "by", "for", "with", "as", "than", "then",
        "is", "was", "are", "were", "am", "be", "been", "being",
        "do", "does", "did", "done", "has", "have", "had", "having",
        "will", "would", "shall", "should", "can", "could", "may", "might", "must",
        "i", "you", "he", "she", "we", "they", "it", "me", "him", "us", "them",
        "my", "your", "his", "her", "its", "our", "their",
        "mine", "yours", "ours", "theirs", "hers", "myself", "yourself",
        "this", "that", "these", "those", "who", "whom", "whose", "which", "what",
        "not", "no", "if", "there", "here", "such", "very", "too",
    ]

    /// Never auto-suggested in a lyric line. Strictly profanity — emotionally dark
    /// vocabulary ("sin", "curse", "damned") stays, since dark songs need it. Without
    /// this, the valence-charged scoring below actively seeks these out for
    /// negative-emotion phrases (VADER scores them strongly), and "i dimension a piss"
    /// is not a suggestion; the songwriter can always type what they mean.
    static let excludedContentWords: Set<String> = [
        "piss", "pissed", "shit", "shitty", "fuck", "fucked", "fucking",
        "cum", "cock", "dick", "tits", "whore", "slut", "bitch", "bitches",
        "bastard", "asshole", "ass", "asses",
    ]

    /// Determiners that must not precede a plural noun (`isAcceptable`). Hoisted out of
    /// the loop that uses it — an array literal there re-allocates per adjacent pair.
    static let singularDeterminers: Set<String> = ["a", "an", "this", "that"]

    /// Lexicon row numbers for `contentSlotStopWords`, and for those plus
    /// `excludedContentWords` plus the single letters.
    ///
    /// These are membership tests in the beam search's innermost loop — roughly half a
    /// million evaluations per `assemble` call — and `Set<String>.contains` there means
    /// hashing a String every time, which an unoptimized build cannot inline away. Since
    /// every entry the beam ever sees comes out of the store, its row number identifies
    /// it just as well, so the sets are resolved to `Set<Int>` once here and the hot path
    /// only ever compares integers. Words absent from the lexicon simply contribute no
    /// row, which is the same outcome as never matching an entry's text.
    private let stopWordIDs: Set<Int>
    private let blockedContentIDs: Set<Int>

    public init(store: LexiconStore, index: StressPatternIndex) {
        self.store = store
        self.index = index

        let stopIDs = Set(Self.contentSlotStopWords.compactMap { store.lookup($0)?.index })
        var blocked = stopIDs
        blocked.formUnion(Self.excludedContentWords.compactMap { store.lookup($0)?.index })
        // Moby tags the single letters as nouns ("l" the letter) and they read as typos
        // in a lyric. One pass over the word table costs a few milliseconds at load and
        // is exact, where enumerating a…z would assume what a single-character row can be.
        for i in 0..<store.count where store.wordText(at: i).count == 1 {
            blocked.insert(i)
        }
        self.stopWordIDs = stopIDs
        self.blockedContentIDs = blocked
    }

    /// The subset of this emotion's trigger words that may actually take a content slot,
    /// as lexicon row numbers. Resolved once per `assemble` call so `positionScore` can
    /// collapse three checks (curated / content-word / not-a-stop-word) into one integer
    /// set lookup in its innermost loop.
    private func triggerWordIDs(for emotion: Emotion) -> Set<Int> {
        var ids = Set<Int>()
        for word in TriggerWordBank.words(for: emotion) {
            guard let entry = store.lookup(word),
                  !entry.pos.isDisjoint(with: .contentWord),
                  !stopWordIDs.contains(entry.index) else { continue }
            ids.insert(entry.index)
        }
        return ids
    }

    /// A slot category is "content" when it carries lexical stress and meaning
    /// (noun/verb/adjective/adverb) rather than being a closed-class function word.
    static func isContentCategory(_ category: POSCategory) -> Bool {
        !category.isDisjoint(with: .contentWord)
    }

    /// A finished line is only offered if it carries at least one real content word,
    /// does not end on a bare function word, and never repeats the same word twice —
    /// two POS slots of the same category in one template (e.g. the noun-and-noun
    /// frame) can otherwise beam-search their way to the same top-Zipf entry for both
    /// slots ("night and night alone"), which reads as broken as any word salad.
    /// Adjacent-pair grammar is also enforced: "a" never precedes a vowel-initial
    /// word ("a arch clause") and a singular determiner never precedes a plural
    /// ("rely a knives") — both reachable because Moby's noun tags cover plurals.
    func isAcceptable(_ line: AssembledLine) -> Bool {
        guard !line.contentWords.isEmpty else { return false }
        let words = line.text.split(separator: " ").map { String($0).lowercased() }
        guard let last = words.last else { return false }
        guard !Self.contentSlotStopWords.contains(last) else { return false }
        guard Set(words).count == words.count else { return false }

        for (word, next) in zip(words, words.dropFirst()) {
            if word == "a", let first = next.first, "aeiou".contains(first) { return false }
            if Self.singularDeterminers.contains(word), next.hasSuffix("s"),
               let entry = store.lookup(next), entry.pos.contains(.pluralNoun) {
                return false
            }
        }
        return true
    }

    /// Generates a pool of scored lines for `syllableTarget` syllables against the
    /// spec's stress map. Templates are tried in seeded-shuffled order.
    public func assemble(
        spec: PhraseSpec,
        syllableTarget: Int,
        seed: UInt64,
        poolTarget: Int
    ) -> [AssembledLine] {
        let pattern = padded(spec.budget.stressMap.pattern, to: syllableTarget)
        let longSlots = Set(spec.longNoteSlots)
        let targetValence = Self.targetValence(for: spec)
        let emotion = spec.requestedEmotionOverride ?? spec.topEmotions.first?.emotion ?? .reflection
        let triggerWords = triggerWordIDs(for: emotion)

        var rng = SeededRandom(seed: seed)
        var templates = TemplateBank.all.filter {
            syllableTarget >= $0.minSyllables && syllableTarget <= $0.maxSyllables
        }
        templates.shuffle(using: &rng)

        var pool: [AssembledLine] = []
        var seenTexts = Set<String>()

        for template in templates {
            guard pool.count < poolTarget else { break }
            let lines = fill(
                template: template,
                pattern: pattern,
                longSlots: longSlots,
                durations: spec.noteDurationsMs,
                targetValence: targetValence,
                triggerWords: triggerWords,
                rng: &rng
            )
            for line in lines where isAcceptable(line) && seenTexts.insert(line.text).inserted {
                pool.append(line)
            }
        }
        return pool
    }

    // MARK: - Beam search over one template

    private struct BeamState {
        var slotIndex: Int
        var syllablePosition: Int
        var entries: [LexiconStore.Entry]
        var positionalScore: Double
    }

    func fill(
        template: LyricTemplate,
        pattern: [Stress],
        longSlots: Set<Int>,
        durations: [Int],
        targetValence: Double,
        triggerWords: Set<Int> = [],
        rng: inout SeededRandom
    ) -> [AssembledLine] {
        let n = pattern.count
        var beam = [BeamState(slotIndex: 0, syllablePosition: 0, entries: [], positionalScore: 0)]
        var completed: [BeamState] = []

        while !beam.isEmpty {
            var next: [BeamState] = []
            for state in beam {
                guard state.slotIndex < template.slots.count else {
                    if state.syllablePosition == n { completed.append(state) }
                    continue
                }
                let remainingSlots = template.slots.count - state.slotIndex
                let remainingSyllables = n - state.syllablePosition
                guard remainingSyllables >= remainingSlots else { continue }

                for entry in expansions(for: template.slots[state.slotIndex], rng: &rng) {
                    guard entry.syllables <= remainingSyllables - (remainingSlots - 1) else { continue }
                    let score = positionScore(
                        entry: entry,
                        at: state.syllablePosition,
                        pattern: pattern,
                        longSlots: longSlots,
                        durations: durations,
                        triggerWords: triggerWords,
                        rng: &rng
                    )
                    var advanced = state
                    advanced.slotIndex += 1
                    advanced.syllablePosition += entry.syllables
                    advanced.entries.append(entry)
                    advanced.positionalScore += score
                    next.append(advanced)
                }
            }
            next.sort { $0.positionalScore > $1.positionalScore }
            if next.count > Self.beamWidth * 4 { next.removeSubrange((Self.beamWidth * 4)...) }
            // Keep beam diversity: cap per (slotIndex, syllablePosition) group.
            var grouped: [Int: Int] = [:]
            beam = next.filter { state in
                let key = state.slotIndex << 8 | state.syllablePosition
                let count = grouped[key, default: 0]
                grouped[key] = count + 1
                return count < Self.beamWidth
            }
        }

        return completed.map { state in
            finalize(state, targetValence: targetValence)
        }
    }

    func expansions(for slot: SlotSpec, rng: inout SeededRandom) -> [LexiconStore.Entry] {
        switch slot {
        case .oneOf(let literals):
            return literals.compactMap(resolveLiteral)
        case .pos(let category):
            let isContent = Self.isContentCategory(category)
            // The beyond-the-head random reach exists to surface evocative mid-frequency
            // *content* vocabulary. For function-word slots (preposition, conjunction)
            // it instead dredges up "sur"/"atop"/"fore"-grade obscurities that wreck a
            // line's fluency — there, only the common head of the bucket is wanted.
            let reach = isContent ? Self.extraReach : 0
            var out: [LexiconStore.Entry] = []
            for syllables in 1...4 {
                let ids = index.topCandidates(syllables: syllables, pos: category, limit: Self.candidatesPerSlot, extraRandom: reach, rng: &rng)
                for id in ids {
                    let entry = store[Int(id)]
                    // Function words, single letters, and profanity all disqualify an
                    // entry from a content slot, so they share one precomputed row set.
                    if isContent, blockedContentIDs.contains(entry.index) { continue }
                    // Moby also tags the articles as prepositions, so without this a
                    // preposition slot happily takes "a" — "half a your cans". An
                    // article-tagged word never belongs in a non-article POS slot.
                    if !category.contains(.article), entry.pos.contains(.article) { continue }
                    // Bare-verb slots: Moby tags participles and past forms as verbs
                    // too, but every template subject and modal pairs with the base
                    // form — "I upgrading a bore", "we'll escaped the goose". Multi-
                    // syllable verbs ending -ing/-ed are inflected forms; the
                    // monosyllables ("sing", "need") are genuine base verbs.
                    if category.contains(.verb), entry.syllables >= 2,
                       entry.text.hasSuffix("ing") || entry.text.hasSuffix("ed") { continue }
                    out.append(entry)
                }
            }
            return out
        }
    }

    /// Multi-word literals ("for now") resolve by combining per-word lexicon entries.
    private func resolveLiteral(_ literal: String) -> LexiconStore.Entry? {
        let words = literal.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }
        if words.count == 1 { return store.lookup(words[0]) }

        var combinedStress: UInt16 = 0
        var combinedOpen: UInt16 = 0
        var syllables = 0
        var valence = 0.0
        var zipf = Double.greatestFiniteMagnitude
        var cluster = 0
        for word in words {
            guard let entry = store.lookup(word) else { return nil }
            combinedStress |= entry.stressBits << syllables
            combinedOpen |= entry.openBits << syllables
            syllables += entry.syllables
            valence += entry.valence
            zipf = min(zipf, entry.zipf)
            cluster = max(cluster, entry.clusterRun)
        }
        guard let last = store.lookup(words[words.count - 1]) else { return nil }
        return LexiconStore.Entry(
            index: -1,
            text: literal.lowercased(),
            syllables: syllables,
            stressBits: combinedStress,
            openBits: combinedOpen,
            pos: [],
            zipf: zipf,
            valence: valence / Double(words.count),
            clusterRun: cluster,
            rhymeKey: last.rhymeKey
        )
    }

    // MARK: - Scoring

    /// Prosodic fit of one word laid down at syllable position `p` (docs: stress-on-
    /// strong-beat, open-vowel-on-long-note, cluster-penalty-on-fast-note).
    private func positionScore(
        entry: LexiconStore.Entry,
        at p: Int,
        pattern: [Stress],
        longSlots: Set<Int>,
        durations: [Int],
        triggerWords: Set<Int> = [],
        rng: inout SeededRandom
    ) -> Double {
        var score = 0.0

        for j in 0..<entry.syllables {
            let slot = p + j
            guard slot < pattern.count else { break }
            let stressed = entry.isStressed(syllable: j)

            switch (stressed, pattern[slot]) {
            case (true, .strong): score += 1.0
            case (false, .weak): score += 0.4
            case (true, .weak): score -= 0.6   // the "toDAY" misstep
            case (false, .strong): score -= 0.3
            }

            if longSlots.contains(slot) {
                score += entry.isOpen(syllable: j) ? 0.6 : -0.4
            }
            if slot < durations.count, durations[slot] < Self.fastNoteMs, entry.clusterRun >= 3 {
                score -= 0.4
            }
        }

        // Prefer evocative, mid-frequency vocabulary over the most common (and most
        // clichéd) words: a word at `evocativePeak` scores best; both worn-out common
        // words and obscure ones score lower. This replaces a prior term that rewarded
        // raw commonness — the source of generic, cliché word choices. Plus a whisper
        // of seeded jitter for tie-break variety.
        score += max(0, 0.3 - abs(entry.zipf - Self.evocativePeak) * 0.15)
        // Mid-frequency alone isn't evocative — "gram" and "flux" sit in the same
        // Zipf band as "thrill" and "grace". The VADER valence already in the lexicon
        // separates them: emotionally charged content words get a modest boost, so
        // lines lean on words that carry feeling rather than merely fitting meter.
        // Direction (positive/negative) is still handled by the line-level emotion
        // score; magnitude alone is rewarded here.
        if !entry.pos.isDisjoint(with: .contentWord) {
            score += min(0.25, abs(entry.valence) * 0.15)
        }
        // Curated beats statistical: content words from the book's Trigger Word
        // Library for the phrase's emotional state ("The Song Finisher", Emotional
        // State Engineering) get a lexical bonus on top of the valence term. Kept
        // below the stress-fit weights so the meter still rules. The content-word and
        // not-a-stop-word conditions are already baked into `triggerWordIDs`, so a
        // trigger word's fringe POS tag still can't drag it into the wrong slot.
        if triggerWords.contains(entry.index) {
            score += 0.25
        }
        score += Double(rng.next() % 100) / 2000.0
        return score
    }

    private func finalize(_ state: BeamState, targetValence: Double) -> AssembledLine {
        let text = state.entries.map(\.text).joined(separator: " ")
        var stressPattern: [Stress] = []
        var contentWords = Set<String>()
        var valence = 0.0
        var zipfSum = 0.0

        for entry in state.entries {
            // Raw lexicon POS bits alone aren't trustworthy here: the same mistagging
            // that made "a" rank as a noun (see contentSlotStopWords' doc comment) would
            // otherwise let a bare function word count as the line's one required
            // "real content" word, defeating the isAcceptable guard from the inside.
            let isContent = !entry.pos.isDisjoint(with: .contentWord) && !stopWordIDs.contains(entry.index)
            for j in 0..<entry.syllables {
                stressPattern.append(entry.isStressed(syllable: j) ? .strong : .weak)
            }
            if isContent { contentWords.insert(entry.text) }
            valence += entry.valence
            zipfSum += entry.zipf
        }

        let syllables = stressPattern.count
        let meanValence = valence / Double(max(1, state.entries.count))
        let normalizedProsody = min(1, max(0, state.positionalScore / Double(max(1, syllables)) * 0.7 + 0.3))
        let fluency = min(1, max(0, (zipfSum / Double(max(1, state.entries.count)) - 2.5) / 3.0))
        let emotion = min(1, max(0, 1.0 - abs(meanValence - targetValence) / 8.0))

        return AssembledLine(
            text: text,
            syllables: syllables,
            stressPattern: stressPattern,
            prosodyScore: normalizedProsody,
            fluencyScore: fluency,
            emotionScore: emotion,
            contentWords: contentWords
        )
    }

    /// Maps the spec's dominant emotion (or the user's override) to a VADER-scale
    /// valence target. Hand-tuned; the custom-keyword upgrade path replaces this.
    static func targetValence(for spec: PhraseSpec) -> Double {
        let emotion = spec.requestedEmotionOverride ?? spec.topEmotions.first?.emotion ?? .reflection
        switch emotion {
        case .joy: return 3.0
        case .hope: return 2.5
        case .release: return 1.5
        case .nostalgia: return -0.5
        case .reflection: return -0.25
        case .longing: return -1.0
        case .tension: return -1.5
        case .melancholy: return -2.5
        }
    }

    private func padded(_ pattern: [Stress], to count: Int) -> [Stress] {
        if pattern.count == count { return pattern }
        if pattern.count > count { return Array(pattern.prefix(count)) }
        return pattern + Array(repeating: .weak, count: count - pattern.count)
    }
}
