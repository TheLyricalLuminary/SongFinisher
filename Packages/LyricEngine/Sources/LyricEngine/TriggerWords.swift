import Foundation
import Domain

/// Curated trigger vocabulary from Mark Amigoni's "The Song Finisher" (2026),
/// "Trigger Word Library — Expanded": words the book's Emotional State Engineering
/// system prescribes for each of its five emotional states. This is the signal the
/// offline tier lacked — lexicon statistics (Zipf, VADER) can say a word is common
/// or charged, but only curation can say it is *singable songwriting vocabulary for
/// this feeling*. The assembler boosts these words when they match the phrase's
/// emotion, so offline lines lean on the same vocabulary the book teaches.
///
/// Multi-word entries from the book ("at last", "on and on") are omitted — matching
/// happens per lexicon entry. The app's eight emotions map onto the book's five
/// states as noted per set.
enum TriggerWordBank {

    /// State 1 — Joyful Release (app: joy, release).
    /// Lists are pruned to unambiguous *content* vocabulary: the book's
    /// function-word triggers ("now", "through", "over", "always") score via slots
    /// they legitimately fill; boosting them everywhere let fringe Moby tags drag
    /// them into noun/adjective slots ("there's a through neat").
    static let joyfulRelease: Set<String> = [
        "breathe", "open", "light", "air", "sky", "wide", "clear", "free", "loose", "expand",
        "finally", "away", "rise", "fly", "lift", "home", "safe", "found", "whole", "settled",
        "arrived", "won", "standing", "alive", "survived", "soft", "warm", "held", "quiet", "resting",
    ]

    /// State 2 — Heartbreak Hold (app: melancholy, longing, nostalgia).
    static let heartbreakHold: Set<String> = [
        "quiet", "still", "empty", "hollow", "cold", "frozen", "flat", "dim",
        "gone", "missing", "space", "lost", "hold", "wait", "alone", "inside",
        "heavy", "ache", "numb", "slow", "tight", "sinking", "stone", "low", "pressed",
        "black", "dead", "stripped",
    ]

    /// State 3 — Tension Spiral (app: tension).
    static let tensionSpiral: Set<String> = [
        "faster", "louder", "higher", "harder", "rising", "building", "climbing",
        "tighter", "closer", "pushing", "pulling", "breaking", "cracking", "walls", "weight",
        "again", "quick", "burn", "crash", "snap", "shatter", "fall", "splinter", "collapse",
        "watch", "creep", "dark", "breathe", "stop", "help", "please",
    ]

    /// State 4 — Hope Return (app: hope).
    static let hopeReturn: Set<String> = [
        "maybe", "almost", "barely", "softer", "brighter", "lighter", "warmer", "dawn",
        "crack", "edge", "find", "start", "turning", "waking", "beginning",
        "small", "slow", "careful", "first", "new", "gentle", "emerging", "faint", "thread", "learning",
    ]

    /// State 5 — Final Resolve (app: reflection).
    static let finalResolve: Set<String> = [
        "finished", "complete", "whole", "end", "final", "closed", "know", "true", "real",
        "clear", "certain", "sure", "honest", "rest", "peace", "still", "calm", "home",
        "settled", "quiet", "forever", "earned", "claimed", "released", "survived", "standing", "won",
    ]

    /// The book's five states, keyed by the app's eight emotions.
    static func words(for emotion: Emotion) -> Set<String> {
        switch emotion {
        case .joy, .release: return joyfulRelease
        case .melancholy, .longing, .nostalgia: return heartbreakHold
        case .tension: return tensionSpiral
        case .hope: return hopeReturn
        case .reflection: return finalResolve
        }
    }
}
