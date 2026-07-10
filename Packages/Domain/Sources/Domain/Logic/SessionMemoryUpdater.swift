import Foundation

/// The accept/reject memory-update rules (docs/ARCHITECTURE.md §9): on accept, append
/// the line, recompute the rhyme tail and dominant emotion, and track repeated content
/// words as motifs. Pure so the ViewModel stays a thin orchestrator.
public enum SessionMemoryUpdater {
    static let motifMinimumOccurrences = 2

    public static func accepting(_ line: LyricLine, into memory: SessionMemory) -> SessionMemory {
        var updated = memory
        updated.acceptedLines.append(line)

        let tail = SyllableCounter.analyze(line: line.text).tailPhoneme
        if !tail.isEmpty { updated.rhymeTails.append(tail) }

        updated.dominantEmotion = mode(updated.acceptedLines.map(\.emotion))

        var wordCounts: [String: Int] = [:]
        for accepted in updated.acceptedLines {
            for word in Set(SyllableCounter.words(in: accepted.text)) {
                wordCounts[word, default: 0] += 1
            }
        }
        updated.motifs = wordCounts
            .filter { $0.value >= motifMinimumOccurrences }
            .map(\.key)
            .sorted()

        if let mostRepeated = wordCounts.max(by: { $0.value < $1.value }), mostRepeated.value >= motifMinimumOccurrences {
            updated.hookLine = updated.acceptedLines.last { SyllableCounter.words(in: $0.text).contains(mostRepeated.key) }?.text
        }

        return updated
    }

    public static func rejecting(_ text: String, reason: RejectedLine.Reason, into memory: SessionMemory) -> SessionMemory {
        var updated = memory
        updated.rejected.append(RejectedLine(text: text, reason: reason))
        return updated
    }

    private static func mode(_ emotions: [Emotion]) -> Emotion? {
        guard !emotions.isEmpty else { return nil }
        var counts: [Emotion: Int] = [:]
        for e in emotions { counts[e, default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key
    }
}
