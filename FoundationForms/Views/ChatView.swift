import SwiftUI

struct ChatView: View {
    @State private var viewModel: ChatViewModel

    init(viewModel: ChatViewModel = ChatViewModel()) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        ConversationView(
            messages: viewModel.messages,
            draft: $viewModel.draft,
            isWorking: viewModel.isThinking,
            availability: viewModel.availability,
            inputPlaceholder: "Message",
            unavailableTitle: "Chat is unavailable",
            onSend: { Task { await viewModel.sendMessage() } }
        )
        .navigationTitle("Chat")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("Available") {
    NavigationStack {
        ChatView(
            viewModel: ChatViewModel(
                seedMessages: [
                    ChatMessage(content: "Hi! How can I help?", isUser: false),
                    ChatMessage(content: "What's the capital of France?", isUser: true),
                    ChatMessage(content: "Paris.", isUser: false)
                ]
            )
        )
    }
}
