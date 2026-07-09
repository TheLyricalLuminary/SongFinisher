import Foundation

public struct Song: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var lines: [LyricLine]
    public var memory: SessionMemory
    public var tempoBPM: Double?
    public var sourceMemoURL: URL?

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date,
        updatedAt: Date,
        lines: [LyricLine] = [],
        memory: SessionMemory = SessionMemory(),
        tempoBPM: Double? = nil,
        sourceMemoURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lines = lines
        self.memory = memory
        self.tempoBPM = tempoBPM
        self.sourceMemoURL = sourceMemoURL
    }
}
