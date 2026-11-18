import Foundation

enum TranslationModel: String, CaseIterable, Identifiable {
    // Translators to choose from; each case must exist in backend/worker.py TRANSLATORS.
    case hymt
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hymt: return "HY-MT2 · 1.8B Q4"
        }
    }
}
