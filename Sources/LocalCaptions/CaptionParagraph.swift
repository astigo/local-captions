import Foundation

/// Readable history, without paraphrasing or inventing words. Each bilingual row
/// is built from the same original caption IDs, so translations stay aligned.
struct CaptionParagraph: Identifiable {
    let id: UUID
    var captions: [Caption]
    var original: String { captions.map(\.english).joined(separator: " ") }
    var translation: String { captions.map { $0.russian ?? ($0.translationError == nil ? "…" : "[Перевод недоступен]") }.joined(separator: " ") }
    var startedAt: Date { captions[0].audioStartAt ?? captions[0].firstSeenAt }
    var sources: [AudioSource] { captions[0].sources }

    static func make(_ captions: [Caption], startsParagraph: ((Caption, Caption) -> Bool)? = nil) -> [CaptionParagraph] {
        var result: [CaptionParagraph] = []
        for caption in captions where caption.channel != "microphone" {
            if let last = result.last, let previous = last.captions.last,
               previous.finalized, caption.finalized,
               caption.firstSeenAt.timeIntervalSince(previous.firstSeenAt) < 10,
               caption.firstSeenAt.timeIntervalSince(last.startedAt) < 35,
               previous.sources == caption.sources,
               startsParagraph?(caption, previous) != true,
               last.original.split(whereSeparator: \.isWhitespace).count < 65 {
                result[result.count - 1].captions.append(caption)
            } else {
                result.append(CaptionParagraph(id: caption.id, captions: [caption]))
            }
        }
        return result
    }
}
