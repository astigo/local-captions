import SwiftUI
import AppKit

/// The main window and menu bar popover: start or stop, and three switches that also work mid-session.
struct ControlPopover: View {
    @ObservedObject var engine: CaptionEngine
    @ObservedObject var store: CaptionStore
    var openHistory: () -> Void
    var openSettings: () -> Void
    var quit: () -> Void
    private var locked: Bool { engine.active || engine.busy }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(engine.active ? Color.red : Color.secondary).frame(width: 8, height: 8)
                Text(engine.state).font(.system(size: 13)).lineLimit(2)
                if engine.busy { ProgressView().controlSize(.small) }
            }
            Button { locked ? engine.stop() : engine.start() } label: {
                Text(locked ? "Остановить" : "Запустить").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            HStack(spacing: 8) {
                SwitchTile(title: "Субтитры", symbol: "captions.bubble", on: engine.subtitlesVisible) {
                    engine.setSubtitlesVisible(!engine.subtitlesVisible)
                }
                SwitchTile(title: "Перевод", symbol: "character.book.closed", on: engine.translationEnabled) {
                    engine.setTranslationEnabled(!engine.translationEnabled)
                }
                SwitchTile(title: "Микрофон", symbol: engine.microphoneEnabled ? "mic.fill" : "mic.slash", on: engine.microphoneEnabled) {
                    engine.setMicrophoneEnabled(!engine.microphoneEnabled)
                }
                .disabled(engine.busy)
            }
            TextField("Название встречи (необязательно)", text: $engine.meetingTitle)
                .textFieldStyle(.roundedBorder).disabled(locked)
            if let error = engine.error {
                ScrollView { Text(error).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 90)
            }
            if let message = engine.saveError {
                Text(message).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
            }
            Divider()
            HStack {
                Button("История", action: openHistory).disabled(store.history.isEmpty)
                Spacer()
                Button("Настройки…", action: openSettings)
                Button("Выйти", action: quit)
            }
            .buttonStyle(.link)
        }
        .padding(16)
        .frame(width: 340)
    }
}

/// A square on/off switch with an icon; the state is in its fill, not only its label.
private struct SwitchTile: View {
    let title: String
    let symbol: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 17)).frame(height: 20)
                Text(title).font(.system(size: 11))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .foregroundStyle(on ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.accentColor : Color.secondary.opacity(0.12)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(on ? "включено" : "выключено")
        .help(on ? "\(title): включено" : "\(title): выключено")
    }
}

struct SettingsView: View {
    @ObservedObject var engine: CaptionEngine
    @ObservedObject var settings: OverlaySettings
    var demo: () -> Void
    var openTranscripts: () -> Void
    @State private var sessions: [SessionMetricsSummary] = []
    @State private var chunk = RecognitionTuning.ultraChunkSeconds(for: .learning)
    @State private var detectTabs = BrowserTabs.enabled
    @AppStorage(TranslationLanguage.defaultsKey) private var translationLanguage = TranslationLanguage.russian.code
    @State private var tabsTrusted = BrowserTabs.trusted
    @State private var reportMessage: String?
    private var locked: Bool { engine.active || engine.busy }

    var body: some View {
        TabView {
            appearance.tabItem { Text("Внешний вид") }
            recognition.tabItem { Text("Распознавание") }
            files.tabItem { Text("Источники и файлы") }
            statistics.padding(16).tabItem { Text("Статистика") }
        }
        .frame(width: 680, height: 560)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            tabsTrusted = BrowserTabs.trusted
        }
    }

    private var appearance: some View {
        Form {
            Picker("Расположение", selection: $settings.placement) {
                ForEach(OverlayPlacement.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            Picker("Строк оригинала", selection: $settings.lines) {
                ForEach(Array(OverlaySettings.lineRange), id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.segmented).disabled(settings.placement == .right)
            if settings.placement == .right {
                Text("Колонка занимает высоту экрана: сейчас \(settings.effectiveLines) строк.").font(.caption).foregroundStyle(.secondary)
            }
            slider("Шрифт", value: $settings.fontSize, range: 16...44, step: 1, label: "\(Int(settings.fontSize)) pt")
            slider("Ширина", value: $settings.width, range: OverlaySettings.widthRange, step: 10, label: "\(Int(settings.width)) pt")
            slider("Подложка", value: $settings.opacity, range: 0.4...0.95, step: 0.01, label: "\(Int(settings.opacity * 100))%")
            slider("Межстрочный интервал", value: $settings.lineSpacing, range: 1.2...1.7, step: 0.02,
                   label: String(format: "%.2f", settings.lineSpacing))
            Toggle("Показывать слова по одному", isOn: $settings.wordPacing)
            Text("Слова из одного обновления распознавания появляются по очереди, а не пачкой.").font(.caption).foregroundStyle(.secondary)
            Toggle("Шторка при наведении в обучении", isOn: $settings.hoverPause)
            Text("Плашку можно перетащить; ширину меняют её края. Высота считается из шрифта и числа строк.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Проверить окно субтитров", action: demo).disabled(locked)
        }
        .formStyle(.grouped)
    }

    private var recognition: some View {
        Form {
            Picker("Режим", selection: Binding(get: { engine.selectedMode }, set: { engine.selectMode($0) })) {
                Text("Обучение").tag(CaptionMode.learning)
                Text("Перевод отдельной дорожкой").tag(CaptionMode.translation)
            }
            .pickerStyle(.segmented).disabled(locked)
            Text(engine.selectedMode.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Модель", selection: $engine.selectedModel) {
                ForEach(RecognitionModel.allCases) { model in
                    Text(model.title).tag(model)
                }
            }
            .disabled(locked)
            Text(engine.selectedModel.detail)
                .font(.caption).foregroundStyle(.secondary)
            // One window, for the selected mode: learning hears Russian and needs a longer one.
            Picker("Окно Ultra", selection: $chunk) {
                ForEach(RecognitionTuning.ultraChunkChoices, id: \.self) { Text(String(format: "%.2f с", $0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: chunk) { _, value in RecognitionTuning.setUltraChunkSeconds(value, for: engine.selectedMode) }
            .onChange(of: engine.selectedMode) { _, mode in chunk = RecognitionTuning.ultraChunkSeconds(for: mode) }
            .onAppear { chunk = RecognitionTuning.ultraChunkSeconds(for: engine.selectedMode) }
            Text(engine.selectedMode == .translation
                 ? "Меньше окно — слова появляются раньше, но ошибок больше. Для английского хватает 0,64 с."
                 : "Меньше окно — слова появляются раньше, но ошибок больше. Русской речи нужно 0,96 с: при 0,64 ошибок вдвое больше.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if engine.selectedMode.translates {
                Picker("Переводчик", selection: $engine.selectedTranslator) {
                    ForEach(TranslationModel.allCases) { Text($0.title).tag($0) }
                }.disabled(locked)
                // Read at every translation, so it works during a session too.
                Picker("Переводить на", selection: $translationLanguage) {
                    ForEach(TranslationLanguage.all) { Text($0.title).tag($0.code) }
                }
                Text(translationLanguage == TranslationLanguage.english.code
                     ? "Фразы на английском переводятся на русский. Меняется сразу, и во время записи тоже."
                     : "Фразы на этом языке переводятся на английский. Меняется сразу, и во время записи тоже.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent("Термины") {
                Button("Открыть glossary.txt") {
                    _ = Glossary.load(transcripts: engine.transcriptsDirectory)
                    NSWorkspace.shared.open(Glossary.url(in: engine.transcriptsDirectory))
                }
            }
            Text("Строки «витрина = data mart»: переводчик будет использовать ваши термины в обе стороны. Работают при переводе на русский и английский.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Режим, модель и переводчик меняются при следующем запуске.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var files: some View {
        Form {
            Toggle("Микрофон · отдельный канал «Я»", isOn: Binding(get: { engine.microphoneEnabled }, set: { engine.setMicrophoneEnabled($0) }))
                .disabled(engine.busy)
            Text("Пишется только в файл встречи, на экран не выводится. Расшифровывается после 3 минут тишины в системном звуке, при выключении и при остановке. Использует Ultra. Переключается и во время сеанса из главного окна.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if engine.microphoneEnabled, !engine.microphoneState.isEmpty {
                Text(engine.microphoneState).font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Определять звучащую вкладку браузера", isOn: $detectTabs)
                .onChange(of: detectTabs) { _, value in
                    BrowserTabs.enabled = value
                    if value, !BrowserTabs.trusted { BrowserTabs.requestAccess() }
                }
            Text("Название вкладки, из которой идёт звук, попадёт в историю и файлы встречи. Нужен «Универсальный доступ»; разрешение записи экрана не требуется.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if detectTabs {
                LabeledContent("Универсальный доступ") {
                    if tabsTrusted { Text("разрешён").foregroundStyle(.secondary) }
                    else {
                        Button("Открыть настройки macOS…") {
                            BrowserTabs.requestAccess()
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
                LabeledContent("Если вкладка не находится") {
                    Button("Сохранить отчёт о вкладках") {
                        let url = engine.transcriptsDirectory.appendingPathComponent("browser-tabs-report.txt")
                        do {
                            try FileManager.default.createDirectory(at: engine.transcriptsDirectory, withIntermediateDirectories: true)
                            try BrowserTabs.diagnostic().write(to: url, atomically: true, encoding: .utf8)
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                            reportMessage = nil
                        } catch { reportMessage = "Отчёт не сохранён: \(error.localizedDescription)" }
                    }
                    .disabled(!tabsTrusted)
                }
                if let reportMessage { Text(reportMessage).font(.caption).foregroundStyle(.red) }
            }
            LabeledContent("Транскрипции") { Button("Открыть папку", action: openTranscripts) }
            LabeledContent("Системный звук") {
                Button("Доступ в настройках macOS…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
            Text("Достаточно разрешения «Только запись системного звука». Звук не сохраняется; текст пишется в Markdown и JSONL.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
    }

    private var statistics: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Задержка — от конца слова в звуке до появления его окончательного написания на экране. Правки — доля показанных слов, которые потом изменились.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if sessions.isEmpty {
                Text("Статистика появится после первой остановки сеанса.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(sessions) {
                    TableColumn("Начало") { Text($0.startedAt.formatted(date: .abbreviated, time: .shortened)) }
                        .width(min: 110, ideal: 120)
                    TableColumn("Режим") { Text(Self.setup($0)) }.width(min: 110, ideal: 130)
                    TableColumn("Слов") { Text("\($0.finalWords)").monospacedDigit() }.width(44)
                    TableColumn("Задержка p50 / p95") { row in
                        Text(row.displayLatency.map { String(format: "%.2f / %.2f с", $0.p50, $0.p95) } ?? "—").monospacedDigit()
                    }.width(min: 110, ideal: 120)
                    TableColumn("Правки") { Text(String(format: "%.1f%%", $0.revisionRate * 100)).monospacedDigit() }.width(56)
                    TableColumn("Обучение") { row in
                        Text(row.learning.map { "\($0.phrasesTranslated)/\($0.phrases) фраз · \($0.wordLookups) сл." } ?? "")
                    }
                }
            }
            HStack {
                Button("Обновить") { sessions = MetricsLog.load(transcripts: engine.transcriptsDirectory) }
                Spacer()
                Button("Открыть metrics.jsonl") { NSWorkspace.shared.open(MetricsLog.url(in: engine.transcriptsDirectory)) }
                    .disabled(sessions.isEmpty)
            }
        }
        .onAppear { sessions = MetricsLog.load(transcripts: engine.transcriptsDirectory) }
    }

    static func setup(_ row: SessionMetricsSummary) -> String {
        let mode = CaptionMode(rawValue: row.mode)?.shortTitle ?? row.mode
        let model = row.model.contains("Ultra") ? "Ultra" + (row.ultraChunkSeconds.map { String(format: " %.2f", $0) } ?? "") : row.model
        return "\(mode) · \(model)" + (row.wordPacing ? "" : " · пачкой")
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, label: String) -> some View {
        LabeledContent(title) {
            HStack {
                // Rounded through the binding: a `step` would draw a tick for every value.
                Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = ($0 / step).rounded() * step }),
                       in: range).labelsHidden().accessibilityLabel(title)
                Text(label).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
            }
        }
    }
}
