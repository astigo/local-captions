import Foundation
import AVFoundation
import CoreML
import FluidAudio

enum CaptionChunking {
    /// Commit complete words only after the following word has started.
    /// Text segmentation never clears the recognizer's audio or decoder state.
    static func boundary(in text: String, maxWords: Int = 24) -> String.Index? {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard maxWords > 0, words.count > maxWords else { return nil }
        return words[maxWords].startIndex
    }

    static func stableBoundary(in text: String, stableCharacters: Int) -> String.Index? {
        let stable = String(text.prefix(stableCharacters))
        // A sentence boundary is useful even before 24 words; keep short abbreviations
        // with their context. Every committed character must be in the stable prefix.
        let words = stable.split(whereSeparator: \.isWhitespace)
        if words.count >= 6,
           let word = words.enumerated().first(where: { $0.offset >= 5 && ".!?".contains($0.element.last!) })?.element {
            return text.index(text.startIndex, offsetBy: stable.distance(from: stable.startIndex, to: word.endIndex))
        }
        guard let boundary = boundary(in: text), text.distance(from: text.startIndex, to: boundary) <= stableCharacters else { return nil }
        return boundary
    }
}

actor Recognition {
    private let choice: RecognitionModel
    private let mode: CaptionMode
    private var ultra: SlidingWindowAsrManager?
    private var ultraModels: AsrModels?
    private var ultraTranscript: UltraTranscript?
    private var ultraUpdates: Task<Void, Error>?
    private var ultraError: Error?
    private var ultraSamplesSent = 0
    private var ultraSamplesProcessed = 0
    private var ultraSilenceSamples = 0
    private var ultraHadSignal = false
    private var worker: LocalWorker?
    private let store: CaptionStore
    private let session: UUID
    private var samples: [Float] = []
    private var phraseID = UUID()
    private var phraseText = ""
    private var phraseWordEnds: [TimeInterval?]?
    private let clock: AudioClock?
    private let ultraChunkSeconds: Double
    private let glossary: @Sendable () -> Glossary
    private let translationLanguage: @Sendable () -> TranslationLanguage
    /// Samples given to the recognizer so far; positions in `clock` use the same count.
    private var sessionSamples = 0
    private var ultraBaseSample = 0
    private var committedCharacters = 0
    private var translating: [UUID: Task<Void, Never>] = [:]
    private var stopped = false
    let onStatus: @Sendable (String) -> Void

    init(worker: LocalWorker?, store: CaptionStore, session: UUID, model choice: RecognitionModel = .ultra,
         mode: CaptionMode = .translation, clock: AudioClock? = nil,
         ultraChunkSeconds: Double? = nil,
         glossary: @escaping @Sendable () -> Glossary = { Glossary(text: "") },
         translationLanguage: @escaping @Sendable () -> TranslationLanguage = { .russian },
         onStatus: @escaping @Sendable (String) -> Void) {
        self.worker = worker; self.store = store; self.session = session; self.onStatus = onStatus
        self.mode = mode; self.choice = choice; self.clock = clock
        self.ultraChunkSeconds = ultraChunkSeconds ?? RecognitionTuning.ultraChunkSeconds(for: mode); self.glossary = glossary
        self.translationLanguage = translationLanguage
    }

    func load(runtime: URL) async throws {
        guard !stopped else { throw CancellationError() }
        let config = MLModelConfiguration(); config.computeUnits = .cpuAndNeuralEngine
        // One case per recognizer; a new model for comparison adds its own loading here.
        switch choice {
        case .ultra:
            // loadLocal never downloads or keeps another recognizer in a shared model cache.
            let models = try AsrModels.loadLocal(from: choice.directory(in: runtime), version: .ultra, configuration: config)
            let warmup = AsrManager()
            try await warmup.loadModels(models)
            do {
                var decoder = TdtDecoderState.make(decoderLayers: AsrModelVersion.ultra.decoderLayers)
                _ = try await warmup.transcribe([Float](repeating: 0, count: 25600), decoderState: &decoder, language: mode.languageHint)
            } catch {
                await warmup.cleanup()
                throw error
            }
            await warmup.cleanup()
            try Task.checkCancellation()
            ultraModels = models
            try await startUltraSegment(models)
        }
    }

    private func startUltraSegment(_ models: AsrModels) async throws {
        let manager = SlidingWindowAsrManager(config: SlidingWindowAsrConfig(
            chunkSeconds: ultraChunkSeconds, hypothesisChunkSeconds: ultraChunkSeconds,
            leftContextSeconds: 6, rightContextSeconds: 0.32,
            minContextForConfirmation: 0, language: mode.languageHint))
        ultra = manager
        ultraTranscript = UltraTranscript(vocabulary: models.vocabulary)
        ultraSamplesSent = 0; ultraSamplesProcessed = 0; ultraBaseSample = sessionSamples
        ultraSilenceSamples = 0; ultraHadSignal = false
        try await manager.loadModels(models)
        let updates = await manager.tokenUpdates
        ultraUpdates = Task { [weak self] in
            do {
                for try await update in updates {
                    try Task.checkCancellation()
                    try await self?.acceptUltra(update)
                }
            } catch {
                await self?.setUltraError(error)
                throw error
            }
        }
        try await manager.startStreaming(source: .system)
    }

    private func finishUltraSegment(restart: Bool) async throws {
        guard let manager = ultra else { return }
        _ = try await manager.finish()
        try await ultraUpdates?.value
        if let ultraError { throw ultraError }
        await finishCaption()
        await manager.cleanup()
        ultra = nil; ultraUpdates = nil; ultraTranscript = nil; committedCharacters = 0
        if restart, !stopped, let models = ultraModels { try await startUltraSegment(models) }
    }

    func consume(_ incoming: [Float]) async throws {
        guard !stopped else { return }
        if let ultraError { throw ultraError }
        samples.append(contentsOf: incoming)
        let window = 5120 // 320 ms; no language classifier or discarded language windows
        while samples.count >= window {
            let block = Array(samples.prefix(window)); samples.removeFirst(window)
            try await process(block)
        }
    }

    private func process(_ block: [Float]) async throws {
        try Task.checkCancellation()
        guard !stopped else { return }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block.count))!
        pcm.frameLength = pcm.frameCapacity
        block.withUnsafeBufferPointer { pcm.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        sessionSamples += block.count
        guard let ultra else { throw CaptionsError.message("Модель не загружена") }
        guard ultraSamplesSent - ultraSamplesProcessed < 15 * 16000 else {
            throw CaptionsError.message("Ultra не успевает за звуком. Остановите сеанс и увеличьте окно Ultra в настройках.")
        }
        ultraSamplesSent += block.count
        await ultra.streamAudio(pcm)
        onStatus("Слушаю · \(mode.title) · Ultra")
        // Only near-digital silence closes a segment; this does not classify language
        // or discard quiet audio. All samples, including the pause, reach the model.
        let energy = block.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(block.count)
        if energy < 0.0000001 { ultraSilenceSamples += block.count }
        else { ultraSilenceSamples = 0; ultraHadSignal = true }
        if ultraHadSignal && ultraSilenceSamples >= 20480 {
            try await finishUltraSegment(restart: true)
        }
    }

    private func acceptUltra(_ update: SlidingWindowTokenUpdate) async throws {
        guard !stopped else { return }
        try ultraTranscript?.apply(update)
        ultraSamplesProcessed = update.revision.center.upperBound
        guard let transcript = ultraTranscript else { return }
        await updateText(transcript.text, stableCharacters: transcript.stableText.count,
                         wordEnds: transcript.wordEnds(baseSample: ultraBaseSample))
    }

    private func setUltraError(_ error: Error) { ultraError = error }

    private func updateText(_ fullText: String, stableCharacters: Int? = nil, wordEnds: [Int]? = nil) async {
        guard !stopped else { return }
        var remaining = String(fullText.dropFirst(committedCharacters))
        while true {
            let boundary: String.Index?
            if let stableCharacters {
                boundary = CaptionChunking.stableBoundary(in: remaining, stableCharacters: max(0, stableCharacters - committedCharacters))
            } else {
                boundary = CaptionChunking.boundary(in: remaining)
            }
            guard let boundary else { break }
            phraseText = String(remaining[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
            phraseWordEnds = uptimes(WordTimings.slice(wordEnds, fullText: fullText, prefixCharacters: committedCharacters, phrase: phraseText))
            committedCharacters += remaining.distance(from: remaining.startIndex, to: boundary)
            await finishCaption()
            remaining = String(fullText.dropFirst(committedCharacters))
        }
        guard !stopped else { return }
        phraseText = String(fullText.dropFirst(committedCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
        phraseWordEnds = uptimes(WordTimings.slice(wordEnds, fullText: fullText, prefixCharacters: committedCharacters, phrase: phraseText))
        if !phraseText.isEmpty {
            let id = phraseID, text = phraseText, store = store, session = session, ends = phraseWordEnds
            await AppRunLoop.update { store.partial(id: id, text: text, session: session, wordEnds: ends) }
        }
    }

    private func uptimes(_ samples: [Int]?) -> [TimeInterval?]? {
        guard let samples, let clock else { return nil }
        return samples.map { clock.uptime(atSample: $0) }
    }

    private func finishCaption() async {
        let text = phraseText, id = phraseID, ends = phraseWordEnds
        phraseID = UUID(); phraseText = ""; phraseWordEnds = nil
        guard !text.isEmpty, !stopped else { return }
        let store = store, session = session
        await AppRunLoop.update {
            store.partial(id: id, text: text, session: session, wordEnds: ends)
            store.finalized(id: id, session: session)
        }
        guard mode.translates else { return }
        // Translation switched off: transcription goes on, phrases simply stay untranslated.
        guard let worker else { return }
        // Translation has its own worker queue and must never stop English captions.
        guard translating.count < 3 else {
            await store.translationFailed(id: id, message: "Перевод отстаёт от речи", session: session)
            return
        }
        // Into the chosen language; a phrase already in it goes into English (Russian when English is chosen).
        let target = translationLanguage().target(for: text)
        let terms = target.glossaryLanguage.map { glossary().pairs(in: text, target: $0) } ?? []
        translating[id] = Task { [weak self, worker, store, session] in
            do {
                let translation = try await worker.translate(text, into: target, terms: terms)
                try Task.checkCancellation()
                await store.translated(id: id, text: translation, session: session, language: target)
            } catch {
                await store.translationFailed(id: id, message: error.localizedDescription, session: session)
                if !Task.isCancelled { await self?.reportTranslationError(error) }
            }
            await self?.translationFinished(id)
        }
    }

    private func translationFinished(_ id: UUID) { translating.removeValue(forKey: id) }

    /// Translation can be switched on and off during a session without touching recognition.
    func setWorker(_ worker: LocalWorker?) { self.worker = worker }
    var isUltra: Bool { ultraModels != nil }
    private func reportTranslationError(_ error: Error) { onStatus("Ошибка перевода: \(error.localizedDescription)") }

    func finishInput() async throws {
        // A file or a stopped source may end without a final silence buffer.
        samples.append(contentsOf: [Float](repeating: 0, count: 15360))
        try await consume([])
        if !samples.isEmpty {
            let tail = samples; samples.removeAll()
            try await process(tail)
        }
        if ultra != nil { try await finishUltraSegment(restart: false) }
        await finishCaption()
        for task in Array(translating.values) { await task.value }
    }

    func transcribeMicrophone(_ segment: MicrophoneSegment) async throws -> Caption? {
        guard let models = ultraModels else { throw CaptionsError.message("Для канала микрофона нужна Ultra") }
        let manager = AsrManager()
        try await manager.loadModels(models) // Same MLModel weights, independent decoder state.
        do {
            var decoder = TdtDecoderState.make(decoderLayers: AsrModelVersion.ultra.decoderLayers)
            let result = try await manager.transcribe(segment.url, decoderState: &decoder, language: nil)
            await manager.cleanup()
            let text = Self.clean(result.text)
            guard !text.isEmpty else { return nil }
            let offset = max(0, result.tokenTimings?.first?.startTime ?? 0)
            return Caption(id: segment.id, english: text, firstSeenAt: Date(), finalized: true,
                original: text, channel: "microphone", audioStartAt: segment.startedAt.addingTimeInterval(offset), audioEndAt: segment.endedAt)
        } catch { await manager.cleanup(); throw error }
    }

    func stop() async {
        stopped = true
        for task in translating.values { task.cancel() }
        translating.removeAll(); samples.removeAll()
        await ultra?.cleanup()
        ultraUpdates?.cancel()
        _ = await ultraUpdates?.result
        ultra = nil; ultraModels = nil; ultraUpdates = nil; ultraTranscript = nil
    }
    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "<EOU>", with: "")
            .replacingOccurrences(of: "▁", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor final class CaptionEngine: ObservableObject {
    @Published private(set) var state = "Остановлено"
    @Published private(set) var active = false
    @Published private(set) var busy = false
    @Published var error: String?
    @Published var meetingTitle = ""
    @Published var selectedTranslator = TranslationModel(rawValue: UserDefaults.standard.string(forKey: "translationModel") ?? "") ?? .hymt {
        didSet { UserDefaults.standard.set(selectedTranslator.rawValue, forKey: "translationModel") }
    }
    @Published private(set) var microphoneEnabled = UserDefaults.standard.bool(forKey: "microphoneEnabled")
    @Published private(set) var microphoneState = ""
    @Published var selectedModel = RecognitionModel(rawValue: UserDefaults.standard.string(forKey: "recognitionModel") ?? "") ?? .ultra {
        didSet { UserDefaults.standard.set(selectedModel.rawValue, forKey: "recognitionModel") }
    }
    @Published private(set) var selectedMode = CaptionMode(rawValue: UserDefaults.standard.string(forKey: "captionMode") ?? "") ?? .learning
    /// Transcription always runs; translation is a switch, so the translator does not run when not needed.
    @Published private(set) var translationEnabled = UserDefaults.standard.object(forKey: "translationEnabled") as? Bool ?? true
    /// Hidden subtitles still record the meeting; only the overlay is off.
    @Published private(set) var subtitlesVisible = UserDefaults.standard.object(forKey: "subtitlesVisible") as? Bool ?? true
    @Published private(set) var saveError: String?
    let store = CaptionStore()
    private var audio: SystemAudio?
    private var worker: LocalWorker?
    private var recognition: Recognition?
    private var microphoneCapture: MicrophoneCapture?
    private var microphoneTranscription: MicrophoneTranscription?
    private var microphoneDrains: [Task<Void, Never>] = []
    private var translationSwitch: Task<Void, Never>?
    private var startup: Task<Void, Never>?
    private var reader: Task<Void, Never>?
    private var shutdown: Task<Void, Never>?
    private var audioInput: LiveAudioInput?
    private var session = UUID()
    private var watchdog: Timer?
    private let sourceMonitor = AudioSourceMonitor()
    /// What the running session uses, for its metrics line.
    private var run: (session: UUID, mode: CaptionMode, model: RecognitionModel, ultraChunk: Double)?
    init() {
        // EN+RU is now learning with translation off.
        if selectedMode == .transcription {
            selectedMode = .learning; translationEnabled = false
            UserDefaults.standard.set(CaptionMode.learning.rawValue, forKey: "captionMode")
            UserDefaults.standard.set(false, forKey: "translationEnabled")
        }
        selectedModel = microphoneEnabled ? .ultra : selectedModel
    }

    /// The microphone can be switched during a session; turning it off transcribes what it recorded.
    func setMicrophoneEnabled(_ enabled: Bool) {
        guard !busy, enabled != microphoneEnabled else { return }
        if active {
            guard let recognition, let input = audioInput else { return }
            if enabled {
                guard run?.model == .ultra else {
                    error = "Микрофон на ходу работает только с Ultra. Остановите сеанс и включите его до запуска."
                    return
                }
                microphoneEnabled = true
                let current = session
                Task {
                    do {
                        guard await MicrophoneCapture.requestAccess() else { throw CaptionsError.message("Нет доступа к микрофону в настройках macOS") }
                        guard session == current, active else { return }
                        try await startMicrophone(recognizer: recognition, input: input)
                    } catch {
                        microphoneEnabled = false
                        self.error = "Микрофон не включён: \(error.localizedDescription)"
                    }
                }
            } else {
                microphoneEnabled = false
                microphoneCapture?.stop(); microphoneCapture = nil
                if let background = microphoneTranscription {
                    microphoneTranscription = nil
                    microphoneDrains.append(Task { [weak self] in
                        do { try await background.finishAndDrain() }
                        catch { self?.saveError = "Микрофон не расшифрован: \(error.localizedDescription). Фрагменты сохранены в Transcripts/.pending-microphone" }
                    })
                }
            }
        } else {
            microphoneEnabled = enabled
            if enabled { selectedModel = .ultra }
        }
        UserDefaults.standard.set(enabled, forKey: "microphoneEnabled")
    }

    private func startMicrophone(recognizer: Recognition, input: LiveAudioInput) async throws {
        // A fresh folder each time: the microphone may be switched on more than once per meeting.
        let directory = transcriptsDirectory.appendingPathComponent(".pending-microphone")
            .appendingPathComponent(store.session.uuidString).appendingPathComponent(UUID().uuidString)
        let spool = try MicrophoneSpool(directory: directory, journal: store.recordingJournal?.eventsURL)
        let microphone = MicrophoneCapture(); microphoneCapture = microphone
        try microphone.start(spool: spool)
        let background = MicrophoneTranscription(spool: spool, recognizer: recognizer, store: store, input: input) { [weak self] message in
            AppRunLoop.perform { [weak self] in self?.microphoneState = message }
        }
        microphoneTranscription = background
        await background.start()
    }

    func setSubtitlesVisible(_ visible: Bool) {
        subtitlesVisible = visible
        UserDefaults.standard.set(visible, forKey: "subtitlesVisible")
    }

    /// Starts or stops the translator during a session; recognition is not interrupted.
    func setTranslationEnabled(_ enabled: Bool) {
        guard enabled != translationEnabled else { return }
        translationEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "translationEnabled")
        guard active, run?.mode.translates == true else { return }
        let previous = translationSwitch, translator = selectedTranslator, current = session
        translationSwitch = Task {
            await previous?.value
            guard session == current, active else { return }
            if enabled, worker == nil {
                let script = Bundle.main.resourceURL?.appendingPathComponent("worker.py") ?? URL(fileURLWithPath: "backend/worker.py")
                let started = LocalWorker()
                do {
                    try await started.start(runtime: runtime, script: script, model: translator)
                    guard session == current, active, translationEnabled else { await started.stop(); return }
                    worker = started; store.translationActive = true
                    await recognition?.setWorker(started)
                } catch {
                    await started.stop()
                    translationEnabled = false
                    self.error = "Переводчик не запустился: \(error.localizedDescription)"
                }
            } else if !enabled, let running = worker {
                await recognition?.setWorker(nil)
                worker = nil; store.translationActive = false
                await running.stop()
            }
        }
    }

    func selectMode(_ mode: CaptionMode) {
        guard !active, !busy else { return }
        selectedMode = mode
        selectedModel = microphoneEnabled ? .ultra : selectedModel
        UserDefaults.standard.set(mode.rawValue, forKey: "captionMode")
    }
    var transcriptsDirectory: URL { runtime.deletingLastPathComponent().appendingPathComponent("Transcripts", isDirectory: true) }

    var runtime: URL {
        if let override = ProcessInfo.processInfo.environment["LOCAL_CAPTIONS_RUNTIME"] { return URL(fileURLWithPath: override) }
        let project = Bundle.main.object(forInfoDictionaryKey: "LocalCaptionsProject") as? String ?? FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: project).appendingPathComponent(".runtime")
    }

    func start() {
        guard !active, !busy, shutdown == nil else { return }
        let mode = selectedMode, selected: RecognitionModel = microphoneEnabled ? .ultra : selectedModel
        error = nil; saveError = nil; busy = true; state = "Загружаю \(selected.title)…"
        microphoneState = ""
        session = UUID(); let current = session
        store.begin(mode: mode)
        let captionSession = store.session
        run = (captionSession, mode, selected, RecognitionTuning.ultraChunkSeconds(for: mode))
        let worker = mode.translates && translationEnabled ? LocalWorker() : nil; self.worker = worker
        store.translationActive = worker != nil
        let script = Bundle.main.resourceURL?.appendingPathComponent("worker.py") ?? URL(fileURLWithPath: "backend/worker.py")
        startup = Task {
            do {
                if microphoneEnabled, !(await MicrophoneCapture.requestAccess()) {
                    throw CaptionsError.message("Разрешите Local Captions доступ к микрофону в настройках macOS или выключите канал «Я»")
                }
                try Task.checkCancellation()
                try await worker?.start(runtime: runtime, script: script, model: selectedTranslator)
                try Task.checkCancellation()
                guard session == current else { return }
                let input = LiveAudioInput(); audioInput = input
                let transcripts = transcriptsDirectory
                let recognizer = Recognition(worker: worker, store: store, session: captionSession, model: selected, mode: mode,
                                             clock: input.clock, glossary: { Glossary.load(transcripts: transcripts) },
                                             translationLanguage: { TranslationLanguage.stored() }) { [weak self] status in
                    Task { @MainActor in
                        guard let self, self.session == current, self.active else { return }
                        self.state = status
                    }
                }
                recognition = recognizer
                try await recognizer.load(runtime: runtime)
                try Task.checkCancellation()
                guard session == current else { return }
                let capture = SystemAudio()
                capture.onAudio = { [weak self] samples in
                    if !input.append(samples) {
                        AppRunLoop.perform { [weak self] in
                            self?.fail("Распознавание отстало от звука более чем на 15 секунд. Повторите запуск.", session: current)
                        }
                    }
                }
                capture.onError = { [weak self] error in
                    Task { @MainActor in self?.fail("Захват звука прервался: \(error.localizedDescription)", session: current) }
                }
                audio = capture
                state = "Запрашиваю доступ к системному звуку…"
                try await capture.start()
                try Task.checkCancellation()
                guard session == current else { await capture.stop(); return }
                try store.record(to: transcriptsDirectory, title: meetingTitle, model: selected.title,
                    translator: mode.translates ? selectedTranslator.title : nil, microphone: microphoneEnabled) { [weak self] message in
                    Task { @MainActor in self?.saveError = message }
                }
                if microphoneEnabled { try await startMicrophone(recognizer: recognizer, input: input) }
                store.currentSources = AudioSourceMonitor.outputCandidates()
                sourceMonitor.start { [weak self] sources in
                    guard let self, self.session == current else { return }
                    self.store.currentSources = sources
                }
                busy = false; active = true; state = "Слушаю · \(selected.title)"
                watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.active else { return }
                        let activity = input.activity()
                        if activity.idle > 4 {
                            self.state = activity.seen ? "Слушаю · нет звука" : "Слушаю · запустите аудио в любом приложении"
                        }
                        if !input.padIfIdle() {
                            self.fail("Распознавание отстало от звука более чем на 15 секунд. Повторите запуск.", session: current)
                        }
                    }
                }
                reader = Task.detached(priority: .userInitiated) { [weak self] in
                    do {
                        for await samples in input.stream {
                            try Task.checkCancellation()
                            try await recognizer.consume(samples)
                        }
                    } catch {
                        if !Task.isCancelled { await self?.fail(error.localizedDescription, session: current) }
                    }
                }
            } catch {
                if !Task.isCancelled { fail(error.localizedDescription, session: current) }
            }
        }
    }

    private func fail(_ message: String, session expected: UUID) {
        guard session == expected else { return }
        stop(); error = message
    }

    func stop() {
        guard shutdown == nil else { return }
        session = UUID(); active = false; busy = true; state = "Останавливаю и освобождаю модель…"
        let startup = startup, reader = reader
        startup?.cancel(); self.startup = nil; reader?.cancel(); self.reader = nil
        audioInput?.finish(); audioInput = nil
        watchdog?.invalidate(); watchdog = nil
        sourceMonitor.stop()
        microphoneCapture?.stop()
        let transcript = store.recordingJournal?.markdownURL.lastPathComponent
        let finishedRun = store.recordingJournal == nil ? nil : run
        run = nil
        store.prepareToFinish()
        shutdown = Task { [self] in
            // Cancelling model loading does not necessarily interrupt a Core ML load.
            // Keep Start and the picker locked until all old work and cleanup finish.
            await worker?.stop()
            await startup?.value
            await audio?.stop()
            await reader?.value
            await translationSwitch?.value; translationSwitch = nil
            for drain in microphoneDrains { await drain.value }
            microphoneDrains = []
            do {
                if let microphoneTranscription {
                    state = "Дорасшифровываю канал «Я»…"
                    try await microphoneTranscription.finishAndDrain()
                }
            }
            catch { saveError = "Микрофон не расшифрован: \(error.localizedDescription). Фрагменты сохранены в Transcripts/.pending-microphone" }
            store.finishJournal()
            if let finishedRun {
                let summary = store.metrics.summary(session: finishedRun.session, mode: finishedRun.mode, model: finishedRun.model.title,
                    ultraChunkSeconds: finishedRun.model == .ultra ? finishedRun.ultraChunk : nil,
                    wordPacing: RecognitionTuning.wordPacing, transcript: transcript)
                do { try MetricsLog.append(summary, transcripts: transcriptsDirectory) }
                catch { saveError = "Статистика сеанса не сохранена: \(error.localizedDescription)" }
            }
            await recognition?.stop()
            audio = nil; worker = nil; recognition = nil; microphoneCapture = nil; microphoneTranscription = nil
            shutdown = nil; busy = false
            state = error == nil ? "Остановлено" : "Ошибка · откройте меню"
        }
    }

    /// A single word for the learning card. Uses the session's translator, so it works only while running.
    /// The word goes where its phrase would go (see `TranslationLanguage.target`); a glossary term answers at once.
    func translateWord(_ word: String, context: String) async throws -> String {
        let target = TranslationLanguage.stored().target(for: context)
        let glossary = Glossary.load(transcripts: transcriptsDirectory)
        if let language = target.glossaryLanguage, let known = glossary.word(word, target: language) { return known }
        guard let worker else { throw CaptionsError.message("Переводчик не запущен") }
        let terms = target.glossaryLanguage.map { glossary.pairs(in: context, target: $0) } ?? []
        return try await worker.translateWord(word, context: context, into: target, terms: terms)
    }

    func stopAndWait() async {
        stop()
        await shutdown?.value
    }
}
