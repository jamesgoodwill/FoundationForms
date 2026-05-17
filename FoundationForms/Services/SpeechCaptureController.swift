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

        await checkAvailability()
        if case .unavailable(let reason) = availability {
            lastError = reason
            return
        }

        // Resolve to a locale Dictation actually supports (e.g. "en" → "en-US").
        guard let supportedLocale = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
            lastError = "On-device dictation isn't available for \(locale.identifier)."
            return
        }

        // Reserve the locale so this app is registered as a consumer of its assets.
        // Idempotent — safe to call when already reserved.
        do {
            _ = try await AssetInventory.reserve(locale: supportedLocale)
        } catch {
            lastError = "Couldn't reserve the dictation model for \(supportedLocale.identifier): \(error.localizedDescription)"
            return
        }

        let transcriber = DictationTranscriber(
            locale: supportedLocale,
            preset: .progressiveLongDictation
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Check status before requesting install — assetInstallationRequest can
        // throw a "not subscribed" error on the simulator even when the asset is
        // already present, so skip it entirely when status is .installed.
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

        let engine = AVAudioEngine()
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)

        // Ask the transcriber what audio formats it accepts and pick the first
        // 16-bit integer one (DictationTranscriber requires Int16 PCM).
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

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)

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

        self.audioEngine = engine
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.inputContinuation = continuation

        // Listen for results BEFORE starting the analyzer, so no early results
        // are dropped.
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
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        inputContinuation?.finish()

        // Flush any pending results before tearing down.
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

    private func append(result: DictationTranscriber.Result) {
        let text = String(result.text.characters)
        if result.isFinal {
            finalText = (finalText + " " + text).trimmingCharacters(in: .whitespaces)
            volatileText = ""
        } else {
            volatileText = text
        }
        let combined = (finalText + " " + volatileText).trimmingCharacters(in: .whitespaces)
        partialTranscript = combined
    }

    private func handle(error: Error) {
        lastError = "Transcription error: \(error.localizedDescription)"
        if isRecording { stop() }
    }

    private func checkAvailability() async {
        // Optimistic — the real availability check happens at start() time when
        // we attempt asset installation and audio session setup. If the locale
        // or assets aren't available, the user sees a friendly error then.
        if availability == .unknown {
            availability = .available
        }
    }

    private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
    }
}
