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

    public init(store: LexiconStore, index: StressPatternIndex) {
        self.store = store
        self.index = index
    }

    /// A slot category is "content" when it carries lexical stress and meaning
    /// (noun/verb/adjective/adverb) rather than being a closed-class function word.
    static func isContentCategory(_ category: POSCategory) -> Bool {
        !category.isDisjoint(with: .contentWord)
    }

    /// A finished line is only offered if it carries at least one real content word and
    /// does not end on a bare function word. A line ending on "a" or "your" reads as
    /// broken no matter how well its stress aligns.
    static func isAcceptable(_ line: AssembledLine) -> Bool {
        guard !line.contentWords.isEmpty else { return false }
        guard let last = line.text.split(separator: " ").last else { return false }
        return !contentSlotStopWords.contains(String(last).lowercased())
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
                rng: &rng
            )
            for line in lines where Self.isAcceptable(line) && seenTexts.insert(line.text).inserted {
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
            let filterStopWords = Self.isContentCategory(category)
            var out: [LexiconStore.Entry] = []
            for syllables in 1...4 {
                let ids = index.topCandidates(syllables: syllables, pos: category, limit: Self.candidatesPerSlot, extraRandom: Self.extraReach, rng: &rng)
                for id in ids {
                    let entry = store[Int(id)]
                    if filterStopWords, Self.contentSlotStopWords.contains(entry.text) { continue }
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
            let isContent = !entry.pos.isDisjoint(with: .contentWord)
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
