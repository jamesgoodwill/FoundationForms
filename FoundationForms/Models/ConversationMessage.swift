import Foundation

struct ConversationMessage: Identifiable, Equatable {
    let id: UUID
    var content: String
    let isUser: Bool

    init(id: UUID = UUID(), content: String, isUser: Bool) {
        self.id = id
        self.content = content
        self.isUser = isUser
    }
}
