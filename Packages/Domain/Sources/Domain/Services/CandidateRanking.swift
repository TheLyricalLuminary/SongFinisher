public protocol CandidateRanking: Sendable {
    func rank(_ candidates: [LyricCandidate], spec: PhraseSpec, memory: SessionMemory) -> [RankedCandidate]
}
