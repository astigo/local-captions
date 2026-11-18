import Foundation

/// Append-only events survive an interrupted meeting; Markdown is a readable, atomic snapshot.
final class TranscriptJournal: @unchecked Sendable {
    struct Session: Codable {
        let id: UUID
        let title: String
        let startedAt: Date
        var endedAt: Date?
        var recognitionModel: String?
        var mode: String?
        var translationModel: String?
        var microphone: Bool?
        var sourceAttribution = "active_output_candidates"
        var timestampMeaning = "first_seen_text_not_exact_audio_time"
    }
    struct Event: Codable {
        var schemaVersion = 3
        let type: String
        let timestamp: Date
        let session: Session?
        let caption: Caption?
    }
    let markdownURL: URL
    let eventsURL: URL
    private var metadata: Session
    private let queue = DispatchQueue(label: "LocalCaptions.transcripts", qos: .utility)
    private let handle: FileHandle
    private let onError: @Sendable (String) -> Void
    private var failed = false
    private var closed = false

    init(directory: URL, sessionID: UUID, title: String, model: String? = nil, mode: CaptionMode = .translation,
         translator: String? = nil, microphone: Bool = false,
         startedAt: Date = Date(), onError: @escaping @Sendable (String) -> Void) throws {
        self.onError = onError
        metadata = Session(id: sessionID, title: title.trimmingCharacters(in: .whitespacesAndNewlines), startedAt: startedAt)
        metadata.recognitionModel = model
        metadata.mode = mode.rawValue
        metadata.translationModel = translator; metadata.microphone = microphone
        if microphone { metadata.timestampMeaning = "system_first_seen_microphone_audio_time" }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let safeTitle = metadata.title.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? String($0) : "_" }.joined()
        let label = safeTitle.isEmpty ? "session" : String(safeTitle.prefix(70))
        let basename = "\(date.string(from: startedAt))_\(label)_\(sessionID.uuidString.prefix(8))"
        markdownURL = directory.appendingPathComponent(basename + ".md")
        eventsURL = directory.appendingPathComponent(basename + ".jsonl")
        guard FileManager.default.createFile(atPath: eventsURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CaptionsError.message("Не удалось создать файл транскрипции: \(directory.path)")
        }
        handle = try FileHandle(forWritingTo: eventsURL)
        try append(Event(type: "session_start", timestamp: startedAt, session: metadata, caption: nil))
        try saveMarkdown([])
    }

    func write(type: String, caption: Caption, snapshot: [Caption]) {
        let event = Event(type: type, timestamp: Date(), session: nil, caption: caption)
        queue.async { [self] in
            guard !closed else { return }
            perform { try append(event); try saveMarkdown(snapshot) }
        }
    }

    /// Audio is deleted only after its text has been durably written.
    func writeVerified(type: String, caption: Caption, snapshot: [Caption]) throws {
        try queue.sync {
            guard !closed else { throw CaptionsError.message("Журнал встречи уже закрыт") }
            try append(Event(type: type, timestamp: Date(), session: nil, caption: caption))
            try saveMarkdown(snapshot)
            try handle.synchronize()
        }
    }

    func finish(snapshot: [Caption], now: Date = Date()) {
        // Drain the small write queue before quitting; no audio/model work is on this queue.
        queue.sync {
            guard !closed else { return }
            metadata.endedAt = now
            perform {
                try append(Event(type: "session_end", timestamp: now, session: metadata, caption: nil))
                try saveMarkdown(snapshot)
                try handle.synchronize()
            }
            try? handle.close(); closed = true
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation() }
        catch {
            if !failed { failed = true; onError("Не удалось сохранить транскрипцию: \(error.localizedDescription)") }
        }
    }
    private func append(_ event: Event) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(event); line.append(10)
        try handle.write(contentsOf: line)
    }
    private func saveMarkdown(_ captions: [Caption]) throws {
        let date = ISO8601DateFormatter()
        let title = metadata.title.isEmpty ? "Сеанс Local Captions" : Self.inline(metadata.title)
        var text = "# \(title)\n\nНачало: \(date.string(from: metadata.startedAt))\n"
        if let model = metadata.recognitionModel { text += "Распознаватель: \(Self.inline(model))\n" }
        if let translator = metadata.translationModel { text += "Переводчик: \(Self.inline(translator))\n" }
        if metadata.microphone == true { text += "Микрофон: отдельный канал «Я», отложенная расшифровка.\n" }
        if let ended = metadata.endedAt { text += "Завершение: \(date.string(from: ended))\n" }
        let transcription = metadata.mode == CaptionMode.transcription.rawValue
        let modeTitle = transcription ? "EN+RU transcription — исходная речь без перевода"
            : (metadata.mode == CaptionMode.learning.rawValue ? "Обучение — EN и RU, перевод на другой язык по клику" : "Перевод отдельной дорожкой")
        text += "\nРежим: \(modeTitle). Захват включается и выключается пользователем.\nВременные метки системных реплик относятся к появлению текста, микрофонных — к захвату звука. Источники — кандидаты по активному аудиовыходу; при смешанном звуке точное соответствие реплике неизвестно. Названия окон могут отличаться от названия встречи.\n\n"
        for caption in captions.sorted(by: { ($0.audioStartAt ?? $0.firstSeenAt) < ($1.audioStartAt ?? $1.firstSeenAt) }) {
            let offset = max(0, Int((caption.audioStartAt ?? caption.firstSeenAt).timeIntervalSince(metadata.startedAt)))
            text += String(format: "## %02d:%02d:%02d", offset / 3600, (offset / 60) % 60, offset % 60) + "\n\n"
            if !caption.sources.isEmpty {
                text += "Возможные источники: " + caption.sources.map { Self.inline($0.label) }.joined(separator: " | ") + "\n\n"
            }
            // Speech is heard as is in every mode; each phrase is labelled by its own script.
            let original = transcription ? "Текст" : CaptionLanguage.detect(caption.english).label
            text += "**\(caption.channel == "microphone" ? "Я · микрофон" : original):** \(Self.inline(caption.english))\n\n"
            if transcription || caption.channel == "microphone" {
                if !caption.finalized { text += "_Незавершённый фрагмент._\n\n" }
                continue
            }
            if let russian = caption.russian { text += "**\((caption.translationLanguage ?? "ru").uppercased()):** \(Self.inline(russian))\n\n" }
            else if caption.translationError != nil { text += "_Перевод не выполнен._\n\n" }
            else { text += caption.finalized ? "_Перевод не завершён._\n\n" : "_Незавершённый фрагмент._\n\n" }
        }
        try text.write(to: markdownURL, atomically: true, encoding: .utf8)
    }
    private static func inline(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "_", with: "\\_").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
