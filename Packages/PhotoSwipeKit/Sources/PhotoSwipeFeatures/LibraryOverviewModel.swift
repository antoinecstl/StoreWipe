import Foundation
import Observation
import PhotoSwipeCore
import PhotoSwipeStore

/// Données de l'accueil et de l'écran « Trier par mois », toutes calculées à partir de
/// l'index local (aucune valeur estimée n'est affichée comme calculée).
@MainActor
@Observable
public final class LibraryOverviewModel {
    public struct ResumableSession: Sendable, Hashable {
        public let record: SortingSessionRecord
        public let remaining: Int
        public let stats: SessionStats
    }

    /// Une catégorie et ses effectifs d'après l'analyse locale.
    public struct CategorySummary: Sendable, Hashable, Identifiable {
        public let category: PhotoCategory
        /// Photos de la catégorie encore à trier (non examinées ou passées).
        public let toSort: Int
        /// Photos de la catégorie, quel que soit leur état.
        public let total: Int

        public var id: String { category.key }
    }

    public private(set) var counts: DecisionCounts = .zero
    public private(set) var months: [MonthSummary] = []
    /// Captures d'écran restant à trier (métadonnées système, sans analyse d'image).
    public private(set) var screenshotsToSort = 0
    /// Vidéos restant à trier.
    public private(set) var videosToSort = 0
    public private(set) var categories: [CategorySummary] = []
    public private(set) var analysisProgress = AnalysisProgress()
    public private(set) var resumable: ResumableSession?
    public private(set) var hasLoaded = false
    public private(set) var loadFailed = false

    private let store: PhotoSwipeStore

    public init(store: PhotoSwipeStore) {
        self.store = store
    }

    /// Photos restant à trier dans le parcours principal (non examinées + passées).
    public var remainingToSort: Int { counts.unreviewed + counts.deferred }

    public func refresh() async {
        do {
            counts = try await store.decisionCounts()
            screenshotsToSort = try await store.toSortCount(filter: .screenshots)
            videosToSort = try await store.toSortCount(filter: .videos)
            analysisProgress = try await store.analysisProgress()
            categories = try await loadCategories()
            resumable = try await loadResumable()
            hasLoaded = true
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    public func refreshMonths() async {
        do {
            months = try await store.monthSummaries()
        } catch {
            loadFailed = true
        }
    }

    private func loadCategories() async throws -> [CategorySummary] {
        var summaries: [CategorySummary] = []
        for category in try await store.allCategories() {
            summaries.append(
                CategorySummary(
                    category: category,
                    toSort: try await store.toSortCount(filter: .category(category.key)),
                    total: try await store.matchCount(rule: category.rule)
                )
            )
        }
        return summaries
    }

    /// Une session n'est proposée à la reprise que si elle a commencé et qu'il lui reste des photos.
    private func loadResumable() async throws -> ResumableSession? {
        guard let active = try await store.activeSession() else { return nil }
        let stats = try await store.sessionStats(active.id)
        guard stats.examined > 0 else { return nil }
        let remaining = try await store.remainingCount(for: active)
        guard remaining > 0 else { return nil }
        return ResumableSession(record: active, remaining: remaining, stats: stats)
    }
}
