/// A curated word → (stress pattern, rhyme tail) lookup table.
///
/// This is the interim bundled subset described in docs/ARCHITECTURE.md §2
/// (`Resources/cmudict-subset.bin`): a few hundred common and deliberately tricky words,
/// embedded as Swift data so it needs no resource-bundle plumbing. `SyllableCounter`'s public
/// API doesn't care where the data comes from, so swapping in a full CMU-derived dataset later
/// is a data change, not a logic change.
///
/// `stress` uses "S"/"w" per syllable (primary stress only — no secondary-stress distinction
/// for MVP). `tail` is a simplified rhyme-tail proxy (last sounded syllable's spelling), used
/// by `ContinuityScorer` for slant-rhyme detection in the absence of true phonemes.
enum SyllableDictionary {
    struct Entry: Sendable {
        let stress: [Stress]
        let tail: String
    }

    /// Pinned ambiguous-word policies (see docs/ARCHITECTURE.md §11 "every" 2–3 note):
    /// - "fire" = 1 syllable (not the Southern-dialect 2-syllable reading)
    /// - "every" = 2 syllables
    /// - "poetry" = 3 syllables
    /// - "wandered" = 2 syllables
    static let entries: [String: Entry] = {
        var d: [String: Entry] = [:]

        func word(_ w: String, _ stress: String, tail: String? = nil) {
            let pattern = stress.map { Stress(rawValue: String($0))! }
            d[w] = Entry(stress: pattern, tail: tail ?? String(w.suffix(min(3, w.count))))
        }

        // Function words — monosyllabic, conventionally weak (they "float" per §9 prompt strategy).
        for w in ["a", "an", "the", "of", "in", "on", "to", "for", "and", "but", "or", "with",
                  "is", "are", "was", "were", "am", "be", "been", "i", "you", "we", "they",
                  "he", "she", "it", "my", "your", "our", "their", "his", "her", "its",
                  "me", "him", "us", "them", "at", "by", "as", "if", "so", "up", "out",
                  "no", "not", "than", "that", "this", "these", "those", "who", "what",
                  "when", "where", "why", "how", "all", "one", "just", "can", "will",
                  "do", "did", "does", "from", "into", "through", "down", "off", "still"] {
            word(w, "w")
        }

        // Monosyllabic content words — default Strong.
        for w in ["fire", "light", "night", "day", "sun", "moon", "star", "stars", "rain",
                  "wait", "waits", "waited", "call", "calls", "called", "fall", "falls",
                  "fell", "hold", "holds", "held", "wall", "walls", "road", "home", "heart",
                  "hearts", "mind", "soul", "eyes", "eye", "hand", "hands", "voice",
                  "song", "songs", "long", "gone", "here", "now", "then", "close", "true",
                  "blue", "cold", "warm", "dark", "bright", "slow", "fast", "stay",
                  "stayed", "leave", "left", "back", "sky", "sea", "wind", "storm", "glass",
                  "rose", "grace", "grave", "wave", "waves", "burn", "burns", "burned",
                  "break", "broke", "broken", "shine", "shone", "cry", "cried", "sing",
                  "sang", "sung", "hear", "heard", "see", "saw", "seen", "know", "knew",
                  "known", "feel", "felt", "love", "loved", "loves", "lost", "lose",
                  "find", "found", "keep", "kept", "let", "give", "gave", "given",
                  "took", "take", "taken", "make", "made", "count", "counts", "counted",
                  "wake", "woke", "woken", "sleep", "slept", "dream", "dreamed", "dreamt",
                  "dreams", "few", "new", "old", "young", "life", "live", "lived",
                  "lives", "die", "died", "breathe", "breath", "touch", "touched",
                  "reach", "reached", "sound", "sounds", "shade", "shades",
                  "chase", "chased", "trace", "traced", "space", "place",
                  "face", "faced", "case", "chance", "dance", "danced", "ring",
                  "rings", "rang", "rung", "bring", "brought", "bell", "bells"] {
            word(w, "S")
        }

        // Two-syllable words — explicit stress + rhyme tail.
        word("every", "Sw", tail: "ry")
        word("wandered", "Sw", tail: "ed")
        word("wander", "Sw", tail: "er")
        word("about", "wS", tail: "out")
        word("again", "wS", tail: "ain")
        word("away", "wS", tail: "way")
        word("alone", "wS", tail: "one")
        word("along", "wS", tail: "ong")
        word("around", "wS", tail: "ound")
        word("before", "wS", tail: "ore")
        word("beyond", "wS", tail: "ond")
        word("beneath", "wS", tail: "eath")
        word("between", "wS", tail: "een")
        word("silence", "Sw", tail: "ence")
        word("silent", "Sw", tail: "ent")
        word("shadow", "Sw", tail: "ow")
        word("shadows", "Sw", tail: "ows")
        word("morning", "Sw", tail: "ing")
        word("evening", "Sw", tail: "ing")
        word("distance", "Sw", tail: "ance")
        word("moment", "Sw", tail: "ent")
        word("moments", "Sw", tail: "ents")
        word("ocean", "Sw", tail: "ean")
        word("open", "Sw", tail: "en")
        word("broken", "Sw", tail: "en")
        word("golden", "Sw", tail: "en")
        word("frozen", "Sw", tail: "en")
        word("river", "Sw", tail: "er")
        word("winter", "Sw", tail: "er")
        word("summer", "Sw", tail: "er")
        word("thunder", "Sw", tail: "er")
        word("wonder", "Sw", tail: "er")
        word("under", "Sw", tail: "er")
        word("over", "Sw", tail: "er")
        word("only", "Sw", tail: "ly")
        word("lonely", "Sw", tail: "ly")
        word("slowly", "Sw", tail: "ly")
        word("gently", "Sw", tail: "ly")
        word("softly", "Sw", tail: "ly")
        word("nothing", "Sw", tail: "ing")
        word("something", "Sw", tail: "ing")
        word("mountain", "Sw", tail: "ain")
        word("waiting", "Sw", tail: "ing")
        word("falling", "Sw", tail: "ing")
        word("holding", "Sw", tail: "ing")
        word("burning", "Sw", tail: "ing")
        word("breaking", "Sw", tail: "ing")
        word("calling", "Sw", tail: "ing")
        word("dreaming", "Sw", tail: "ing")
        word("crying", "Sw", tail: "ing")
        word("singing", "Sw", tail: "ing")
        word("reaching", "Sw", tail: "ing")
        word("driving", "Sw", tail: "ing")
        word("living", "Sw", tail: "ing")
        word("leaving", "Sw", tail: "ing")
        word("taillight", "Sw", tail: "ight")
        word("taillights", "Sw", tail: "ights")
        word("highway", "Sw", tail: "way")
        word("midnight", "Sw", tail: "ight")
        word("sunlight", "Sw", tail: "ight")
        word("moonlight", "Sw", tail: "ight")
        word("daylight", "Sw", tail: "ight")
        word("heartbeat", "Sw", tail: "eat")
        word("heartbeats", "Sw", tail: "eats")
        word("streetlight", "Sw", tail: "ight")
        word("windows", "Sw", tail: "ows")
        word("window", "Sw", tail: "ow")
        word("driveway", "Sw", tail: "way")
        word("always", "Sw", tail: "ays")
        word("never", "Sw", tail: "er")
        word("forever", "wSw", tail: "er")
        word("whatever", "wSw", tail: "er")
        word("tomorrow", "wSw", tail: "ow")

        // Words the OOV heuristic provably cannot reach, because the spelling carries no
        // signal either way. `SyllableCounter.hasSyllabicL` handles the "-le"/"-led"
        // families by rule; these are the residue, and a lookup is the honest fix.
        //
        // The "-ed" here is a real syllable even though it follows neither t nor d — the
        // adjectival "-ed", which is a closed class in English. Deliberately *not* listed:
        // blessed, learned, cursed, aged. Those carry a live verb reading at one syllable
        // ("you blessed my name") alongside the adjective at two, and pinning either would
        // be wrong half the time; the heuristic's one-syllable answer matches the reading
        // a songwriter is more often singing.
        word("naked", "Sw", tail: "ked")
        word("wicked", "Sw", tail: "ked")
        word("sacred", "Sw", tail: "red")
        word("crooked", "Sw", tail: "ked")
        word("rugged", "Sw", tail: "ged")
        word("ragged", "Sw", tail: "ged")
        word("wretched", "Sw", tail: "ched")
        // "-sle" looks exactly like the syllabic "-le" of "little" and is not. Only these
        // two matter for lyrics; the rest of the family ("hassle", "tussle") really is
        // syllabic, so this stays a lookup rather than a rule — measured, adding an "s"
        // case to `hasSyllabicL` fixed three words and broke three others.
        word("aisle", "S", tail: "ile")
        word("isle", "S", tail: "ile")

        // Three-syllable words.
        word("poetry", "Sww", tail: "try")
        word("memory", "Sww", tail: "ory")
        word("memories", "Sww", tail: "ories")
        word("beautiful", "Sww", tail: "ful")
        word("wonderful", "Sww", tail: "ful")
        word("interstate", "Sww", tail: "ate")
        word("everyone", "Sww", tail: "one")
        word("remember", "wSw", tail: "er")
        word("remembered", "wSw", tail: "ered")
        word("quietly", "Sww", tail: "ly")
        word("everything", "Sww", tail: "ing")

        // Four-syllable words.
        word("everybody", "Swww", tail: "ody")

        // Contractions — common repair targets for the auto-repair pass (docs/ARCHITECTURE.md §9).
        word("i'm", "S", tail: "im")
        word("you're", "S", tail: "ure")
        word("we're", "S", tail: "ere")
        word("they're", "S", tail: "ere")
        word("don't", "S", tail: "ont")
        word("won't", "S", tail: "ont")
        word("can't", "S", tail: "ant")
        word("isn't", "Sw", tail: "isnt")
        word("wasn't", "Sw", tail: "asnt")
        word("didn't", "Sw", tail: "idnt")
        word("couldn't", "Sw", tail: "uldnt")
        word("wouldn't", "Sw", tail: "uldnt")
        word("it's", "S", tail: "its")
        word("that's", "S", tail: "ats")
        word("there's", "S", tail: "eres")

        return d
    }()
}
