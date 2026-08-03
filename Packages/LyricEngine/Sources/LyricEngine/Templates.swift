import Foundation

/// One slot of a lyric template: either an open-class POS slot filled from the
/// lexicon, or a small closed-class literal set (anchoring subjects, articles,
/// and line-enders keeps the output fluent without a runtime language model).
enum SlotSpec: Sendable {
    case pos(POSCategory)
    case oneOf([String])
}

struct LyricTemplate: Sendable {
    let slots: [SlotSpec]
    /// Minimum syllables this template can produce (1 per open slot, literal minimum otherwise).
    let minSyllables: Int
    let maxSyllables: Int
}

/// The template bank. Songwriting is syntactically repetitive: a modest bank of
/// frames × a 35K-word lexicon gives enormous variety. Literals are deliberately
/// common, singable function words.
enum TemplateBank {
    /// Subjects that pair with a bare-form verb slot. "she"/"he" are deliberately
    /// absent: the lexicon's verb bucket serves base forms ("she provision…" reads
    /// broken), so third-person singular subjects only appear in templates whose
    /// copula is pinned to agree.
    static let subjects = ["I", "you", "we", "they"]
    static let articles = ["the", "a", "this", "that", "my", "your", "our", "her", "his"]
    static let enders = ["again", "tonight", "away", "alone", "somehow", "for now", "at last", "inside"]
        // "for now"/"at last" are two words but fixed — counted via lexicon at build.

    static let all: [LyricTemplate] = {
        var templates: [[SlotSpec]] = []

        // Subject-led clauses.
        templates.append([.oneOf(subjects), .pos(.verb), .oneOf(articles), .pos(.noun)])
        templates.append([.oneOf(subjects), .pos(.verb), .pos(.preposition), .oneOf(articles), .pos(.noun)])
        templates.append([.oneOf(subjects), .pos(.verb), .oneOf(articles), .pos(.adjective), .pos(.noun)])
        templates.append([.oneOf(subjects), .pos(.adverb), .pos(.verb), .oneOf(articles), .pos(.noun)])
        templates.append([.oneOf(subjects), .pos(.verb), .oneOf(enders)])
        templates.append([.oneOf(subjects), .pos(.verb), .pos(.pluralNoun)])
        templates.append([.oneOf(["I'm", "you're", "we're"]), .pos(.adjective), .oneOf(enders)])
        templates.append([.oneOf(["I'll", "you'll", "we'll"]), .pos(.verb), .oneOf(articles), .pos(.noun)])
        templates.append([.oneOf(["don't", "can't", "won't"]), .pos(.verb), .oneOf(articles), .pos(.noun)])

        // Noun-led images. The subject of the verb-carrying frame is *plural* on
        // purpose: the open verb slot serves base forms (see the -ing/-ed filter in
        // PhraseAssembler.expansions), and a plural subject agrees with the base form
        // by construction — "the nights burn again", never "the heart break again".
        templates.append([.oneOf(["the", "my", "your", "our", "her", "his", "these", "those"]),
                          .pos(.pluralNoun), .pos(.verb), .oneOf(enders)])
        templates.append([.oneOf(articles), .pos(.noun), .pos(.preposition), .oneOf(articles), .pos(.noun)])
        templates.append([.pos(.adjective), .pos(.noun), .pos(.preposition), .oneOf(articles), .pos(.noun)])
        templates.append([.oneOf(articles), .pos(.adjective), .pos(.noun)])
        templates.append([.pos(.pluralNoun), .pos(.preposition), .oneOf(articles), .pos(.noun)])
        templates.append([.pos(.noun), .oneOf(["and"]), .pos(.noun), .oneOf(enders)])
        templates.append([.oneOf(["all", "half"]), .pos(.preposition), .oneOf(articles), .pos(.pluralNoun)])

        // Imperatives / vocatives.
        templates.append([.pos(.verb), .oneOf(["me", "us", "it"]), .oneOf(enders)])
        templates.append([.pos(.verb), .oneOf(articles), .pos(.noun), .oneOf(enders)])
        templates.append([.pos(.verb), .pos(.preposition), .oneOf(articles), .pos(.noun)])
        templates.append([.oneOf(["oh", "so", "still", "now"]), .oneOf(subjects), .pos(.verb), .oneOf(articles), .pos(.noun)])

        // Prepositional images.
        templates.append([.pos(.preposition), .oneOf(articles), .pos(.noun), .oneOf(subjects), .pos(.verb)])
        templates.append([.pos(.preposition), .oneOf(articles), .pos(.adjective), .pos(.noun)])
        templates.append([.pos(.preposition), .pos(.pluralNoun), .oneOf(["and"]), .pos(.pluralNoun)])

        // Copular / descriptive. Subject and copula are split into agreement-consistent
        // groups — one free slot for each would let the beam pair "you" with "was",
        // and grammar breaks read worse than any bland word choice.
        templates.append([.oneOf(articles), .pos(.noun), .oneOf(["is", "was"]), .pos(.adjective)])
        templates.append([.oneOf(["I"]), .oneOf(["am", "was"]), .pos(.adverb), .pos(.adjective)])
        templates.append([.oneOf(["you", "we", "they"]), .oneOf(["are", "were"]), .pos(.adverb), .pos(.adjective)])
        templates.append([.oneOf(["she", "he"]), .oneOf(["is", "was"]), .pos(.adverb), .pos(.adjective)])
        templates.append([.oneOf(["it's", "there's"]), .oneOf(articles), .pos(.adjective), .pos(.noun)])

        // Short frames, for phrases of one or two syllables. Every frame above needs at
        // least three slots, so a one- or two-note phrase — a single strum on Sparse
        // density, or a two-note hum — matched no template at all. That did not fail
        // loudly: `OfflineLyricProvider` has a last-resort sweep that widens the target
        // until something fills, so the writer got a *three*-syllable line for their
        // one-syllable phrase. Metrically wrong, silently — the one thing this app
        // exists to get right. These frames let the sweep stay unused.
        //
        // Short lines are also just good songwriting: a held one-word line over a single
        // strum is a hook, not a degenerate case.
        // Every two-slot frame here anchors on a closed-class word. `[adjective, noun]`
        // and `[article, noun]` were tried and dropped: with only two words there is no
        // surrounding structure to carry a Moby mistag, so they produced "his mock" and
        // "that grimes" where the longer frames absorb the same errors.
        templates.append([.pos(.noun)])
        templates.append([.oneOf(subjects), .pos(.verb)])
        templates.append([.pos(.verb), .oneOf(["me", "us", "it"])])
        templates.append([.oneOf(["oh", "so", "still", "now"]), .pos(.adjective)])

        return templates.map { slots in
            var minSyll = 0
            var maxSyll = 0
            for slot in slots {
                switch slot {
                case .pos:
                    minSyll += 1
                    maxSyll += 4
                case .oneOf(let words):
                    // Literal syllable counts are resolved against the lexicon at
                    // assembly; conservatively 1–3 here for feasibility pruning.
                    minSyll += 1
                    maxSyll += words.contains(where: { $0.contains(" ") }) ? 3 : 2
                }
            }
            return LyricTemplate(slots: slots, minSyllables: minSyll, maxSyllables: maxSyll)
        }
    }()
}
