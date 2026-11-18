import Foundation

enum CaptionsError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// One process per active session. Killing it cancels all in-flight requests on Stop.
actor LocalWorker {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var buffer = Data()
    private var ready: CheckedContinuation<Void, Error>?
    private var stderr = Data()

    func start(runtime: URL, script: URL, model: TranslationModel = .hymt) async throws {
        let process = Process()
        process.executableURL = runtime.appendingPathComponent("venv/bin/python")
        process.arguments = ["-u", script.path, "--models", runtime.appendingPathComponent("models").path, "--translator", model.rawValue]
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HUB_OFFLINE"] = "1"
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), errors = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = errors
        input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.receive(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.receiveError(data) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { await self?.failed("Локальный обработчик завершился. Повторите запуск.") }
        }
        self.process = process
        try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            do { try process.run() }
            catch { ready = nil; continuation.resume(throwing: error) }
        }
    }

    func call(_ values: [String: Any]) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard let input, process?.isRunning == true else { throw CaptionsError.message("Обработчик не запущен") }
        let id = UUID().uuidString
        var request = values; request["id"] = id
        var data = try JSONSerialization.data(withJSONObject: request); data.append(10)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try input.write(contentsOf: data) }
            catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
        }
    }

    func translate(_ text: String, into target: CaptionLanguage = .russian, terms: [[String]] = []) async throws -> String {
        let response = try await call(["op": "translate", "text": text, "target": target.rawValue, "terms": terms])
        guard let translated = response["text"] as? String, !translated.isEmpty else {
            throw CaptionsError.message("Переводчик вернул пустой результат")
        }
        return translated
    }

    /// One word as used in `context`; the phrase background used by `translate` is left alone.
    func translateWord(_ word: String, context: String, into target: CaptionLanguage = .russian, terms: [[String]] = []) async throws -> String {
        let response = try await call(["op": "word", "text": word, "context": context, "target": target.rawValue, "terms": terms])
        guard let translated = response["text"] as? String, !translated.isEmpty else {
            throw CaptionsError.message("Переводчик вернул пустой результат")
        }
        return translated
    }

    func stop() {
        process?.terminationHandler = nil
        if process?.isRunning == true {
            process?.terminate()
            process?.waitUntilExit()
        }
        try? input?.close(); output?.readabilityHandler = nil
        failed("Обработка остановлена")
        process = nil; input = nil; output = nil; buffer.removeAll()
    }

    private func receiveError(_ data: Data) {
        stderr.append(data)
        if stderr.count > 4096 { stderr = stderr.suffix(4096) }
    }

    private func failed(_ message: String) {
        let details = String(data: stderr, encoding: .utf8) ?? ""
        let error = CaptionsError.message(details.isEmpty ? message : "\(message)\n\(details)")
        ready?.resume(throwing: error); ready = nil
        let requests = pending.values; pending = [:]
        for request in requests { request.resume(throwing: error) }
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            guard let response = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if response["ready"] as? Bool == true { ready?.resume(); ready = nil; continue }
            guard let id = response["id"] as? String, let continuation = pending.removeValue(forKey: id) else { continue }
            if let error = response["error"] as? String { continuation.resume(throwing: CaptionsError.message(error)) }
            else { continuation.resume(returning: response) }
        }
    }
}
