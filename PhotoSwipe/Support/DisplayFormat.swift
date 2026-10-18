import Foundation
import PhotoSwipeCore

/// Textes dérivés des données (dates, titres de périmètre, raisons de présence).
enum DisplayFormat {
    static func monthTitle(_ month: MonthKey?, calendar: Calendar = .current) -> String {
        guard let month,
              let date = calendar.date(from: DateComponents(year: month.year, month: month.month, day: 1))
        else {
            return String(localized: "Sans date")
        }
        let text = date.formatted(.dateTime.month(.wide).year())
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Taille lisible (« 85 Mo »), jamais présentée comme de l'espace garanti libéré.
    static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Durée d'une vidéo (« 1:05 » ou « 1:02:03 »).
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    static func photoDate(_ date: Date?) -> String {
        guard let date else { return String(localized: "Date inconnue") }
        return date.formatted(date: .long, time: .shortened)
    }

    static func shortDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    static func scopeTitle(_ scope: SessionScope, categories: [PhotoCategory] = []) -> String {
        let base: String
        switch scope.filter {
        case .all:
            switch scope.pool {
            case .standard: return String(localized: "Tri")
            case .deferredOnly: return String(localized: "Photos passées")
            case .keptReview: return String(localized: "Photos conservées")
            }
        case .month(let month):
            base = monthTitle(month)
        case .undated:
            base = String(localized: "Sans date")
        case .screenshots:
            base = String(localized: "Captures d'écran")
        case .videos:
            base = String(localized: "Vidéos")
        case .category(let key):
            base = categories.first { $0.key == key }?.name ?? String(localized: "Catégorie")
        }
        switch scope.pool {
        case .standard: return base
        case .deferredOnly: return String(localized: "\(base) · passées")
        case .keptReview: return String(localized: "\(base) · conservées")
        }
    }

    /// Raison de présence de la photo dans la pile, si elle mérite d'être affichée.
    static func reason(for item: QueueItem) -> String? {
        switch item.reason {
        case .unreviewed:
            return nil
        case .previouslyDeferred(let since):
            guard let since else { return String(localized: "Passée précédemment") }
            return String(localized: "Passée le \(shortDate(since))")
        case .reviewingKept(let since):
            guard let since else { return String(localized: "Déjà conservée") }
            return String(localized: "Conservée le \(shortDate(since))")
        }
    }
}
