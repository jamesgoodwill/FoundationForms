# Step 1: Add on-device chat to a SwiftUI app with `FoundationModels`

This walks through everything we did to put a working, streaming, on-device chat screen into a fresh SwiftUI iOS app, backed by Apple's `FoundationModels` framework — including the gotchas that aren't in the WWDC sample code.

By the end you'll have:

- A SwiftUI iOS app with a home screen and a Chat screen.
- An `@Observable` `ChatViewModel` that owns the `LanguageModelSession`, streams responses, and handles errors with friendly copy.
- An availability-gated UI that shows a graceful fallback when Apple Intelligence isn't ready.
- A repo layout that's ready to grow (Models / ViewModels / Views).

## Prerequisites

- Xcode 26.2 or later.
- An Apple Silicon Mac running macOS 26 (Foundation Models doesn't work in the simulator on Intel Macs).
- We'll cover enabling the actual on-device model later, in [step 8](#step-8--enable-apple-intelligence-on-the-host-and-the-simulator). For now you can build without it.

---

## Step 1 — Create the project

1. In Xcode: **File → New → Project → iOS → App**.
2. Product Name: `FoundationForms`. Interface: SwiftUI. Language: Swift. Storage: None.
3. Set the iOS Deployment Target to **iOS 26.2**. `FoundationModels` requires iOS 26 — anything older won't link the framework.
4. Save somewhere convenient. You'll get the usual `FoundationFormsApp.swift` + `ContentView.swift` stub.

Notice that the target is set up with a `PBXFileSystemSynchronizedRootGroup`. That means any file you drop into the `FoundationForms/` folder on disk gets picked up automatically by Xcode — no manual "Add Files…" required. We'll lean on this.

## Step 2 — Pick an architecture and reorganize the folders

We're using **MVVM**:

- **Model** — plain Swift types, no SwiftUI import.
- **ViewModel** — `@Observable` class owning presentation state and intent methods. The only thing views talk to for data.
- **View** — thin SwiftUI views, no I/O or decoding inline, previews use stub VMs.

Create three subfolders under `FoundationForms/`:

```
FoundationForms/
├── FoundationFormsApp.swift
├── Models/
├── ViewModels/
└── Views/
```

Move the default `ContentView.swift` into `Views/`. Leave `FoundationFormsApp.swift` at the root — it's the app entry, not a view.

Because the target is a filesystem-synchronized group, you do this in the Finder (or `mv` from the terminal); Xcode picks the changes up next time it indexes:

```sh
cd FoundationForms
mkdir -p Models ViewModels Views
mv ContentView.swift Views/
```

## Step 3 — Define the message model

Create `FoundationForms/Models/ChatMessage.swift`. This is the data shape for a single bubble in the chat:

```swift
import Foundation

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    var content: String
    let isUser: Bool

    init(id: UUID = UUID(), content: String, isUser: Bool) {
        self.id = id
        self.content = content
        self.isUser = isUser
    }
}
```

Two things to note:

- **No `SwiftUI` import.** Models stay framework-agnostic so they're cheap to test and reuse.
- `content` is `var` because the assistant's message gets updated as tokens stream in.

## Step 4 — Build the `ChatViewModel`

This is the file that does the real work. Create `FoundationForms/ViewModels/ChatViewModel.swift`:

```swift
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
```

Things worth pointing out as you read this:

- **`@Observable`** (not `ObservableObject`). It's the modern macro and works with `@State var viewModel = ...` in views.
- **`availability` is read once at `init`.** `SystemLanguageModel.default.availability` is the right gate for whether the model is *usable in principle*. The view branches on it.
- **The session is only constructed when `.available`.** On unsupported devices we never even allocate it.
- **`Instructions(...)` and `Prompt(...)`.** The Foundation Models APIs accept these typed wrappers (rather than plain `String`) and they're `ExpressibleByStringLiteral`. Using the wrappers explicitly avoids subtle overload-resolution issues when you pass runtime strings.
- **Streaming is snapshot-based.** `streamResponse(to:)` yields cumulative `snapshot.content` values, not deltas. So you don't append — you replace. That's why we hold a placeholder bubble and overwrite its `content` on each iteration.
- **Lookup-by-id, not by index.** `updatePlaceholder` finds the bubble by `UUID` so concurrent appends or list reorders can't corrupt it.
- **Friendly errors.** `LanguageModelSession.GenerationError` has well-known cases; mapping them to copy users can act on is much better than dumping `error -1`.

## Step 5 — Build the `ChatView`

Create `FoundationForms/Views/ChatView.swift`:

```swift
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
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
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
            Text("Chat is unavailable").font(.title3.weight(.semibold))
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
            viewModel: ChatViewModel(seedMessages: [
                ChatMessage(content: "Hi! How can I help?", isUser: false),
                ChatMessage(content: "What's the capital of France?", isUser: true),
                ChatMessage(content: "Paris.", isUser: false)
            ])
        )
    }
}
```

Things that aren't obvious:

- **Init that accepts an injected VM.** The default value (`ChatViewModel()`) keeps the call site simple, but the init exists so previews and tests can pass a stubbed VM with seeded messages. The "Available" preview uses this.
- **`ScrollViewReader` + `.onChange(of: viewModel.messages.last?.id)`.** New tokens mutate the *last* message's content. Watching the *last id* is enough to keep autoscroll responsive without re-running for every keystroke.
- **`UnavailableView` switches on the framework's reason.** Each `UnavailableReason` case gets its own copy. `.appleIntelligenceNotEnabled` is the most common one users hit; the "Open Settings" button uses `UIApplication.openSettingsURLString`, which is why we `import UIKit`.
- **Empty placeholder still renders a bubble.** `Text(message.content.isEmpty ? " " : message.content)` keeps the bubble visible (with a thin space) before the first token arrives, so the user sees the assistant "thinking" with the right shape.

## Step 6 — Wire the entry point

Rewrite `FoundationForms/Views/ContentView.swift` so the home screen has a link to chat (and leaves room for future features):

```swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("AI") {
                    NavigationLink {
                        ChatView()
                    } label: {
                        Label("Chat", systemImage: "bubble.left.and.bubble.right")
                    }
                }
            }
            .navigationTitle("FoundationForms")
        }
    }
}

#Preview { ContentView() }
```

`FoundationFormsApp.swift` is unchanged — the default template's `WindowGroup { ContentView() }` is fine.

## Step 7 — Build

From a terminal in the project root:

```sh
xcodebuild -project FoundationForms.xcodeproj \
  -scheme FoundationForms \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -configuration Debug build
```

Pick a simulator that supports iOS 26.x — `iPhone 17 Pro` is a good default. You should see `** BUILD SUCCEEDED **`.

If the build fails on `FoundationModels` not being found, your deployment target is too low; it needs to be **iOS 26.0+**.

## Step 8 — Enable Apple Intelligence on the host and the simulator

The build succeeding only proves your code compiles. To actually get a model response, the on-device assets have to be reachable. In the iOS Simulator, those assets live on the host Mac and the simulator reaches through to them.

Short version:

1. **macOS host:** System Settings → Apple Intelligence & Siri → toggle Apple Intelligence on. Wait for the foundation models to finish downloading (multi-GB, background).
2. **iOS Simulator:** boot an Apple-Intelligence-capable device (e.g. *iPhone 17 Pro*), open Settings → Apple Intelligence & Siri → toggle on.
3. Cold-start the app so `ChatViewModel.init` re-reads availability.

Full version, including symptoms when this isn't set up and the Intel-Mac fallback, is in [`APPLE_INTELLIGENCE_SETUP.md`](APPLE_INTELLIGENCE_SETUP.md). Read it once — it'll save you an hour the first time you hit `assetsUnavailable`.

## Step 9 — Run and verify

Run the app from Xcode (Cmd-R) targeting your iOS 26.x simulator (or device).

What you should see:

- Home screen with a single **Chat** row under "AI".
- Tap it → navigation pushes to the Chat screen.
- Type `Say hello in one sentence.` and tap send → user bubble appears immediately; the assistant bubble starts empty and fills in as tokens stream; the list scrolls to the bottom; the send button is disabled while `isThinking` is true.
- If you're on a device/simulator where Apple Intelligence is unavailable, you'll instead see the **`sparkles.slash`** unavailable view with reason-specific copy and an Open Settings button.

## Step 10 — Ignore these known simulator warnings

You'll likely see one or both of these in the Xcode console while testing in the simulator. **They are false positives** in the simulator's Foundation Models stack and do not appear on real devices.

- `"Running as root is not supported."` — pinned by Xcode to the line that touches `SystemLanguageModel.default.availability`. Your app is *not* actually root; the framework's identity check misfires under simulator sandboxing.
- `"Attempted to update accumulator from source type: 0, after completion has already been called for token: [...]"` — internal bookkeeping noise.

`APPLE_INTELLIGENCE_SETUP.md` has a "Known simulator warnings to ignore" section with the diagnostic `ps` command if you want to confirm your environment is clean.

## Where to go next

- **Make it faster.** `session.prewarm()` on view appear, tuning `GenerationOptions`, and avoiding session churn are the biggest wins. See [`FOUNDATION_MODELS_OPTIMIZATION.md`](FOUNDATION_MODELS_OPTIMIZATION.md).
- **Structured output.** For the real direction of this app (filling forms defined in `basic_information.json`), define `@Generable` Swift types matching the form schema and use `session.respond(to: prompt, generating: ...)` instead of parsing free-form text. That's the natural Step 2.
- **Tools.** Once form-fill is structured, expose per-field actions as types conforming to the `Tool` protocol so the model can only invoke real fields.

## Recap

What you built in this step:

- A canonical SwiftUI MVVM layout (`Models/`, `ViewModels/`, `Views/`) that scales beyond chat.
- A `ChatViewModel` that gates on `SystemLanguageModel` availability, owns a single long-lived `LanguageModelSession`, streams snapshot-based responses into a placeholder bubble, and maps `GenerationError` cases to friendly copy.
- A `ChatView` with availability branching, autoscrolling streamed messages, a styled `MessageBubble`, and an `UnavailableView` that links to Settings.
- A `ContentView` home screen that's ready to grow.

That's a complete, shippable on-device chat surface — and a solid base for the form-fill features that come next.
