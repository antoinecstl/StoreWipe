import Foundation
import Observation
import PhotoSwipeCore
import PhotoSwipeStore

/// Analyse locale des photos, par petits lots, avec pause et reprise.
///
/// Les résultats (étiquettes et mesures) sont enregistrés au fur et à mesure : une interruption
/// ne perd rien, et une photo déjà analysée n'est refaite que si elle a été modifiée.
/// Aucune photo n'est modifiée ni supprimée par ce modèle, et rien ne passe par le réseau.
@MainActor
@Observable
public final class AnalysisCoordinator {
    public enum Phase: Sendable, Equatable {
        case idle
        case running
        /// Suspendue (appareil dans un état critique) : reprend d'elle-même.
        case paused
        case finished
    }

    public private(set) var phase: Phase = .idle
    public private(set) var progress = AnalysisProgress()
    /// Incrémenté à chaque lot enregistré (rafraîchit les compteurs de catégories).
    public private(set) var revision = 0
    /// Photos ignorées pendant cette passe (image absente de l'appareil ou illisible).
    public private(set) var skippedCount = 0
    /// Vrai quand l'analyse tourne à cadence réduite (iPhone chaud, économie d'énergie) au lieu de s'arrêter.
    public private(set) var isThrottled = false

    public static let batchSize = 12

    private let store: PhotoSwipeStore
    private let analyzer: any ImageAnalyzing
    private let pacing: @MainActor () -> WorkPacing
    private let pauseInterval: Duration
    private let now: @Sendable () -> Date
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var runID = 0

    public init(
        store: PhotoSwipeStore,
        analyzer: any ImageAnalyzing,
        pacing: @escaping @MainActor () -> WorkPacing = { .full },
        pauseInterval: Duration = .seconds(5),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.analyzer = analyzer
        self.pacing = pacing
        self.pauseInterval = pauseInterval
        self.now = now
    }

    public var isActive: Bool { task != nil }

    /// Démarre (ou relance) l'analyse des photos pas encore analysées. Sans effet si déjà en cours.
    public func start() {
        guard task == nil else { return }
        runID += 1
        let id = runID
        phase = .running
        // Priorité basse : cœurs économes, moins de chaleur, l'interface reste fluide.
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

    /// Attend la fin de la passe en cours (tests).
    public func waitUntilIdle() async {
        while let task {
            await task.value
        }
    }

    public func refreshProgress() async {
        if let latest = try? await store.analysisProgress() {
            progress = latest
        }
    }

    private func finishRun(_ id: Int) {
        if runID == id { task = nil }
    }

    private func run() async {
        var skipped: [AssetID] = []
        skippedCount = 0
        await refreshProgress()
        while !Task.isCancelled {
            if case .paused = pacing() {
                isThrottled = false
                phase = .paused
                try? await Task.sleep(for: pauseInterval)
                continue
            }
            phase = .running
            guard let batch = try? await store.assetsToAnalyze(limit: Self.batchSize, excluding: skipped) else {
                phase = .idle
                return
            }
            if batch.isEmpty { break }
            for asset in batch {
                if Task.isCancelled { return }
                switch pacing() {
                case .paused:
                    isThrottled = false
                case .throttled(let delay):
                    // Espacer les photos laisse l'appareil refroidir sans interrompre le travail.
                    isThrottled = true
                    try? await Task.sleep(for: delay)
                case .full:
                    isThrottled = false
                }
                if case .paused = pacing() { break }
                do {
                    if let analysis = try await analyzer.analyze(asset.id) {
                        try await store.saveAnalysis(analysis, for: asset, at: now())
                        progress.analyzed = min(progress.total, progress.analyzed + 1)
                    } else {
                        skipped.append(asset.id)
                        skippedCount += 1
                    }
                } catch is CancellationError {
                    return
                } catch {
                    skipped.append(asset.id)
                    skippedCount += 1
                }
            }
            await refreshProgress()
            revision += 1
        }
        guard !Task.isCancelled else { return }
        await refreshProgress()
        revision += 1
        isThrottled = false
        phase = .finished
    }
}
