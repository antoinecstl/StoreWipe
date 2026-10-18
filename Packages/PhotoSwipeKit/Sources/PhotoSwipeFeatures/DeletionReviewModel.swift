import Foundation
import Observation
import PhotoSwipeCore
import PhotoSwipeStore

/// Revue puis suppression de la sélection « à supprimer ».
///
/// La suppression passe toujours par le système (alerte de confirmation d'iOS) : ce modèle
/// ne fait que la demander. Seules les photos réellement absentes de la photothèque après
/// l'opération sont retirées de l'index local.
@MainActor
@Observable
public final class DeletionReviewModel {
    public enum Outcome: Sendable, Equatable {
        /// Photos supprimées, et photos que le système n'a pas pu supprimer.
        case deleted(count: Int, failed: Int)
        /// L'utilisateur a refusé dans l'alerte système : rien n'a changé.
        case cancelled
        case failed
    }

    public private(set) var items: [AssetSummary] = []
    /// Photos retirées de la sélection pendant cette revue (elles sont alors conservées).
    public private(set) var excluded: Set<AssetID> = []
    public private(set) var isDeleting = false
    public private(set) var outcome: Outcome?
    public private(set) var hasLoaded = false

    private let store: PhotoSwipeStore
    private let library: any PhotoLibraryService
    private let deleter: any AssetDeleting
    private let now: @Sendable () -> Date

    public init(
        store: PhotoSwipeStore,
        library: any PhotoLibraryService,
        deleter: any AssetDeleting,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.library = library
        self.deleter = deleter
        self.now = now
    }

    /// Photos qui seront supprimées si l'utilisateur confirme.
    public var selectedCount: Int { items.count - excluded.count }

    public func isSelected(_ id: AssetID) -> Bool { !excluded.contains(id) }

    public func load() async {
        items = (try? await store.markedForDeletion()) ?? []
        excluded = []
        hasLoaded = true
    }

    /// Retire une photo de la sélection (elle est conservée) ou l'y remet. Enregistré immédiatement.
    public func toggle(_ id: AssetID) async {
        guard !isDeleting, items.contains(where: { $0.id == id }) else { return }
        let isExcluded = excluded.contains(id)
        let decision: Decision = isExcluded ? .markedForDeletion : .kept
        guard (try? await store.applyDecision(decision, to: id, sessionID: nil, at: now())) != nil else { return }
        if isExcluded {
            excluded.remove(id)
        } else {
            excluded.insert(id)
        }
        outcome = nil
    }

    /// Demande la suppression des photos sélectionnées au système.
    public func confirmDeletion() async {
        guard !isDeleting else { return }
        let ids = items.map(\.id).filter { !excluded.contains($0) }
        guard !ids.isEmpty else { return }
        isDeleting = true
        outcome = nil
        defer { isDeleting = false }

        let confirmed: Bool
        do {
            confirmed = try await deleter.deleteAssets(ids)
        } catch {
            outcome = .failed
            return
        }
        guard confirmed else {
            outcome = .cancelled
            return
        }
        // Résultat réel : seules les photos effectivement absentes sont comptées et purgées.
        let remaining = await library.existingAssetIDs(among: ids)
        let deleted = ids.filter { !remaining.contains($0) }
        try? await store.purge(deleted)
        items = (try? await store.markedForDeletion()) ?? []
        excluded = []
        outcome = .deleted(count: deleted.count, failed: ids.count - deleted.count)
    }

    public func dismissOutcome() {
        outcome = nil
    }
}
