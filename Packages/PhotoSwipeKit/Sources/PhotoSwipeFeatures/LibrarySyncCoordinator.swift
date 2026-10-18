import Foundation
import Observation
import PhotoSwipeCore
import PhotoSwipeStore

/// Synchronise l'index local avec la photothèque : énumération complète par lots
/// (dans le sens du tri, pour que le tri puisse commencer tout de suite), puis
/// réconciliation prudente des photos disparues.
@MainActor
@Observable
public final class LibrarySyncCoordinator {
    public enum Phase: Sendable, Equatable {
        case idle
        case running
        case finished
        case failed
    }

    public private(set) var phase: Phase = .idle
    /// Photos traitées pendant la passe en cours.
    public private(set) var processedCount = 0
    public private(set) var lastCompletedAt: Date?
    public private(set) var lastPlan: ReconciliationPlan?
    /// Incrémenté à chaque modification de l'index (utile pour rafraîchir l'interface).
    public private(set) var revision = 0

    public static let batchSize = 400
    public static let changeDebounce: Duration = .milliseconds(800)

    private let library: any PhotoLibraryService
    private let store: PhotoSwipeStore
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let enumerationOrder: @MainActor () -> PresentationOrder
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var rerunRequested = false
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    public init(
        library: any PhotoLibraryService,
        store: PhotoSwipeStore,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() },
        enumerationOrder: @escaping @MainActor () -> PresentationOrder = { .newestFirst }
    ) {
        self.library = library
        self.store = store
        self.calendar = calendar
        self.now = now
        self.enumerationOrder = enumerationOrder
    }

    public var isRunning: Bool { syncTask != nil }

    /// Demande une synchronisation. Une demande pendant une passe en cours en relance une à la fin.
    public func requestSync() {
        guard syncTask == nil else {
            rerunRequested = true
            return
        }
        syncTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Écoute les changements de la photothèque (y compris la sélection en accès limité).
    public func startObservingChanges() {
        guard observationTask == nil else { return }
        let stream = library.changeNotifications()
        observationTask = Task { [weak self] in
            for await _ in stream {
                self?.scheduleDebouncedSync()
            }
        }
    }

    public func stop() {
        observationTask?.cancel()
        observationTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        syncTask?.cancel()
    }

    /// Attend la fin de la passe en cours et des relances éventuelles.
    public func waitUntilIdle() async {
        while let task = syncTask {
            await task.value
        }
    }

    private func scheduleDebouncedSync() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.changeDebounce)
            guard !Task.isCancelled else { return }
            self?.requestSync()
        }
    }

    private func runLoop() async {
        repeat {
            rerunRequested = false
            await performSync()
        } while rerunRequested && !Task.isCancelled
        syncTask = nil
    }

    private func performSync() async {
        let authorization = library.authorizationStatus()
        guard authorization.allowsReading else {
            phase = .idle
            return
        }
        phase = .running
        processedCount = 0
        do {
            let generation = try await store.beginSyncGeneration()
            // Le sens suit celui du tri : le tri peut commencer dès le premier lot, sans désordre ensuite.
            for try await batch in library.assetBatches(batchSize: Self.batchSize, order: enumerationOrder()) {
                try Task.checkCancellation()
                _ = try await store.upsertAssets(batch, generation: generation, calendar: calendar, at: now())
                processedCount += batch.count
                revision += 1
            }
            try Task.checkCancellation()

            // Une autorisation modifiée pendant l'énumération invalide la comparaison : on recommence.
            guard library.authorizationStatus() == authorization else {
                rerunRequested = true
                return
            }
            let notSeen = try await store.assetsNotSeen(since: generation)
            let confirmed: Set<AssetID> = authorization == .full && !notSeen.isEmpty
                ? await library.existingAssetIDs(among: notSeen)
                : []
            let plan = ReconciliationPlanner.plan(
                notSeen: notSeen,
                authorization: authorization,
                confirmedExisting: confirmed,
                totalIndexed: try await store.assetCount()
            )
            try await store.apply(plan, at: now())
            lastPlan = plan
            lastCompletedAt = now()
            phase = .finished
            revision += 1
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed
        }
    }
}
