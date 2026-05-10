# Foundation Models optimization notes

Practical ways to make `FoundationModels` faster, more reliable, and cheaper (in latency/battery) inside this project. Notes are written against the current code in `FoundationForms/ViewModels/ChatViewModel.swift` and `FoundationForms/Views/ChatView.swift`, and the future direction of using the model to fill forms defined in `basic_information.json`.

## What this codebase already does well

Worth keeping as you extend the app:

- **One long-lived session per ViewModel.** `ChatViewModel` constructs a single `LanguageModelSession` and reuses it across messages. The system's prefix/KV cache is per-session, so reuse is what makes the second turn faster than the first. Don't refactor toward "new session per message."
- **Streaming UI bound to a stable id.** `streamResponse(to:)` yields cumulative snapshots; `updatePlaceholder(id:content:)` looks up the placeholder by `UUID`, not array index, so concurrent appends or list reorders can't corrupt the bubble.
- **Single in-flight guard.** The send button is disabled while `isThinking == true`. `LanguageModelSession` serializes generations — concurrent `streamResponse` calls on the same session will error. Preserve this guard when adding features.
- **Availability-gated session construction.** The `LanguageModelSession` is only built when `availability == .available`, so unsupported devices don't allocate resources or hit asset errors.

## Prewarm so the first response feels instant

Cold load (loading model weights + the safety model) is the biggest one-time cost. Hide it by calling `session.prewarm()` as soon as the chat surface appears, before the user has finished typing:

- Add a `prewarm()` method to `ChatViewModel` that calls `session?.prewarm()`.
- Call it from `ChatView`'s `.task { ... }` modifier (runs once when the view first appears).

Without prewarm, the first message can take several seconds before the first token. With prewarm, you're usually under a second.

## Tune `GenerationOptions` per task

`streamResponse(to:options:)` accepts a `GenerationOptions`. Defaults are fine for chat, but the form-fill use case wants different settings:

- **`temperature`** — keep low (`0.1`–`0.3`) when extracting structured field values from a user utterance. Defaults are tuned for conversational creativity, which is the wrong shape for "extract a ZIP code."
- **`maximumResponseTokens`** — cap aggressively for short answers. Each token costs latency and battery. For a single field value, `64` is plenty.
- **`sampling`** — `.greedy` for deterministic structured tasks; default for chat.

Concretely, this means a form-fill flow should pass its own `GenerationOptions`, not reuse the chat defaults. Plan to thread `options` through `ChatViewModel.sendMessage` (or a sibling extraction VM) when that work lands.

## Prefer `@Generable` over "please return JSON"

For the form-fill direction, do not prompt the model to emit JSON and then parse it — that's slower and lossier than the framework's guided generation. Instead:

1. Define Swift types that mirror the form schema and annotate them with `@Generable`.
2. Use `session.respond(to: prompt, generating: PatientIntake.self)` or the streaming variant.
3. The runtime constrains decoding to your type, so the model can't emit invalid shapes.

This is the single biggest accuracy + latency win for the eventual form-fill feature. The schema in `basic_information.json` (rows of fields with `id`, `type`, `isRequired`, `maxCharacters`) maps cleanly onto a `@Generable` Swift representation.

## Use `Tool` for actions, not prose

When the form-fill assistant needs to *do* something (set a specific field, validate a ZIP, look up a state code), expose those as types conforming to the `Tool` protocol and pass them in the session initializer (`LanguageModelSession(tools: [...], instructions: ...)`). Benefits:

- The model can only invoke tools you registered, so it can't hallucinate a field id that doesn't exist in the schema.
- Tool outputs feed back into the transcript automatically — no manual parsing.
- The framework handles the call/response loop; you just implement the side-effecting Swift code.

## Mind the transcript / context window

Every turn is appended to `session.transcript` automatically. Long chats eventually hit `.exceededContextWindowSize` (already mapped to a friendly message in `ChatViewModel.userMessage(for:)`). Strategies, in order of preference:

1. **Reset for unrelated tasks.** When the user moves from chit-chat to filling a form, build a *new* `LanguageModelSession` for the form. The form-fill session's prefix cache is then pure schema + instructions, not polluted by earlier banter — and the form session won't trip the window on long forms.
2. **Trim old turns.** When you must keep going in one session, drop the oldest turns by constructing a new session seeded with a summary of dropped content via `instructions`.
3. **Summarize on the fly.** Periodically ask the model to compress the transcript and start a fresh session with the summary as instructions.

Don't try to manually mutate `session.transcript` mid-stream — treat it as read-only.

## Session lifecycle and prefix caching

- **One session per logical task.** Chat = one session. Each form fill = its own session. Don't share.
- **Don't churn sessions.** Building a new `LanguageModelSession` discards the prefix cache; the next message pays cold-load cost again.
- **Tear down on memory pressure.** If the app gets a memory warning while a session is idle, releasing the session and re-creating it on next foreground is fair game. The OS may evict the model anyway.

## Latency budget — what actually costs what

Approximate breakdown on a real device with Apple Intelligence enabled and the model already downloaded:

| Cost                                          | When it's paid                          | Mitigation                          |
|-----------------------------------------------|-----------------------------------------|-------------------------------------|
| Model weight load                             | First session use after app launch      | `prewarm()` on view appear          |
| Safety model load                             | First input + first output              | `prewarm()` (covers this too)       |
| Per-turn safety pass (input + output)         | Every message                           | Unavoidable; budget for it          |
| Generation                                    | Every message                           | Cap `maximumResponseTokens`         |
| Re-priming after session swap                 | Each new `LanguageModelSession`         | Reuse sessions across turns         |

Streaming hides much of the generation cost from the user — they see tokens immediately even if total generation takes several seconds. Don't undo that by buffering snapshots into a single update.

## Things you cannot optimize away

- **The input/output safety model runs on every turn.** There's no opt-out. It adds a roughly constant latency floor; budget for it.
- **The first launch after enabling Apple Intelligence is slow.** The OS is downloading multi-GB assets. Documented in `APPLE_INTELLIGENCE_SETUP.md`.
- **No background generation while the app is suspended.** If you start a long generation and the user backgrounds the app, the work pauses. Don't design flows that depend on long-running off-screen generation.
- **No batching across users/sessions.** This is on-device; one prompt at a time per session, and the framework doesn't expose batch APIs.
