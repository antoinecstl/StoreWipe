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

    public private(set) var counts: DecisionCounts = .zero
    public private(set) var months: [MonthSummary] = []
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
