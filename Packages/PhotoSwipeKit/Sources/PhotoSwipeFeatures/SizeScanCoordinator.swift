import Foundation
import Observation
import PhotoSwipeCore
import PhotoSwipeStore

/// Mesure en arrière-plan la taille des fichiers de la photothèque (métadonnées uniquement,
/// aucune image décodée, aucun téléchargement). Les résultats servent aux gros fichiers,
/// aux doublons probables et au volume affiché avant une suppression.
@MainActor
@Observable
public final class SizeScanCoordinator {
    public enum Phase: Sendable, Equatable {
        case idle
        case running
        case finished
    }

    public private(set) var phase: Phase = .idle
    public private(set) var coverage = SizeCoverage()
    /// Incrémenté à chaque lot enregistré.
    public private(set) var revision = 0

    public static let batchSize = 200

    private let store: PhotoSwipeStore
    private let sizer: any AssetSizing
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var runID = 0

    public init(store: PhotoSwipeStore, sizer: any AssetSizing) {
        self.store = store
        self.sizer = sizer
    }

    public var isActive: Bool { task != nil }

    /// Démarre (ou relance) la mesure des éléments pas encore mesurés. Sans effet si déjà en cours.
    public func start() {
        guard task == nil else { return }
        runID += 1
        let id = runID
        phase = .running
        task = Task { [weak self] in
            await self?.run()
            self?.finishRun(id)
        }
    }

    public func stop() {
        runID += 1
        task?.cancel()
        task = nil
        if phase != .finished { phase = .idle }
    }

    public func waitUntilIdle() async {
        while let task {
            await task.value
        }
    }

    public func refreshCoverage() async {
        if let latest = try? await store.sizeCoverage() {
            coverage = latest
        }
    }

    private func finishRun(_ id: Int) {
        if runID == id { task = nil }
    }

    private func run() async {
        var unresolved: [AssetID] = []
        await refreshCoverage()
        while !Task.isCancelled {
            guard let ids = try? await store.assetsWithoutSize(limit: Self.batchSize, excluding: unresolved) else {
                phase = .idle
                return
            }
            if ids.isEmpty { break }
            let sizes = await sizer.byteSizes(for: ids)
            if Task.isCancelled { return }
            try? await store.saveSizes(sizes)
            // Une taille introuvable ne doit pas être redemandée en boucle pendant cette passe.
            unresolved += ids.filter { sizes[$0] == nil }
            await refreshCoverage()
            revision += 1
        }
        guard !Task.isCancelled else { return }
        await refreshCoverage()
        revision += 1
        phase = .finished
    }
}
