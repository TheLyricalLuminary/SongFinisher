import Foundation

/// Part-of-speech categories, mirroring the bit positions written by
/// `tools/build_lexicon.py` (Moby POS codes).
public struct POSCategory: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let noun = POSCategory(rawValue: 1 << 0)
    public static let pluralNoun = POSCategory(rawValue: 1 << 1)
    public static let verb = POSCategory(rawValue: 1 << 2)
    public static let adjective = POSCategory(rawValue: 1 << 3)
    public static let adverb = POSCategory(rawValue: 1 << 4)
    public static let conjunction = POSCategory(rawValue: 1 << 5)
    public static let preposition = POSCategory(rawValue: 1 << 6)
    public static let interjection = POSCategory(rawValue: 1 << 7)
    public static let pronoun = POSCategory(rawValue: 1 << 8)
    public static let article = POSCategory(rawValue: 1 << 9)
    public static let nounPhrase = POSCategory(rawValue: 1 << 10)

    /// Categories whose monosyllables conventionally carry lexical stress.
    public static let contentWord: POSCategory = [.noun, .pluralNoun, .verb, .adjective, .adverb, .interjection]
}

/// Memory-mapped reader for the SFLX v1 lexicon blob (format documented in
/// `tools/build_lexicon.py`). All reads are unaligned loads against the mapped
/// `Data`; nothing is copied at load beyond the header fields, so cold-load is
/// dominated by the page cache (Task 2 acceptance: < 50 ms).
public struct LexiconStore: Sendable {
    public struct Entry: Sendable, Equatable {
        public let index: Int
        public let text: String
        public let syllables: Int
        public let stressBits: UInt16   // bit i (LSB-first) = syllable i primary-stressed
        public let openBits: UInt16     // bit i = syllable i nucleus is an open vowel
        public let pos: POSCategory
        public let zipf: Double
        public let valence: Double      // VADER scale, -4…+4
        public let clusterRun: Int      // longest consonant-phoneme run
        public let rhymeKey: UInt32

        public func isStressed(syllable i: Int) -> Bool { stressBits & (1 << i) != 0 }
        public func isOpen(syllable i: Int) -> Bool { openBits & (1 << i) != 0 }
    }

    public enum LoadError: Error {
        case resourceMissing
        case badMagic
        case unsupportedVersion(UInt32)
        case truncated
    }

    public let count: Int

    private let data: Data
    private let offsetsBase: Int      // u32 × (count+1)
    private let syllablesBase: Int    // u8 × count
    private let stressBase: Int       // u16 × count
    private let openBase: Int         // u16 × count
    private let posBase: Int          // u16 × count
    private let zipfBase: Int         // u8 × count
    private let valenceBase: Int      // i8 × count
    private let clusterBase: Int      // u8 × count
    private let rhymeBase: Int        // u32 × count
    /// Every word decoded once at load, not on each access. The beam-search hot path
    /// re-reads the same handful of common words thousands of times per assembly;
    /// decoding UTF-8 from the mapped `Data` on every subscript call (the original
    /// design) measured at 3.2 s for a single 7-syllable line — this array collapses
    /// that to microseconds at the cost of ~35K short String allocations at init,
    /// which is still well inside the cold-load budget (measured a few ms).
    private let words: [String]

    public init(data: Data) throws {
        guard data.count >= 32 else { throw LoadError.truncated }
        let magic = data.prefix(4)
        guard magic.elementsEqual("SFLX".utf8) else { throw LoadError.badMagic }
        let version: UInt32 = Self.load(data, at: 4)
        guard version == 1 else { throw LoadError.unsupportedVersion(version) }
        let n = Int(Self.load(data, at: 8) as UInt32)
        let stringsOff = Int(Self.load(data, at: 12) as UInt32)
        let stringsLen = Int(Self.load(data, at: 16) as UInt32)
        guard data.count >= stringsOff + stringsLen else { throw LoadError.truncated }

        self.count = n
        self.data = data
        var cursor = 32
        offsetsBase = cursor; cursor += (n + 1) * 4
        syllablesBase = cursor; cursor += n
        stressBase = cursor; cursor += n * 2
        openBase = cursor; cursor += n * 2
        posBase = cursor; cursor += n * 2
        zipfBase = cursor; cursor += n
        valenceBase = cursor; cursor += n
        clusterBase = cursor; cursor += n
        rhymeBase = cursor; cursor += n * 4
        guard cursor == stringsOff else { throw LoadError.truncated }

        var decoded: [String] = []
        decoded.reserveCapacity(n)
        for i in 0..<n {
            let start = Int(Self.load(data, at: offsetsBase + i * 4) as UInt32)
            let end = Int(Self.load(data, at: offsetsBase + (i + 1) * 4) as UInt32)
            decoded.append(String(decoding: data.subdata(in: (stringsOff + start)..<(stringsOff + end)), as: UTF8.self))
        }
        self.words = decoded
    }

    /// Loads the blob bundled with LyricEngine, memory-mapped.
    public static func bundled() throws -> LexiconStore {
        guard let url = Bundle.module.url(forResource: "lexicon", withExtension: "bin") else {
            throw LoadError.resourceMissing
        }
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return try LexiconStore(data: data)
    }

    public subscript(index: Int) -> Entry {
        precondition(index >= 0 && index < count)
        return Entry(
            index: index,
            text: words[index],
            syllables: Int(data[data.startIndex + syllablesBase + index]),
            stressBits: Self.load(data, at: stressBase + index * 2),
            openBits: Self.load(data, at: openBase + index * 2),
            pos: POSCategory(rawValue: Self.load(data, at: posBase + index * 2)),
            zipf: Double(data[data.startIndex + zipfBase + index]) / 20.0,
            valence: Double(Int8(bitPattern: data[data.startIndex + valenceBase + index])) / 25.0,
            clusterRun: Int(data[data.startIndex + clusterBase + index]),
            rhymeKey: Self.load(data, at: rhymeBase + index * 4)
        )
    }

    /// Binary search over the sorted strings table.
    public func lookup(_ word: String) -> Entry? {
        let needle = word.lowercased()
        var low = 0
        var high = count - 1
        while low <= high {
            let mid = (low + high) / 2
            let candidate = wordText(at: mid)
            if candidate == needle { return self[mid] }
            if candidate < needle { low = mid + 1 } else { high = mid - 1 }
        }
        return nil
    }

    func wordText(at index: Int) -> String { words[index] }

    private static func load<T: FixedWidthInteger>(_ data: Data, at offset: Int) -> T {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
    }
}
