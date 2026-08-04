import Foundation

public struct LyricLine: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public let phraseID: UUID
    public let text: String
    public let stressMap: StressMap
    public let emotion: Emotion
    public let acceptedAt: Date
    public var isHookCandidate: Bool

    public init(
        id: UUID = UUID(),
        phraseID: UUID,
        text: String,
        stressMap: StressMap,
        emotion: Emotion,
        acceptedAt: Date,
        isHookCandidate: Bool = false
    ) {
        self.id = id
        self.phraseID = phraseID
        self.text = text
        self.stressMap = stressMap
        self.emotion = emotion
        self.acceptedAt = acceptedAt
        self.isHookCandidate = isHookCandidate
    }
}

public struct RejectedLine: Sendable, Equatable, Codable {
    public enum Reason: String, Sendable, Equatable, Codable {
        case regenerated, differentEmotion, explicitReject
    }

    public let text: String
    public let reason: Reason

    public init(text: String, reason: Reason) {
        self.text = text
        self.reason = reason
    }
}

/// The developing song's context, injected into every AI prompt (capped per
/// docs/ARCHITECTURE.md §9 so requests stay small and cache-friendly).
public struct SessionMemory: Sendable, Equatable, Codable {
    public static let maxAcceptedLinesInPrompt = 12
    public static let maxRejectedInPrompt = 20
    public static let maxThemes = 8

    public var acceptedLines: [LyricLine]
    public var rejected: [RejectedLine]
    public var themes: [String]
    public var motifs: [String]
    public var hookLine: String?
    public var dominantEmotion: Emotion?
    public var rhymeTails: [String]

    public init(
        acceptedLines: [LyricLine] = [],
        rejected: [RejectedLine] = [],
        themes: [String] = [],
        motifs: [String] = [],
        hookLine: String? = nil,
        dominantEmotion: Emotion? = nil,
        rhymeTails: [String] = []
    ) {
        self.acceptedLines = acceptedLines
        self.rejected = rejected
        self.themes = themes
        self.motifs = motifs
        self.hookLine = hookLine
        self.dominantEmotion = dominantEmotion
        self.rhymeTails = rhymeTails
    }

    /// Writes `line` onto the sheet, keyed by the phrase it belongs to, and returns the
    /// line it displaced (`nil` if it was appended).
    ///
    /// One line per phrase is what makes automatic keeping usable: a phrase's line is
    /// recorded the moment it arrives, and [Regenerate], [More Like This], [Different
    /// Emotion] and the syllable nudges all produce a *replacement* for that same
    /// phrase rather than another entry. Appending blindly would turn a writer who
    /// fiddled with one line into six copies of it.
    @discardableResult
    public mutating func record(_ line: LyricLine) -> LyricLine? {
        guard let index = acceptedLines.firstIndex(where: { $0.phraseID == line.phraseID }) else {
            acceptedLines.append(line)
            return nil
        }
        let replaced = acceptedLines[index]
        acceptedLines[index] = line
        return replaced
    }

    /// FIFO-capped view used when building a prompt (docs/ARCHITECTURE.md §9 memory caps).
    public var promptAcceptedLines: [LyricLine] { Array(acceptedLines.suffix(Self.maxAcceptedLinesInPrompt)) }
    public var promptRejected: [RejectedLine] { Array(rejected.suffix(Self.maxRejectedInPrompt)) }
    public var promptThemes: [String] { Array(themes.suffix(Self.maxThemes)) }
}
