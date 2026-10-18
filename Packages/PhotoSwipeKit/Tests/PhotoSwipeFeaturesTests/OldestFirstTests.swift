import Foundation
import Testing
import PhotoSwipeCore
import PhotoSwipeStore
@testable import PhotoSwipeFeatures

@MainActor
@Suite("Tri des plus anciennes aux plus récentes")
struct OldestFirstTests {
    private let oldest = SessionScope(filter: .all, pool: .standard, order: .oldestFirst)

    @Test func presentsOldestFirst() async throws {
        let store = try await indexedStore(library(4))
        let model = try await open(oldest, store: store, clock: TestClock())
        var presented: [AssetID] = []
        while let current = model.current {
            presented.append(current.id)
            model.perform(.keep)
            await model.flush()
        }
        #expect(presented == ["p00", "p01", "p02", "p03"])
        #expect(model.state == .completed)
    }

    @Test func resumesFromTheCursorAndKeepsOrder() async throws {
        let store = try await indexedStore(library(6))
        let clock = TestClock()
        let first = try await open(oldest, store: store, clock: clock)
        first.perform(.keep)
        first.perform(.keep)
        await first.flush()
        #expect(first.current?.id == "p02")

        let resumed = try await open(oldest, store: store, clock: clock)
        #expect(resumed.current?.id == "p02")
        #expect(resumed.remainingCount == 4)
    }

    @Test func newerPhotosAddedLaterComeAtTheEnd() async throws {
        let store = try await indexedStore(library(3))
        let model = try await open(oldest, store: store, clock: TestClock())
        model.perform(.keep)
        await model.flush()
        let generation = try await store.beginSyncGeneration()
        _ = try await store.upsertAssets(library(3) + [photo("new", day: 100)], generation: generation, calendar: utcCalendar)
        model.reloadQueue()
        await model.flush()
        var presented: [AssetID] = []
        while let current = model.current {
            presented.append(current.id)
            model.perform(.keep)
            await model.flush()
        }
        #expect(presented == ["p01", "p02", "new"])
    }

    @Test func keptReviewFollowsTheOrder() async throws {
        let store = try await indexedStore(library(3))
        for id in ["p00", "p01", "p02"] {
            try await store.applyDecision(.kept, to: AssetID(id), sessionID: nil, at: Date())
        }
        let review = SessionScope(filter: .all, pool: .keptReview, order: .oldestFirst)
        let model = try await open(review, store: store, clock: TestClock())
        #expect(model.current?.id == "p00")
        #expect(model.remainingCount == 3)
    }

    @Test func orderDistinguishesScopes() {
        #expect(SessionScope.everything != oldest)
    }

    @Test func enumerationFollowsTheRequestedOrder() async throws {
        let library = InMemoryPhotoLibrary(assets: photos(5))
        var ascending: [AssetID] = []
        for try await batch in library.assetBatches(batchSize: 2, order: .oldestFirst) {
            ascending += batch.map(\.id)
        }
        var descending: [AssetID] = []
        for try await batch in library.assetBatches(batchSize: 2) {
            descending += batch.map(\.id)
        }
        #expect(ascending == ["p00", "p01", "p02", "p03", "p04"])
        #expect(descending == ascending.reversed())
    }
}
