import Foundation

/// One persisted notes row from the `notes` table.
public struct NotesRecord: Identifiable, Sendable, Equatable {
    public var id: UUID
    public var callID: UUID
    public var provider: NotesProviderID
    public var modelDigest: String?
    public var promptVersion: String
    public var body: CallNotes
    public var editedByUser: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        callID: UUID,
        provider: NotesProviderID,
        modelDigest: String? = nil,
        promptVersion: String = NotesPromptTemplate.version,
        body: CallNotes,
        editedByUser: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.callID = callID
        self.provider = provider
        self.modelDigest = modelDigest
        self.promptVersion = promptVersion
        self.body = body
        self.editedByUser = editedByUser
        self.createdAt = createdAt
    }

    /// Deep notes win over instant title/tldr rows; newest row of that class wins.
    public static func preferred(in records: [NotesRecord]) -> NotesRecord? {
        records.filter { $0.provider != .appleFM }.max { $0.createdAt < $1.createdAt }
            ?? records.max { $0.createdAt < $1.createdAt }
    }
}
