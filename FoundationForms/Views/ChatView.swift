import SwiftUI
import FoundationModels
import UIKit

struct ChatView: View {
    @State private var viewModel: ChatViewModel

    init(viewModel: ChatViewModel = ChatViewModel()) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        Group {
            switch viewModel.availability {
            case .available:
                chatBody
            case .unavailable(let reason):
                UnavailableView(reason: reason)
            }
        }
        .navigationTitle("Chat")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var chatBody: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List(viewModel.messages) { message in
                    MessageBubble(message: message)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .id(message.id)
                }
                .listStyle(.plain)
                .onChange(of: viewModel.messages.last?.id) { _, newID in
                    guard let newID else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(newID, anchor: .bottom)
                    }
                }
            }

            inputRow
        }
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $viewModel.draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)

            Button {
                Task { await viewModel.sendMessage() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
            }
            .disabled(
                viewModel.isThinking
                || viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.isUser { Spacer(minLength: 40) }

            Text(message.content.isEmpty ? " " : message.content)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(message.isUser ? Color.white : Color.primary)
                .background(
                    message.isUser
                        ? AnyShapeStyle(Color.accentColor)
                        : AnyShapeStyle(Color(.secondarySystemBackground))
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)

            if !message.isUser { Spacer(minLength: 40) }
        }
    }
}

private struct UnavailableView: View {
    let reason: SystemLanguageModel.Availability.UnavailableReason

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Chat is unavailable")
                .font(.title3.weight(.semibold))
            Text(explanation)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var explanation: String {
        switch reason {
        case .deviceNotEligible:
            return "This device does not support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in Settings to use chat."
        case .modelNotReady:
            return "The on-device model is still downloading or preparing. Try again shortly."
        @unknown default:
            return "On-device AI is unavailable on this device."
        }
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
