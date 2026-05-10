import Foundation
import FoundationModels

@Observable
final class PatientIntakeViewModel {
    var form: PatientIntakeForm
    var messages: [ChatMessage]
    var draft: String = ""
    var isWorking: Bool = false
    var lastError: String?
    let availability: SystemLanguageModel.Availability

    private var session: LanguageModelSession?

    init(
        seed: PatientIntakeForm = .init(),
        seedMessages: [ChatMessage]? = nil
    ) {
        self.form = seed
        self.messages = seedMessages ?? [Self.greeting]
        self.availability = SystemLanguageModel.default.availability
        if case .available = availability {
            self.session = Self.makeSession(for: seed)
        }
    }

    /// Call when the intake screen first appears so the model is warm before
    /// the user finishes typing. See FOUNDATION_MODELS_OPTIMIZATION.md.
    func prewarm() {
        session?.prewarm()
    }

    /// Process the drafted message: extract structured fields, merge into
    /// `form`, and post a short assistant reply summarizing what was captured.
    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, case .available = availability else { return }

        draft = ""
        messages.append(ChatMessage(content: text, isUser: true))

        let placeholder = ChatMessage(content: "", isUser: false)
        let placeholderID = placeholder.id
        messages.append(placeholder)

        // Rebuild so the instructions reflect the latest "already known" state.
        let session = Self.makeSession(for: form)
        self.session = session

        isWorking = true
        lastError = nil
        defer { isWorking = false }

        let before = form
        do {
            let response = try await session.respond(
                to: Prompt(text),
                generating: PatientIntakeFormExtraction.self,
                options: Self.extractionOptions
            )
            form = PatientIntakeForm(merging: response.content, into: before)
            updatePlaceholder(id: placeholderID, content: Self.summary(before: before, after: form))
        } catch let error as LanguageModelSession.GenerationError {
            let msg = Self.userMessage(for: error)
            lastError = msg
            updatePlaceholder(id: placeholderID, content: msg)
        } catch {
            let msg = "Extraction failed: \(error.localizedDescription)"
            lastError = msg
            updatePlaceholder(id: placeholderID, content: msg)
        }
    }

    private func updatePlaceholder(id: UUID, content: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].content = content
    }

    private static let greeting = ChatMessage(
        content: "Hi! Tell me about the patient — name, date of birth, address, and what they're experiencing.",
        isUser: false
    )

    private static func makeSession(for form: PatientIntakeForm) -> LanguageModelSession {
        LanguageModelSession(
            instructions: Instructions(form.extractionInstructions())
        )
    }

    // Greedy + low-temperature settings for deterministic structured extraction
    // (per FOUNDATION_MODELS_OPTIMIZATION.md "Tune GenerationOptions per task").
    private static let extractionOptions = GenerationOptions(
        sampling: .greedy,
        temperature: 0.1,
        maximumResponseTokens: 512
    )

    private static func summary(before: PatientIntakeForm, after: PatientIntakeForm) -> String {
        let added = changedFieldLabels(from: before, to: after)
        let missing = missingFieldLabels(in: after)

        var parts: [String] = []
        if added.isEmpty {
            parts.append("I didn't pick up any new fields from that.")
        } else {
            parts.append("Got " + added.joined(separator: ", ") + ".")
        }
        if missing.isEmpty {
            parts.append("Everything's filled in — review the form on the right.")
        } else {
            parts.append("Still need: " + missing.joined(separator: ", ") + ".")
        }
        return parts.joined(separator: " ")
    }

    private static func changedFieldLabels(
        from old: PatientIntakeForm,
        to new: PatientIntakeForm
    ) -> [String] {
        var out: [String] = []
        if old.firstName != new.firstName { out.append("first name") }
        if old.lastName != new.lastName { out.append("last name") }
        if old.dateOfBirth != new.dateOfBirth { out.append("date of birth") }
        if old.address?.street != new.address?.street { out.append("street") }
        if old.address?.city != new.address?.city { out.append("city") }
        if old.address?.state != new.address?.state { out.append("state") }
        if old.address?.zip != new.address?.zip { out.append("ZIP") }
        if old.symptoms != new.symptoms { out.append("symptoms") }
        return out
    }

    private static func missingFieldLabels(in form: PatientIntakeForm) -> [String] {
        var out: [String] = []
        if (form.firstName ?? "").isEmpty { out.append("first name") }
        if (form.lastName ?? "").isEmpty { out.append("last name") }
        if form.dateOfBirth == nil { out.append("date of birth") }
        if (form.address?.street ?? "").isEmpty { out.append("street") }
        if (form.address?.city ?? "").isEmpty { out.append("city") }
        if (form.address?.state ?? "").isEmpty { out.append("state") }
        if (form.address?.zip ?? "").isEmpty { out.append("ZIP") }
        if (form.symptoms ?? "").isEmpty { out.append("symptoms") }
        return out
    }

    private static func userMessage(for error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .assetsUnavailable:
            return "The on-device model isn't ready. Enable Apple Intelligence in Settings and wait for the model to finish downloading."
        case .exceededContextWindowSize:
            return "Conversation history is too long. Start a fresh intake to continue."
        case .guardrailViolation:
            return "Apple's safety system blocked this input."
        case .unsupportedLanguageOrLocale:
            return "The model doesn't support this language yet."
        case .rateLimited:
            return "Too many requests in a short window. Try again in a moment."
        case .decodingFailure:
            return "The model returned a response that couldn't be decoded into the form."
        case .unsupportedGuide:
            return "A `@Guide` constraint isn't supported by the runtime."
        default:
            return "Extraction failed: \(error.localizedDescription)"
        }
    }
}
