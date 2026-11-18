import SwiftUI

/// Session history in an ordinary window: searchable, selectable, never on top of the video.
struct HistoryView: View {
    @ObservedObject var store: CaptionStore
    @ObservedObject var vocabulary: Vocabulary
    @State private var query = ""
    @State private var tab = 0
    @State private var unveiled: Set<UUID> = []

    private var paragraphs: [CaptionParagraph] {
        let all = CaptionParagraph.make(store.history.filter { $0.channel != "microphone" }, startsParagraph: store.startsParagraph)
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter { $0.original.lowercased().contains(needle) || $0.translation.lowercased().contains(needle) }
    }
    private var bilingual: Bool { store.mode != .transcription }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $tab) {
                    Text("Сеанс").tag(0)
                    Text("Словарь · \(vocabulary.entries.count)").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                if tab == 0 {
                    TextField(bilingual ? "Поиск по EN и RU" : "Поиск", text: $query)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                }
            }
            .padding(12)
            Divider()
            if tab == 0 { session } else { words }
        }
        .frame(minWidth: 520, minHeight: 320)
    }

    private var session: some View {
        Group {
            if paragraphs.isEmpty {
                Text(query.isEmpty ? "Здесь появятся завершённые фразы сеанса." : "Ничего не найдено по «\(query)».")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(paragraphs) { paragraph in
                        row(paragraph).id(paragraph.id)
                    }
                    .listStyle(.inset)
                    .onAppear { if let last = paragraphs.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
        }
    }

    private func row(_ paragraph: CaptionParagraph) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(paragraph.startedAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                if !paragraph.sources.isEmpty {
                    Text(paragraph.sources.map(\.label).joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Text(paragraph.original).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if bilingual {
                let hidden = store.mode == .learning && query.isEmpty && !unveiled.contains(paragraph.id)
                Text(paragraph.translation).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .blur(radius: hidden ? 5 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard hidden else { return }
                        unveiled.insert(paragraph.id)
                        store.metrics.phraseTranslationShown()
                    }
                    .help(hidden ? "Показать перевод" : "")
            }
        }
        .padding(.vertical, 4)
    }

    private var words: some View {
        Group {
            if vocabulary.entries.isEmpty {
                Text("В обучении нажмите на слово в субтитрах, затем «В словарь».")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(vocabulary.entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(entry.word).fontWeight(.semibold).frame(width: 140, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.translation.isEmpty ? "—" : entry.translation)
                            if !entry.context.isEmpty { Text(entry.context).font(.system(size: 12)).foregroundStyle(.secondary) }
                        }
                        .textSelection(.enabled)
                        Spacer()
                        Button { vocabulary.remove(entry) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Убрать из словаря")
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            }
        }
    }
}
