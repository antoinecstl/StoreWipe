import Foundation
import Observation
import PhotoSwipeCore
import PhotoSwipeStore

/// Vérification des doublons exacts par empreinte SHA-256 (méthode `exact-sha256-v1`).
///
/// 1. Empreinte partielle (premiers octets) des éléments qui ont un sosie probable ;
/// 2. empreinte complète seulement pour ceux dont l'empreinte partielle est partagée.
///
/// Les lectures se font une à la fois, à cadence réduite si l'appareil chauffe. Rien n'est modifié ni
/// supprimé, aucun téléchargement iCloud sans autorisation, et seules les empreintes sont conservées.
@MainActor
@Observable
public final class DuplicateScanCoordinator {
    public enum Phase: Sendable, Equatable {
        case idle
        case running
        case paused
        case finished
    }

    public private(set) var phase: Phase = .idle
    public private(set) var isThrottled = false
    /// Fichiers traités pendant cette passe.
    public private(set) var processed = 0
    /// Fichiers qui n'ont pas pu être vérifiés (iCloud non autorisé, lecture impossible).
    public private(set) var unverifiable = 0
    /// Fichiers non comparables en V1 (modifiés, Live Photos, RAW+JPEG…).
    public private(set) var ineligible = 0
    /// Incrémenté à chaque lot enregistré.
    public private(set) var revision = 0

    public static let batchSize = 25

    private let store: PhotoSwipeStore
    private let hasher: any ResourceHashing
    private let pacing: @MainActor () -> WorkPacing
    private let allowsNetwork: @MainActor () -> Bool
    private let pauseInterval: Duration
    private let now: @Sendable () -> Date
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var runID = 0

    public init(
        store: PhotoSwipeStore,
        hasher: any ResourceHashing,
        pacing: @escaping @MainActor () -> WorkPacing = { .full },
        allowsNetwork: @escaping @MainActor () -> Bool = { false },
        pauseInterval: Duration = .seconds(5),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.hasher = hasher
        self.pacing = pacing
        self.allowsNetwork = allowsNetwork
        self.pauseInterval = pauseInterval
        self.now = now
    }

    public var isActive: Bool { task != nil }

    public func start() {
        guard task == nil else { return }
        runID += 1
        let id = runID
        phase = .running
        task = Task(priority: .utility) { [weak self] in
            await self?.run()
            self?.finishRun(id)
        }
    }

    public func stop() {
        runID += 1
        task?.cancel()
        task = nil
        isThrottled = false
        if phase != .finished { phase = .idle }
    }

    public func waitUntilIdle() async {
        while let task {
            await task.value
        }
    }

    private func finishRun(_ id: Int) {
        if runID == id { task = nil }
    }

    /// Applique la cadence demandée. Renvoie `false` si la tâche a été annulée pendant l'attente.
    private func pace() async -> Bool {
        while !Task.isCancelled {
            switch pacing() {
            case .full:
                isThrottled = false
                phase = .running
                return true
            case .throttled(let delay):
                isThrottled = true
                phase = .running
                try? await Task.sleep(for: delay)
                return !Task.isCancelled
            case .paused:
                isThrottled = false
                phase = .paused
                try? await Task.sleep(for: pauseInterval)
            }
        }
        return false
    }

    private func run() async {
        processed = 0
        unverifiable = 0
        ineligible = 0
        var unresolved: [AssetID] = []

        // Étape 1 : empreintes partielles.
        while !Task.isCancelled {
            guard let batch = try? await store.digestCandidates(stage: .partial, limit: Self.batchSize, excluding: unresolved),
                  !batch.isEmpty
            else { break }
            for asset in batch {
                guard await pace() else { return }
                let outcome = await hasher.partialDigest(for: asset.id, allowsNetwork: allowsNetwork())
                switch outcome {
                case .digest(let digest):
                    try? await store.savePartialDigest(for: asset.id, eligible: true, partial: digest, at: now())
                case .ineligible:
                    try? await store.savePartialDigest(for: asset.id, eligible: false, partial: nil, at: now())
                    ineligible += 1
                case .unavailable:
                    unresolved.append(asset.id)
                    unverifiable += 1
                }
                processed += 1
            }
            revision += 1
        }

        // Étape 2 : empreintes complètes, seulement pour les candidats restants.
        while !Task.isCancelled {
            guard let batch = try? await store.digestCandidates(stage: .full, limit: Self.batchSize, excluding: unresolved),
                  !batch.isEmpty
            else { break }
            for asset in batch {
                guard await pace() else { return }
                let outcome = await hasher.fullDigest(
                    for: asset.id,
                    expectedBytes: asset.byteSize ?? 0,
                    allowsNetwork: allowsNetwork()
                )
                if case .digest(let digest) = outcome {
                    try? await store.saveFullDigest(for: asset.id, full: digest, at: now())
                } else {
                    unresolved.append(asset.id)
                    unverifiable += 1
                }
                processed += 1
            }
            revision += 1
        }

        guard !Task.isCancelled else { return }
        revision += 1
        isThrottled = false
        phase = .finished
    }
}
