# Step 3: Voice-to-text mic in the chat shell

This walks through everything we did to add a microphone button to the shared `ConversationView` from [step 2](step2.md), so users can dictate their input instead of typing — and crucially, walks through the four iOS 26 Speech-framework gotchas that aren't in the WWDC sample code and will burn an afternoon if you don't know about them.

By the end you'll have:

- A `SpeechCaptureController` that wraps `SpeechAnalyzer` + `DictationTranscriber` + `AVAudioEngine`, exposes a tiny `@Observable` surface (`isRecording`, `partialTranscript`, `lastError`, `availability`), and handles permissions, locale reservation, asset installation, audio-format conversion, and the analyzer lifecycle.
- A microphone button slotted into the existing input row of `ConversationView`. Tap to start, tap to stop. Live transcript streams into the same `draft` binding the keyboard already populates — so both Chat and Patient Intake get voice for free, with zero changes to either ViewModel.
- Two privacy strings (`NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`) added directly in `project.pbxproj` — no separate `Info.plist` file required under Xcode 26.
- Knowledge of why `SpeechTranscriber` doesn't work on the simulator, why `AssetInventory.reserve(locale:)` is the missing "subscription" step, why your audio buffers must be Int16 PCM, and why `.endOfStream` will silently break your converter forever.

## Prerequisites

- You finished [step 2](step2.md). Patient Intake works; the conversational form-fill loop runs end-to-end.
- Apple Intelligence is enabled on host + simulator (see [`APPLE_INTELLIGENCE_SETUP.md`](APPLE_INTELLIGENCE_SETUP.md)). The dictation models share the AI pipeline.
- Some patience. The Speech framework's iOS 26 surface is new enough that the documentation is sparse; this doc front-loads the answers.

---

## Step 1 — Plan the surface

We want a microphone button next to the existing send button, with the simplest possible UX:

- **Tap to start, tap to stop.** No press-and-hold.
- **Transcript streams into the existing `$draft` binding.** Whether the user typed or talked, the rest of the app sees the same `String`. Send/extract is unchanged.
- **No auto-send.** When the user stops dictating, the text sits in the draft for review/edit before they tap send. Voice transcription has errors — proper nouns especially — and the user should fix them before the LLM sees them.
- **Both screens get it for free.** `ConversationView` is the shell behind both Chat and Patient Intake; adding the mic there means both surfaces gain voice without touching either ViewModel.

The implication for architecture: the speech state (recording? partial transcript? error?) is *presentation* concern, not domain concern. It belongs inside the chat shell, not threaded through `ChatViewModel`/`PatientIntakeViewModel`. We give `ConversationView` a `@State private var speech = SpeechCaptureController()` and wire it up.

## Step 2 — Add privacy strings via `project.pbxproj`

Two iOS privacy keys are required:

- `NSMicrophoneUsageDescription` — granted via the standard mic permission alert.
- `NSSpeechRecognitionUsageDescription` — separate alert from `SFSpeechRecognizer.requestAuthorization`.

This project has no `Info.plist` file — Xcode 26 with `GENERATE_INFOPLIST_FILE = YES` inlines those keys directly into `project.pbxproj` as `INFOPLIST_KEY_*` build settings. Add to **both Debug and Release** configs:

```
GENERATE_INFOPLIST_FILE = YES;
INFOPLIST_KEY_NSMicrophoneUsageDescription = "FoundationForms uses the microphone to transcribe what you say into form fields.";
INFOPLIST_KEY_NSSpeechRecognitionUsageDescription = "FoundationForms uses on-device speech recognition to convert your voice into text.";
INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
```

Things worth pointing out:

- **Edit the pbxproj directly, not via a synthesized `Info.plist` file.** The text-format pbxproj is straightforward and Xcode round-trips your edits cleanly. Adding an `Info.plist` *file* would also require flipping `GENERATE_INFOPLIST_FILE` to `NO` and adding `INFOPLIST_FILE = ...`, which is more invasive.
- **Both configs.** Forgetting Release means TestFlight/App Store builds will crash on first mic tap with a generic permission failure — the kind of bug that only shows up in the wrong build configuration.
- **Strings are user-facing.** They appear in the permission alert; write them as one short sentence the user can act on.

## Step 3 — Controller scaffold

Create `FoundationForms/Services/SpeechCaptureController.swift`. We start with state, lifecycle methods, and an availability enum that mirrors the `SystemLanguageModel.Availability` pattern from chat:

```swift
import Foundation
import Speech
import AVFoundation

@Observable
@MainActor
final class SpeechCaptureController {

    enum Availability: Equatable {
        case unknown
        case available
        case unavailable(reason: String)

        var isUnavailable: Bool {
            if case .unavailable = self { return true }
            return false
        }
    }

    var isRecording: Bool = false
    var partialTranscript: String = ""
    var lastError: String?
    var availability: Availability = .unknown

    private let locale: Locale
    private var transcriber: DictationTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var audioEngine: AVAudioEngine?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    private var finalText: String = ""
    private var volatileText: String = ""

    init(locale: Locale = .current) {
        self.locale = locale
    }

    func prewarm() {
        Task { await checkAvailability() }
    }

    private func checkAvailability() async {
        // Optimistic — the real check happens at start() time when we attempt
        // asset reservation and audio session setup.
        if availability == .unknown { availability = .available }
    }
}
```

Things worth pointing out:

- **`@Observable` + `@MainActor`** so the view can bind directly to `isRecording`, `partialTranscript`, etc. with reactive updates. Audio work runs off the main actor (the tap callback is on the audio thread); state mutations marshal back through the MainActor isolation.
- **`partialTranscript` vs `finalText`/`volatileText`.** The transcriber emits both *volatile* (live, revisable) and *final* (committed) results. We accumulate finals and overlay the latest volatile so the user sees stable already-finalized text plus the live tail.
- **Optional storage for `transcriber`/`analyzer`/`audioEngine`.** They only exist while recording. Lifecycle is start → use → stop → tear down → repeat.

## Step 4 — Permissions

Two permissions, both requested lazily on first tap. Add to the controller:

```swift
private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
    await withCheckedContinuation { cont in
        SFSpeechRecognizer.requestAuthorization { status in
            cont.resume(returning: status)
        }
    }
}

func start() async {
    guard !isRecording else { return }
    lastError = nil
    partialTranscript = ""
    finalText = ""
    volatileText = ""

    let speechAuth = await Self.requestSpeechAuthorization()
    guard speechAuth == .authorized else {
        lastError = "Speech recognition permission was denied. Enable it in Settings."
        return
    }

    let micGranted = await AVAudioApplication.requestRecordPermission()
    guard micGranted else {
        lastError = "Microphone permission was denied. Enable it in Settings."
        return
    }

    // ... locale, reserve, install, audio engine, analyzer (next steps)
}
```

Things worth pointing out:

- **Lazy authorization.** Don't request at app launch — users hate that, and it's confusing because they haven't done anything yet that needs the mic. Request on the first tap; iOS shows the alert; subsequent taps skip it because the answer is cached.
- **Two distinct alerts.** Microphone and speech recognition are independent permissions on iOS. Both must be granted; the order doesn't matter, but both fail with their own message.
- **`SFSpeechRecognizer.requestAuthorization` is still callback-based** in iOS 26 — wrap with `withCheckedContinuation` to use it from `async` code. `AVAudioApplication.requestRecordPermission()` is already async (iOS 17+).

## Step 5 — Pick the right transcriber (gotcha #1)

iOS 26 ships **two** speech transcribers:

- `SpeechTranscriber` — the new, high-quality, "Apple Intelligence-class" recognizer.
- `DictationTranscriber` — the broader-compatibility dictation pipeline.

If you naïvely pick `SpeechTranscriber` (the obvious "modern" choice), `AssetInventory.status(forModules:)` returns `.unsupported` on the iOS Simulator without Apple Intelligence on the host, and you get a friendly-but-wrong error: *"On-device speech model isn't supported for en_US on this device."*

The simulator can't see the AI-class models. **Use `DictationTranscriber`.** It's also a better semantic fit for our use case — we want the user dictating multi-sentence input into a text field, and `DictationTranscriber.Preset.progressiveLongDictation` is named for exactly that.

```swift
let transcriber = DictationTranscriber(
    locale: supportedLocale,
    preset: .progressiveLongDictation
)
let analyzer = SpeechAnalyzer(modules: [transcriber])
```

Things worth pointing out:

- **Symptom of getting this wrong:** the friendly error fires immediately on the first tap, before any audio flows. If you see "isn't supported on this device" on the simulator with English locale, swap to `DictationTranscriber`.
- **Preset-based init is cleaner than the options-set init.** The preset bakes in the right `transcriptionOptions`/`reportingOptions` set for "live multi-sentence dictation."
- **`SpeechAnalyzer` is the coordinator;** transcribers are modules. Pass any module(s) to `SpeechAnalyzer(modules: [...])` — the analyzer drives the audio through them and exposes their `results` streams.

## Step 6 — Reserve the locale (gotcha #2)

Apple's iOS 26 speech assets aren't shipped with the OS — they're on-demand resources. Before you can install or query them, your app has to *reserve* the locale. Skip this and `assetInstallationRequest(supporting:)` throws *"Cannot check the download status, com.your.app is not subscribed to transcription.en"* — cryptic, because nothing in the API surface is named "subscribe."

The right call is `AssetInventory.reserve(locale:)`. It registers your app as a consumer of that language's assets:

```swift
guard let supportedLocale = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
    lastError = "On-device dictation isn't available for \(locale.identifier)."
    return
}

do {
    _ = try await AssetInventory.reserve(locale: supportedLocale)
} catch {
    lastError = "Couldn't reserve the dictation model for \(supportedLocale.identifier): \(error.localizedDescription)"
    return
}
```

Things worth pointing out:

- **Resolve the locale first.** `DictationTranscriber.supportedLocale(equivalentTo:)` (on the `LocaleDependentSpeechModule` protocol) maps `Locale.current` to a locale Apple actually ships assets for — e.g. `en` → `en-US`. Pass the *resolved* locale to both `reserve(locale:)` and `DictationTranscriber(locale:)`, or you'll get "subscribed but to a different locale" mismatch behavior.
- **`reserve` is idempotent.** Returns `Bool` indicating whether the reservation was new; safe to call repeatedly.
- **There's a cap.** `AssetInventory.maximumReservedLocales` is small. If a future feature needs to swap languages, balance reservations with `AssetInventory.release(reservedLocale:)`.
- **Where to put `supportedLocale(equivalentTo:)`.** It's defined on the `LocaleDependentSpeechModule` protocol, not on `AssetInventory`. So you call it on `DictationTranscriber` (or `SpeechTranscriber`), not on the inventory class. Easy to misread the headers.

## Step 7 — Status check + asset install

Now that the locale is reserved, check whether the assets are installed. If they are, skip the install request entirely — `assetInstallationRequest(supporting:)` can throw "not subscribed" errors on the simulator even when assets are present.

```swift
let status = await AssetInventory.status(forModules: [transcriber])
switch status {
case .installed:
    break
case .unsupported:
    lastError = "On-device dictation isn't supported for \(supportedLocale.identifier) on this device."
    return
case .downloading, .supported:
    do {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    } catch {
        lastError = "Couldn't prepare the on-device dictation model (status: \(status)): \(error.localizedDescription)"
        return
    }
@unknown default:
    break
}
```

Things worth pointing out:

- **`AssetInventory.Status` has four cases:** `unsupported`, `supported`, `downloading`, `installed`. Branch on them — `unsupported` is the only one that's terminal.
- **Including `status` in the error message** turned out to be invaluable while debugging. When something fails, "couldn't install (status: supported): ..." tells you where in the lifecycle you are.
- **`assetInstallationRequest` returns `Optional`.** A `nil` return means nothing needs to be installed — perfectly fine, fall through.

## Step 8 — Audio session

Configure `AVAudioSession` for recording. Wrap in `#if !os(macOS)` because the project's "Designed for iPad" Mac destination compiles, and `AVAudioSession` is iOS-only:

```swift
#if !os(macOS)
do {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
    try session.setActive(true, options: .notifyOthersOnDeactivation)
} catch {
    lastError = "Couldn't configure the audio session: \(error.localizedDescription)"
    return
}
#endif
```

And in `cleanup()`:

```swift
#if !os(macOS)
try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
#endif
```

Things worth pointing out:

- **`.measurement` mode** disables AGC, EQ, and other DSP. Speech recognition wants clean, unprocessed audio.
- **`.duckOthers`** makes background audio quieter while you're dictating — important for users dictating over a podcast or music.
- **Why `#if !os(macOS)`?** SourceKit complains when checking the macOS slice ("AVAudioSession is unavailable in macOS"). At runtime under "Designed for iPad" the code path that runs is the iOS one; the conditional just calms the indexer.

## Step 9 — Format negotiation (gotcha #3)

The microphone gives you Float32 PCM in its native sample rate (typically 48 kHz). `DictationTranscriber` requires **Int16 PCM**, usually at 16 kHz mono. Feed it Float32 and the framework crashes hard with *"Failed precondition: Audio sample data must be 16-bit signed integers."*

Don't hardcode any of those numbers. The `SpeechModule` protocol exposes `availableCompatibleAudioFormats` — let the framework tell you what shapes it accepts:

```swift
let engine = AVAudioEngine()
let inputFormat = engine.inputNode.outputFormat(forBus: 0)

let compatibleFormats = await transcriber.availableCompatibleAudioFormats
guard let targetFormat = compatibleFormats.first(where: { $0.commonFormat == .pcmFormatInt16 })
        ?? compatibleFormats.first else {
    lastError = "Dictation model returned no compatible audio formats."
    return
}

guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
    lastError = "Couldn't build an audio converter for the dictation model."
    return
}
```

Things worth pointing out:

- **Filter for `.pcmFormatInt16` explicitly.** `availableCompatibleAudioFormats` may return multiple formats; pick the Int16 one to avoid future-shipping-a-subtly-wrong-thing.
- **`AVAudioConverter` handles both bit-depth conversion and resampling** in one pass. The mic's 48 kHz Float32 → analyzer's 16 kHz Int16 is one call.
- **Compute `outCapacity` from the sample-rate ratio**: `AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)`. The `+ 1024` is slack for converter latency on the first buffer — without it you get truncated output.

## Step 10 — Wire the converter callback (gotcha #4)

`AVAudioConverter.convert(to:error:withInputFrom:)` takes a callback that supplies input. The callback is asked once or more per `convert()` call. The status you set in that callback **persists across `convert()` calls** — and getting it wrong silently kills the entire stream.

The wrong code (which I wrote first and which silently produces empty output for every buffer after the first):

```swift
let status = converter.convert(to: outBuffer, error: nil) { _, outStatus in
    if sourceConsumed {
        outStatus.pointee = .endOfStream  // ❌ latches the converter permanently closed
        return nil
    }
    sourceConsumed = true
    outStatus.pointee = .haveData
    return buffer
}
```

The right code:

```swift
engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
    let ratio = targetFormat.sampleRate / inputFormat.sampleRate
    let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
    guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return }

    var sourceConsumed = false
    let status = converter.convert(to: outBuffer, error: nil) { _, outStatus in
        if sourceConsumed {
            // .noDataNow — "no more input for this call, ask again later."
            // .endOfStream would permanently latch the converter closed
            // and reject every subsequent buffer.
            outStatus.pointee = .noDataNow
            return nil
        }
        sourceConsumed = true
        outStatus.pointee = .haveData
        return buffer
    }

    if status != .error && outBuffer.frameLength > 0 {
        continuation.yield(AnalyzerInput(buffer: outBuffer))
    }
}
```

Things worth pointing out:

- **`.noDataNow` ≠ `.endOfStream`.** Read literally:
  - `.haveData` → "here's a buffer for you."
  - `.noDataNow` → "I have nothing more for *this* convert call, but the stream is still alive."
  - `.endOfStream` → "this stream is permanently done; never ask me again."
- **Symptom of `.endOfStream`:** the first buffer converts fine (`status=0`, `out=1600`), every subsequent buffer returns `status=2` and `out=0`. Diagnosing this without a `print` in the tap is nearly impossible — there's no error, no exception, just silence. If you ever debug a converter that "stopped working," check this first.
- **The `continuation` is captured by the tap closure and runs on the audio thread.** `AsyncStream.Continuation` is `Sendable`; this is fine.

## Step 11 — Start the analyzer (and inline-await it)

Two more lifecycle pieces. Listen to the transcriber's results stream, *then* start the analyzer, *then* start the audio engine. Order matters:

```swift
self.audioEngine = engine
self.transcriber = transcriber
self.analyzer = analyzer
self.inputContinuation = continuation

resultsTask = Task { [weak self] in
    guard let self else { return }
    do {
        guard let results = self.transcriber?.results else { return }
        for try await result in results {
            self.append(result: result)
        }
    } catch {
        self.handle(error: error)
    }
}

// Inline-await so the analyzer is actually consuming the input stream
// before any audio flows. start() returns after setup — it does not
// block until the stream ends.
do {
    try await analyzer.start(inputSequence: stream)
} catch {
    lastError = "Couldn't start the dictation analyzer: \(error.localizedDescription)"
    engine.inputNode.removeTap(onBus: 0)
    continuation.finish()
    cleanup()
    return
}

do {
    try engine.start()
} catch {
    lastError = "Couldn't start the microphone: \(error.localizedDescription)"
    engine.inputNode.removeTap(onBus: 0)
    continuation.finish()
    cleanup()
    return
}

isRecording = true
```

Things worth pointing out:

- **`analyzer.start` returns after setup**, not after the stream ends. The analyzer keeps consuming in the framework's own scheduling. Don't wrap it in a `Task { try await ... }` — if the Task isn't scheduled before `engine.start()`, audio piles up in the AsyncStream waiting for an analyzer that hasn't attached. Result: mic captures, no transcripts. Inline `await` makes the order deterministic.
- **`resultsTask` must be set up before `analyzer.start()`** — otherwise the first results from the analyzer's startup phase get dropped before anyone is listening.
- **Error paths call `cleanup()`.** A half-started analyzer + still-active engine + leaked tap is the worst possible state. Tear down before returning.

And the result accumulator — finals get committed, the latest volatile is overlaid:

```swift
private func append(result: DictationTranscriber.Result) {
    let text = String(result.text.characters)
    if result.isFinal {
        finalText = (finalText + " " + text).trimmingCharacters(in: .whitespaces)
        volatileText = ""
    } else {
        volatileText = text
    }
    partialTranscript = (finalText + " " + volatileText).trimmingCharacters(in: .whitespaces)
}
```

Note: `result.isFinal` is provided by an extension on the `SpeechModuleResult` protocol, not declared on `Result` directly — easy to miss when reading the headers.

## Step 12 — Stop and clean up

```swift
func stop() {
    guard isRecording else { return }
    isRecording = false

    audioEngine?.inputNode.removeTap(onBus: 0)
    audioEngine?.stop()
    inputContinuation?.finish()

    let analyzerRef = analyzer
    Task {
        try? await analyzerRef?.finalize(through: nil)
    }

    cleanup()
}

private func cleanup() {
    resultsTask?.cancel()
    resultsTask = nil
    audioEngine = nil
    inputContinuation = nil
    analyzer = nil
    transcriber = nil
    #if !os(macOS)
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    #endif
}
```

Things worth pointing out:

- **`analyzer.finalize(through: nil)`** flushes any in-flight results before tearing down. The `through:` parameter is a `CMTime?` cutoff; `nil` means "everything." Capture `analyzer` into a local `analyzerRef` before `cleanup()` nils it.
- **Order in `stop()`:** stop pulling audio (remove tap, stop engine), then close the input stream (`continuation.finish()`), then finalize the analyzer to drain results. Doing those in the wrong order risks dropping the last sentence.

## Step 13 — Wire into `ConversationView`

The shell already takes a `@Binding var draft: String`. Add a `SpeechCaptureController` as `@State`, slot a mic button into the input row, and bridge the controller's `partialTranscript` into the existing `$draft` binding:

```swift
struct ConversationView: View {
    let messages: [ChatMessage]
    @Binding var draft: String
    let isWorking: Bool
    let availability: SystemLanguageModel.Availability
    let inputPlaceholder: String
    let unavailableTitle: String
    let onSend: () -> Void

    @State private var speech = SpeechCaptureController()

    // ... existing body ...

    private var conversationBody: some View {
        VStack(spacing: 0) {
            // ... messages list ...
            inputRow
        }
        .task { speech.prewarm() }
        .onChange(of: speech.partialTranscript) { _, newValue in
            if speech.isRecording { draft = newValue }
        }
    }

    private var inputRow: some View {
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(inputPlaceholder, text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)

                if !speech.availability.isUnavailable {
                    Button {
                        if speech.isRecording {
                            speech.stop()
                        } else {
                            Task { await speech.start() }
                        }
                    } label: {
                        Image(systemName: speech.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(speech.isRecording ? Color.red : Color.accentColor)
                            .symbolEffect(.pulse, isActive: speech.isRecording)
                    }
                    .accessibilityLabel(speech.isRecording ? "Stop dictation" : "Start dictation")
                }

                Button {
                    onSend()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                }
                .disabled(
                    isWorking
                    || speech.isRecording
                    || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }

            if let err = speech.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
```

Things worth pointing out:

- **The bridge is one `.onChange`.** `speech.partialTranscript` mirrors into `$draft` while `speech.isRecording`. The parent VM never knows whether the text came from the keyboard or the mic.
- **Send is disabled while recording.** Otherwise a mid-sentence dictation could be sent before the user stops.
- **Mic hides if `availability == .unavailable`.** Graceful degrade — the keyboard still works on devices/simulators where dictation isn't available.
- **`speech.lastError` surfaces inline below the row** — a small red caption. Friendlier than a modal alert for transient transcription errors.

## Step 14 — Build & run

```sh
xcodebuild -project FoundationForms.xcodeproj \
  -scheme FoundationForms \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -configuration Debug build
```

Run on the simulator. Patient Intake → tap mic. Two permission dialogs appear (mic, then speech). Grant both. Mic turns red and pulses. Speak: *"My name is Jane Smith, born March 15, 1982."* Text streams into the draft field as you talk. Tap mic again — recording stops, text stays. Tap send — the existing extraction path runs and the form fills.

Same flow works in Chat: tap mic, speak a question, the existing chat path streams the model's reply.

## What the pipeline looks like end-to-end

```mermaid
sequenceDiagram
    actor User
    participant View as ConversationView
    participant Ctrl as SpeechCaptureController
    participant Inv as AssetInventory
    participant Trans as DictationTranscriber
    participant Conv as AVAudioConverter
    participant Eng as AVAudioEngine
    participant Anlz as SpeechAnalyzer

    User->>View: tap mic
    View->>Ctrl: start()
    Ctrl->>Ctrl: request mic + speech permissions
    Ctrl->>Trans: supportedLocale(equivalentTo: .current)
    Trans-->>Ctrl: e.g. "en-US"
    Ctrl->>Inv: reserve(locale:)
    Ctrl->>Inv: status(forModules:)
    Inv-->>Ctrl: .installed / .supported / ...
    Note over Ctrl,Inv: install assets if needed
    Ctrl->>Trans: availableCompatibleAudioFormats
    Trans-->>Ctrl: [Int16 16kHz mono, ...]
    Ctrl->>Conv: AVAudioConverter(Float32 48k → Int16 16k)
    Ctrl->>Eng: install tap (Float32 48k)
    Ctrl->>Anlz: start(inputSequence: stream)
    Ctrl->>Eng: start()
    Note over Ctrl: isRecording = true; mic turns red

    loop while user speaks
        Eng-->>Conv: Float32 buffer (4800 frames)
        Conv-->>Conv: convert (haveData → noDataNow)
        Conv-->>Anlz: AnalyzerInput(Int16, 1600 frames)
        Anlz-->>Trans: process
        Trans-->>Ctrl: Result(text, isFinal)
        Ctrl->>Ctrl: append → partialTranscript
        Ctrl-->>View: @Observable change
        View-->>View: draft = partialTranscript
    end

    User->>View: tap mic again
    View->>Ctrl: stop()
    Ctrl->>Eng: removeTap; stop()
    Ctrl->>Anlz: finalize(through: nil)
    Note over Ctrl: isRecording = false; final text in draft
```

The box at the top of the loop — convert / haveData → noDataNow / Int16 — is the gotcha cluster. Get any of those wrong and the loop falls silent.

## Where to go next

- **Show audio level while recording.** A simple meter (RMS of the input buffer) gives users confidence the mic is hearing them. Useful when transcription is silent because the room is too quiet.
- **Auto-stop on silence.** Detect a pause longer than N seconds and stop recording automatically. Saves a tap per utterance.
- **Custom vocabulary.** `DictationTranscriber.ContentHint.customizedLanguage(modelConfiguration:)` lets you bias the recognizer toward expected terms. Useful for medical jargon in patient intake — "dyspnea" beats "dis-knee-ah."
- **Localization beyond `.current`.** Let the user pick a dictation language; balance reservations with `AssetInventory.release(reservedLocale:)` to stay under `maximumReservedLocales`.
- **Speech detection vs transcription.** `SpeechDetector` (a separate module) tells you when speech is happening without producing text. Pair with the transcriber to drive UI affordances.

## Recap

What you built in this step:

- `SpeechCaptureController` — `@Observable` MainActor wrapper around iOS 26's `SpeechAnalyzer` + `DictationTranscriber` + `AVAudioEngine`. Lazy permissions, locale resolution, asset reservation + status-aware install, audio session config, format negotiation, on-the-fly Float32 → Int16 conversion, and a non-destructive volatile/final transcript merge.
- Two privacy strings (`NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`) inlined into `project.pbxproj` for both Debug and Release.
- A mic button in the existing `ConversationView` input row that bridges `partialTranscript` into the existing `$draft` binding via a single `.onChange`. Both Chat and Patient Intake gain voice with zero ViewModel changes.

And four things you now know that the documentation doesn't make obvious:

1. **`SpeechTranscriber` requires Apple-Intelligence-class hardware.** Use `DictationTranscriber` if you want it to work on the simulator (and for dictation use cases generally).
2. **`AssetInventory.reserve(locale:)` is the missing "subscription" step.** The cryptic "is not subscribed to transcription.en" error means you skipped it.
3. **`DictationTranscriber` requires Int16 PCM.** Use `availableCompatibleAudioFormats` + `AVAudioConverter`; never feed it the mic's native Float32.
4. **`AVAudioConverter`'s input callback status is sticky.** Use `.noDataNow` for "no more input *this call*," not `.endOfStream` — which latches the converter permanently closed.

That's a complete on-device voice surface, sharing a single `LanguageModelSession` per task with the rest of the app, with the chat shell now polyglot for keyboard and voice alike.
