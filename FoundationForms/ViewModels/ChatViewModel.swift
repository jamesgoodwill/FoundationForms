import Foundation
import FoundationModels

@Observable
final class ChatViewModel {
    var messages: [ChatMessage]
    var draft: String = ""
    var isThinking: Bool = false
    let availability: SystemLanguageModel.Availability

    private let instructions: String
    private var session: LanguageModelSession?

    init(
        instructions: String = "You are a helpful assistant named AppleBot. Be concise.",
        seedMessages: [ChatMessage] = []
    ) {
        self.instructions = instructions
        self.messages = seedMessages
        self.availability = SystemLanguageModel.default.availability
        if case .available = availability {
            self.session = LanguageModelSession(instructions: Instructions(instructions))
        }
    }

    func sendMessage() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let session else { return }

        draft = ""
        messages.append(ChatMessage(content: text, isUser: true))

        let placeholder = ChatMessage(content: "", isUser: false)
        let placeholderID = placeholder.id
        messages.append(placeholder)

        isThinking = true
        defer { isThinking = false }

        do {
            let stream = session.streamResponse(to: Prompt(text))
            for try await snapshot in stream {
                updatePlaceholder(id: placeholderID, content: snapshot.content)
            }
        } catch let error as LanguageModelSession.GenerationError {
            print("FoundationModels GenerationError: \(error)")
            updatePlaceholder(id: placeholderID, content: Self.userMessage(for: error))
        } catch {
            print("FoundationModels error: \(error)")
            updatePlaceholder(
                id: placeholderID,
                content: "Sorry, something went wrong: \(error.localizedDescription)"
            )
        }
    }

    private func updatePlaceholder(id: UUID, content: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].content = content
    }

    private static func userMessage(for error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .assetsUnavailable:
            return "The on-device model isn't ready. Enable Apple Intelligence in Settings and wait for the model to finish downloading. On the iOS Simulator, the host Mac must also have Apple Intelligence enabled."
        case .exceededContextWindowSize:
            return "This conversation is too long for the model's context window. Start a new chat to continue."
        case .guardrailViolation:
            return "Apple's safety system blocked this request or response."
        case .unsupportedLanguageOrLocale:
            return "The model doesn't support this language yet."
        case .rateLimited:
            return "Too many requests in a short window. Try again in a moment."
        case .decodingFailure:
            return "The model returned a response that couldn't be decoded."
        case .unsupportedGuide:
            return "The structured-output guide isn't supported."
        default:
            return "Generation failed: \(error.localizedDescription)"
        }
    }
}
