import Foundation
import Testing
import PhotoSwipeCore
import PhotoSwipeStore
@testable import PhotoSwipeFeatures

// MARK: - Aides

var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

func photo(_ id: String, day: Int) -> AssetSummary {
    AssetSummary(
        id: AssetID(id),
        creationDate: Date(timeIntervalSince1970: 1_704_110_400 + Double(day) * 86_400),
        pixelWidth: 4032,
        pixelHeight: 3024
    )
}

/// Horloge de test strictement croissante.
final class TestClock: Sendable {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)
    private let counter = Counter()

    var now: @Sendable () -> Date {
        { [base, counter] in base.addingTimeInterval(Double(counter.next())) }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

func indexedStore(_ assets: [AssetSummary], url: URL? = nil) async throws -> PhotoSwipeStore {
    if let url {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    let store = try PhotoSwipeStore(url: url)
    let generation = try await store.beginSyncGeneration()
    _ = try await store.upsertAssets(assets, generation: generation, calendar: utcCalendar)
    return store
}

func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("photoswipe-features-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("store.sqlite")
}

/// Photos `p00` (la plus ancienne) à `p{n-1}` (la plus récente).
func library(_ count: Int) -> [AssetSummary] {
    (0..<count).map { photo(String(format: "p%02d", $0), day: $0) }
}

@MainActor
func open(_ scope: SessionScope = .everything, store: PhotoSwipeStore, clock: TestClock) async throws -> SortingSessionModel {
    try await SessionLauncher.open(scope: scope, store: store, now: clock.now)
}

// MARK: - Tests

@MainActor
@Suite("Session de tri")
struct SortingSessionModelTests {
    @Test func presentsNewestFirstAndRecordsDecisions() async throws {
        let store = try await indexedStore(library(3))
        let clock = TestClock()
        let model = try await open(store: store, clock: clock)
        #expect(model.state == .sorting)
        #expect(model.current?.id == "p02")
        #expect(model.remainingCount == 3)

        model.perform(.keep)
        model.perform(.markForDeletion)
        model.perform(.skip)
        await model.flush()

        #expect(model.state == .completed)
        #expect(model.stats == SessionStats(kept: 1, markedForDeletion: 1, deferred: 1))
        #expect(try await store.decision(for: "p02")?.decision == .kept)
        #expect(try await store.decision(for: "p01")?.decision == .markedForDeletion)
        #expect(try await store.decision(for: "p00")?.decision == .deferred)
    }

    @Test func undoRestoresDecisionAndShowsPhotoAgain() async throws {
        let store = try await indexedStore(library(3))
        let model = try await open(store: store, clock: TestClock())
        model.perform(.markForDeletion)
        #expect(model.current?.id == "p01")
        model.undo()
        #expect(model.current?.id == "p02")
        #expect(model.stats.examined == 0)
        await model.flush()
        #expect(try await store.decision(for: "p02") == nil)
        #expect(!model.canUndo)
    }

    @Test func undoAfterCompletionReturnsToSorting() async throws {
        let store = try await indexedStore(library(1))
        let model = try await open(store: store, clock: TestClock())
        model.perform(.keep)
        await model.flush()
        #expect(model.state == .completed)
        model.undo()
        #expect(model.state == .sorting)
        #expect(model.current?.id == "p00")
        await model.flush()
        #expect(try await store.decision(for: "p00") == nil)
    }

    @Test func rapidActionsArePersistedInOrderWithoutRepeats() async throws {
        let store = try await indexedStore(library(40))
        let model = try await open(store: store, clock: TestClock())
        var presented: [AssetID] = []
        for index in 0..<40 {
            if model.current == nil { await model.flush() }
            let current = try #require(model.current)
            presented.append(current.id)
            model.perform(index.isMultiple(of: 2) ? .keep : .markForDeletion)
        }
        await model.flush()
        #expect(Set(presented).count == 40)
        #expect(presented == library(40).reversed().map(\.id))
        let counts = try await store.decisionCounts()
        #expect(counts.kept == 20)
        #expect(counts.markedForDeletion == 20)
        #expect(model.state == .completed)
    }

    @Test func resumesOnTheSamePhotoAfterRelaunch() async throws {
        let url = temporaryDatabaseURL()
        let clock = TestClock()
        do {
            let store = try await indexedStore(library(10), url: url)
            let model = try await open(store: store, clock: clock)
            model.perform(.keep)
            model.perform(.keep)
            model.perform(.skip)
            #expect(model.current?.id == "p06")
            await model.flush()
        }
        // Nouvelle instance (relance de l'app) sur le même fichier.
        let reopened = try PhotoSwipeStore(url: url)
        let resumed = try #require(try await SessionLauncher.resumeActive(store: reopened, now: clock.now))
        #expect(resumed.current?.id == "p06")
        #expect(resumed.stats == SessionStats(kept: 2, markedForDeletion: 0, deferred: 1))
        #expect(resumed.canUndo)

        // L'annulation fonctionne encore après la relance.
        resumed.undo()
        #expect(resumed.current?.id == "p07")
        await resumed.flush()
        #expect(try await reopened.decision(for: "p07") == nil)
    }

    @Test func newerPhotosAddedAfterPauseComeAfterTheResumePoint() async throws {
        let url = temporaryDatabaseURL()
        let clock = TestClock()
        let store = try await indexedStore(library(6), url: url)
        do {
            let model = try await open(store: store, clock: clock)
            model.perform(.keep) // p05
            model.perform(.keep) // p04
            await model.flush()
        }
        // Deux nouvelles photos, plus récentes que toutes les autres.
        let generation = try await store.beginSyncGeneration()
        _ = try await store.upsertAssets(library(6) + [photo("new1", day: 100), photo("new2", day: 101)], generation: generation, calendar: utcCalendar)

        let resumed = try await open(store: store, clock: clock)
        var order: [AssetID] = []
        while let current = resumed.current {
            order.append(current.id)
            resumed.perform(.keep)
            if resumed.current == nil { await resumed.flush() }
        }
        #expect(order == ["p03", "p02", "p01", "p00", "new2", "new1"])
    }

    @Test func deferredPhotosReturnInALaterSessionAfterUnreviewedOnes() async throws {
        let store = try await indexedStore(library(3))
        let clock = TestClock()
        let first = try await open(store: store, clock: clock)
        first.perform(.skip) // p02
        first.perform(.keep) // p01
        await first.flush()
        // « p02 » passée n'est pas reproposée dans la même session.
        #expect(first.current?.id == "p00")
        first.perform(.keep)
        await first.flush()
        #expect(first.state == .completed)

        // Nouvelle session : il ne reste que la photo passée.
        let second = try await open(store: store, clock: clock)
        #expect(second.session.id != first.session.id)
        #expect(second.current?.id == "p02")
        #expect(second.current?.reason == .previouslyDeferred(since: try await store.decision(for: "p02")?.decidedAt))
        second.perform(.skip)
        await second.flush()
        #expect(second.state == .completed)
    }

    @Test func keptReviewSkipLeavesDecisionUnchanged() async throws {
        let store = try await indexedStore(library(3))
        let clock = TestClock()
        let sorting = try await open(store: store, clock: clock)
        for _ in 0..<3 { sorting.perform(.keep) }
        await sorting.flush()

        let review = try await open(SessionScope(filter: .all, pool: .keptReview), store: store, clock: clock)
        #expect(review.remainingCount == 3)
        #expect(review.current?.id == "p02")
        review.perform(.skip)
        review.perform(.markForDeletion)
        review.perform(.keep)
        await review.flush()
        #expect(review.state == .completed)
        #expect(review.stats.examined == 3)
        #expect(try await store.decision(for: "p02")?.decision == .kept)
        #expect(try await store.decision(for: "p01")?.decision == .markedForDeletion)

        // Annuler un « passer » pendant la revue revient simplement sur la photo.
        review.undo() // keep p00
        review.undo() // mark p01
        review.undo() // skip p02
        #expect(review.current?.id == "p02")
        await review.flush()
        #expect(try await store.decision(for: "p01")?.decision == .kept)
    }

    @Test func monthSessionOnlyShowsThatMonth() async throws {
        // p00…p40 : 41 jours à partir du 1er janvier 2024.
        let store = try await indexedStore(library(41))
        let february = try #require(MonthKey(year: 2024, month: 2))
        let model = try await open(SessionScope(filter: .month(february)), store: store, clock: TestClock())
        #expect(model.remainingCount == 10)
        var seen: [AssetID] = []
        while let current = model.current {
            seen.append(current.id)
            model.perform(.keep)
            if model.current == nil { await model.flush() }
        }
        #expect(seen == (31...40).reversed().map { AssetID(String(format: "p%02d", $0)) })
    }

    @Test func unavailablePhotoIsDroppedWithoutDecision() async throws {
        let store = try await indexedStore(library(2))
        let model = try await open(store: store, clock: TestClock())
        model.dropUnavailableCurrent()
        await model.flush()
        #expect(model.current?.id == "p00")
        #expect(try await store.decision(for: "p01") == nil)
        #expect(model.stats.examined == 0)
    }

    @Test func reloadPicksUpPhotosIndexedAfterStart() async throws {
        let store = try PhotoSwipeStore(url: nil)
        let model = try await open(store: store, clock: TestClock())
        #expect(model.state == .completed)
        let generation = try await store.beginSyncGeneration()
        _ = try await store.upsertAssets(library(2), generation: generation, calendar: utcCalendar)
        model.reloadQueue()
        await model.flush()
        #expect(model.state == .sorting)
        #expect(model.current?.id == "p01")
        #expect(model.remainingCount == 2)
    }

    @Test func launcherStartsNewSessionWhenActiveOneIsExhausted() async throws {
        let store = try await indexedStore(library(1))
        let clock = TestClock()
        let first = try await open(store: store, clock: clock)
        first.perform(.keep)
        await first.flush()
        let again = try await open(store: store, clock: clock)
        #expect(again.session.id != first.session.id)

        let month = try #require(MonthKey(year: 2024, month: 1))
        let other = try await open(SessionScope(filter: .month(month)), store: store, clock: clock)
        #expect(other.session.id != again.session.id)
        #expect(try await store.activeSession()?.id == other.session.id)
    }
}
