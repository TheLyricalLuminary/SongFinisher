import Foundation

/// Creative material offered alongside (or instead of) a finished line: strong,
/// evocative words that fit the phrase's emotion and meter, plus rhymes for the last
/// accepted line. The offline generator can only guarantee metrical fit, never meaning
/// — so rather than hand the songwriter a nonsense line, it hands them sparks and lets
/// them write it. Meaning stays with the human; the app supplies the raw material.
public struct WordSparks: Sendable, Equatable, Codable {
    /// Evocative content words (nouns, verbs, adjectives) aligned to the phrase's
    /// emotion, ordered best-first.
    public let images: [String]
    /// Words that rhyme with the last accepted line's final word — empty when there is
    /// no line to rhyme against yet.
    public let rhymes: [String]

    public init(images: [String], rhymes: [String]) {
        self.images = images
        self.rhymes = rhymes
    }

    public var isEmpty: Bool { images.isEmpty && rhymes.isEmpty }
}

/// Supplies `WordSparks` for a completed phrase. Synchronous and local: sparks are a
/// lexicon lookup, not a generation request, so they resolve instantly with no
/// cancellation or error surface (docs/ARCHITECTURE.md §9 keeps the offline path
/// dependency-free).
public protocol SparkProviding: Sendable {
    func sparks(for spec: PhraseSpec, memory: SessionMemory) -> WordSparks
}
