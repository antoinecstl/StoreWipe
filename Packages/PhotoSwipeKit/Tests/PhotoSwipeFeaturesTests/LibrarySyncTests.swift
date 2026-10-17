import Foundation
import Testing
import PhotoSwipeCore
import PhotoSwipeStore
@testable import PhotoSwipeFeatures

/// Bibliothèque dont l'autorisation change pendant l'énumération (réglage modifié en cours de route).
final class AuthorizationFlippingLibrary: PhotoLibraryService {
    let base: InMemoryPhotoLibrary
    let after: LibraryAuthorization

    init(base: InMemoryPhotoLibrary, after: LibraryAuthorization) {
        self.base = base
        self.after = after
    }

    func authorizationStatus() -> LibraryAuthorization { base.authorizationStatus() }
    func requestAuthorization() async -> LibraryAuthorization { await base.requestAuthorization() }
    func existingAssetIDs(among ids: [AssetID]) async -> Set<AssetID> { await base.existingAssetIDs(among: ids) }
    func changeNotifications() -> AsyncStream<Void> { base.changeNotifications() }

    func assetBatches(batchSize: Int) -> AsyncThrowingStream<[AssetSummary], any Error> {
        let stream = base.assetBatches(batchSize: batchSize)
        base.setAuthorization(after, notify: false)
        return stream
    }
}

func photos(_ count: Int) -> [AssetSummary] { library(count) }

@MainActor
@Suite("Synchronisation de la photothèque")
struct LibrarySyncTests {
    private func sync(_ library: any PhotoLibraryService, store: PhotoSwipeStore) async -> LibrarySyncCoordinator {
        let coordinator = LibrarySyncCoordinator(library: library, store: store, calendar: utcCalendar)
        coordinator.requestSync()
        await coordinator.waitUntilIdle()
        return coordinator
    }

    @Test func indexesVisiblePhotosOnly() async throws {
        let library = InMemoryPhotoLibrary(assets: photos(5))
        library.setHidden(["p01"], hidden: true, notify: false)
        let store = try PhotoSwipeStore(url: nil)
        let coordinator = await sync(library, store: store)
        #expect(coordinator.phase == .finished)
        #expect(coordinator.processedCount == 4)
        #expect(try await store.assetCount(visibility: .accessible) == 4)
    }

    @Test func doesNothingWithoutAuthorization() async throws {
        let library = InMemoryPhotoLibrary(assets: photos(3), authorization: .denied)
        let store = try PhotoSwipeStore(url: nil)
        let coordinator = await sync(library, store: store)
        #expect(coordinator.phase == .idle)
        #expect(library.enumerationCount == 0)
        #expect(try await store.assetCount() == 0)
    }

    @Test func deletionInPhotosPurgesLocalDataInFullAccess() async throws {
        let library = InMemoryPhotoLibrary(assets: photos(3))
        let store = try PhotoSwipeStore(url: nil)
        _ = await sync(library, store: store)
        try await store.applyDecision(.markedForDeletion, to: "p01", sessionID: nil, at: Date())

        library.remove(["p01"], notify: false)
        let coordinator = await sync(library, store: store)
        #expect(coordinator.lastPlan?.purge == ["p01"])
        #expect(try await store.asset("p01") == nil)
        #expect(try await store.decision(for: "p01") == nil)
    }

    @Test func hiddenPhotoIsNotTreatedAsDeleted() async throws {
        let library = InMemoryPhotoLibrary(assets: photos(3))
        let store = try PhotoSwipeStore(url: nil)
        _ = await sync(library, store: store)
        try await store.applyDecision(.kept, to: "p02", sessionID: nil, at: Date())

        library.setHidden(["p02"], hidden: true, notify: false)
        _ = await sync(library, store: store)
        #expect(try await store.visibility(of: "p02") == .inaccessible)
        #expect(try await store.decision(for: "p02")?.decision == .kept)
    }

    @Test func limitedAccessNeverDeletesDecisions() async throws {
        let library = InMemoryPhotoLibrary(assets: photos(4))
        let store = try PhotoSwipeStore(url: nil)
        _ = await sync(library, store: store)
        try await store.applyDecision(.markedForDeletion, to: "p00", sessionID: nil, at: Date())
        try await store.applyDecision(.kept, to: "p01", sessionID: nil, at: Date())

        // Passage en accès limité avec seulement deux photos autorisées.
        library.setLimitedSelection(["p02", "p03"], notify: false)
        library.setAuthorization(.limited, notify: false)
        let limited = await sync(library, store: store)
        #expect(limited.lastPlan?.purge == [])
        #expect(try await store.visibility(of: "p00") == .inaccessible)
        #expect(try await store.decision(for: "p00")?.decision == .markedForDeletion)
        #expect(try await store.decisionCounts().totalAccessible == 2)

        // Retour en accès complet : tout réapparaît avec les décisions intactes.
        library.setAuthorization(.full, notify: false)
        _ = await sync(library, store: store)
        #expect(try await store.visibility(of: "p00") == .accessible)
        #expect(try await store.decision(for: "p00")?.decision == .markedForDeletion)
        #expect(try await store.decision(for: "p01")?.decision == .kept)
    }

    @Test func authorizationChangeDuringSyncSkipsReconciliation() async throws {
        let base = InMemoryPhotoLibrary(assets: photos(3))
        let store = try PhotoSwipeStore(url: nil)
        _ = await sync(base, store: store)
        try await store.applyDecision(.kept, to: "p00", sessionID: nil, at: Date())
        base.remove(["p00"], notify: false)

        // L'accès passe en « limité » pendant l'énumération : aucune purge ne doit être décidée
        // sur la base d'une énumération faite sous une autre autorisation.
        let flipping = AuthorizationFlippingLibrary(base: base, after: .limited)
        let store2Coordinator = LibrarySyncCoordinator(library: flipping, store: store, calendar: utcCalendar)
        store2Coordinator.requestSync()
        await store2Coordinator.waitUntilIdle()
        #expect(try await store.decision(for: "p00")?.decision == .kept)
        #expect(store2Coordinator.lastPlan?.purge.isEmpty ?? true)
    }

    @Test func changeNotificationsTriggerAResync() async throws {
        let library = InMemoryPhotoLibrary(assets: photos(2))
        let store = try PhotoSwipeStore(url: nil)
        let coordinator = LibrarySyncCoordinator(library: library, store: store, calendar: utcCalendar)
        coordinator.startObservingChanges()
        coordinator.requestSync()
        await coordinator.waitUntilIdle()
        #expect(try await store.assetCount() == 2)

        library.add([photo("new", day: 50)])
        // Attente bornée du déclenchement différé (anti-rebond).
        for _ in 0..<50 where try await store.assetCount() < 3 {
            try await Task.sleep(for: .milliseconds(100))
            await coordinator.waitUntilIdle()
        }
        #expect(try await store.assetCount() == 3)
        coordinator.stop()
    }

    @Test func overviewReflectsIndexAndResumableSession() async throws {
        let library = InMemoryPhotoLibrary(assets: photos(4))
        let store = try PhotoSwipeStore(url: nil)
        _ = await sync(library, store: store)
        let overview = LibraryOverviewModel(store: store)
        await overview.refresh()
        #expect(overview.counts.totalAccessible == 4)
        #expect(overview.resumable == nil)

        let model = try await SessionLauncher.open(scope: .everything, store: store)
        model.perform(.keep)
        await model.flush()
        await overview.refresh()
        #expect(overview.resumable?.remaining == 3)
        #expect(overview.resumable?.stats.kept == 1)
        #expect(overview.remainingToSort == 3)

        await overview.refreshMonths()
        #expect(overview.months.count == 1)
        #expect(overview.months.first?.remaining == 3)
    }

    @Test func markingForDeletionNeverRemovesPhotosFromTheLibrary() async throws {
        let library = InMemoryPhotoLibrary(assets: photos(5))
        let store = try PhotoSwipeStore(url: nil)
        _ = await sync(library, store: store)
        let model = try await SessionLauncher.open(scope: .everything, store: store)
        while model.current != nil {
            model.perform(.markForDeletion)
            if model.current == nil { await model.flush() }
        }
        #expect(try await store.decisionCounts().markedForDeletion == 5)
        #expect(library.allAssetIDs.count == 5)
    }
}
