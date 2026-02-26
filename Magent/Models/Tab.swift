import Foundation

nonisolated struct Tab: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let threadId: UUID
    var tmuxSessionName: String
    var index: Int

    init(
        id: UUID = UUID(),
        threadId: UUID,
        tmuxSessionName: String,
        index: Int
    ) {
        self.id = id
        self.threadId = threadId
        self.tmuxSessionName = tmuxSessionName
        self.index = index
    }
}
