import Foundation
import Testing
import PhotoSwipeCore
@testable import PhotoSwipeStore

// MARK: - Aides

var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

/// Photo datée de `day` jours après le 1er janvier 2024 (UTC), à midi.
func photo(_ id: String, day: Int, modified: Double? = nil, width: Int = 4032) -> AssetSummary {
    AssetSummary(
        id: AssetID(id),
        creationDate: Date(timeIntervalSince1970: 1_704_110_400 + Double(day) * 86_400),
        modificationDate: modified.map(Date.init(timeIntervalSince1970:)),
        pixelWidth: width,
        pixelHeight: 3024
    )
}

func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("photoswipe-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("store.sqlite")
}

func makeFileStore(at url: URL) throws -> PhotoSwipeStore {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    return try PhotoSwipeStore(url: url)
}

/// Base en mémoire contenant `assets`, indexés lors de la passe 1.
func makeStore(_ assets: [AssetSummary]) async throws -> PhotoSwipeStore {
    let store = try PhotoSwipeStore(url: nil)
    let generation = try await store.beginSyncGeneration()
    _ = try await store.upsertAssets(assets, generation: generation, calendar: utcCalendar)
    return store
}

let t0 = Date(timeIntervalSince1970: 1_750_000_000)

// MARK: - Schéma et durabilité

@Suite("Store – schéma et durabilité")
struct StoreDurabilityTests {
    @Test func migratesToLatestVersion() async throws {
        let url = temporaryDatabaseURL()
        _ = try makeFileStore(at: url)
        let connection = try SQLiteConnection(location: .file(url))
        #expect(try connection.scalarInt("PRAGMA user_version;") == Int64(PhotoSwipeStore.schemaVersion))
        #expect(try connection.query("PRAGMA journal_mode;") { $0.text(0) } == ["wal"])
    }

    @Test func refusesNewerSchema() async throws {
        let url = temporaryDatabaseURL()
        _ = try makeFileStore(at: url)
        let connection = try SQLiteConnection(location: .file(url))
        try connection.execute("PRAGMA user_version = 999;")
        #expect(throws: DatabaseError.self) { _ = try PhotoSwipeStore(url: url) }
    }

    @Test func committedDecisionIsVisibleWithoutCleanShutdown() async throws {
        let url = temporaryDatabaseURL()
        let first = try makeFileStore(at: url)
        let generation = try await first.beginSyncGeneration()
        _ = try await first.upsertAssets([photo("a", day: 1)], generation: generation, calendar: utcCalendar)
        try await first.applyDecision(.markedForDeletion, to: "a", sessionID: nil, at: t0)

        // La première connexion n'est jamais fermée : on simule une app tuée après la validation.
        let second = try PhotoSwipeStore(url: url)
        let record = try await second.decision(for: "a")
        #expect(record?.decision == .markedForDeletion)
        #expect(record?.decidedAt == t0)
        withExtendedLifetime(first) {}
    }

    @Test func dataSurvivesReopen() async throws {
        let url = temporaryDatabaseURL()
        do {
            let store = try makeFileStore(at: url)
            let generation = try await store.beginSyncGeneration()
            _ = try await store.upsertAssets([photo("a", day: 1)], generation: generation, calendar: utcCalendar)
            try await store.applyDecision(.kept, to: "a", sessionID: nil, at: t0)
        }
        let reopened = try PhotoSwipeStore(url: url)
        #expect(try await reopened.decision(for: "a")?.decision == .kept)
        #expect(try await reopened.assetCount() == 1)
    }
}

// MARK: - Décisions et annulation

@Suite("Store – décisions")
struct StoreDecisionTests {
    @Test func unreviewedHasNoRow() async throws {
        let store = try await makeStore([photo("a", day: 1)])
        #expect(try await store.decision(for: "a") == nil)
    }

    @Test func undoRestoresUnreviewed() async throws {
        let store = try await makeStore([photo("a", day: 1)])
        let event = try await store.applyDecision(.markedForDeletion, to: "a", sessionID: nil, at: t0)
        #expect(event.previousDecision == .unreviewed)
        #expect(try await store.undo(eventID: event.id) == .restored(.unreviewed))
        #expect(try await store.decision(for: "a") == nil)
    }

    @Test func undoRestoresPreviousDecisionAndDate() async throws {
        let store = try await makeStore([photo("a", day: 1)])
        let deferredAt = t0
        try await store.applyDecision(.deferred, to: "a", sessionID: nil, at: deferredAt)
        let keep = try await store.applyDecision(.kept, to: "a", sessionID: nil, at: t0.addingTimeInterval(3_600))
        #expect(try await store.undo(eventID: keep.id) == .restored(.deferred))
        let record = try await store.decision(for: "a")
        #expect(record?.decision == .deferred)
        #expect(record?.decidedAt == deferredAt)
    }

    @Test func undoIsStaleOnceSuperseded() async throws {
        let store = try await makeStore([photo("a", day: 1)])
        let first = try await store.applyDecision(.kept, to: "a", sessionID: nil, at: t0)
        try await store.applyDecision(.markedForDeletion, to: "a", sessionID: nil, at: t0.addingTimeInterval(1))
        #expect(try await store.undo(eventID: first.id) == .stale)
        #expect(try await store.decision(for: "a")?.decision == .markedForDeletion)
    }

    @Test func undoTwiceIsStale() async throws {
        let store = try await makeStore([photo("a", day: 1)])
        let event = try await store.applyDecision(.kept, to: "a", sessionID: nil, at: t0)
        #expect(try await store.undo(eventID: event.id) == .restored(.unreviewed))
        #expect(try await store.undo(eventID: event.id) == .stale)
    }

    @Test func chainedUndoWalksBackHistory() async throws {
        let store = try await makeStore([photo("a", day: 1)])
        let first = try await store.applyDecision(.deferred, to: "a", sessionID: nil, at: t0)
        let second = try await store.applyDecision(.kept, to: "a", sessionID: nil, at: t0.addingTimeInterval(1))
        #expect(try await store.undo(eventID: second.id) == .restored(.deferred))
        #expect(try await store.undo(eventID: first.id) == .restored(.unreviewed))
        #expect(try await store.decision(for: "a") == nil)
    }

    @Test func countsAndMarkedList() async throws {
        let store = try await makeStore([photo("a", day: 1), photo("b", day: 2), photo("c", day: 3), photo("d", day: 4)])
        try await store.applyDecision(.kept, to: "a", sessionID: nil, at: t0)
        try await store.applyDecision(.markedForDeletion, to: "b", sessionID: nil, at: t0)
        try await store.applyDecision(.markedForDeletion, to: "c", sessionID: nil, at: t0)
        let counts = try await store.decisionCounts()
        #expect(counts == DecisionCounts(totalAccessible: 4, unreviewed: 1, kept: 1, markedForDeletion: 2, deferred: 0))
        #expect(try await store.markedForDeletion().map(\.id) == ["c", "b"])
    }
}

// MARK: - Piles

@Suite("Store – piles de tri")
struct StoreQueueTests {
    private let session = SessionID(rawValue: 1)

    @Test func mainPhaseIsNewestFirstAndSkipsDecided() async throws {
        let store = try await makeStore([photo("a", day: 1), photo("b", day: 3), photo("c", day: 2)])
        try await store.applyDecision(.kept, to: "c", sessionID: nil, at: t0)
        let page = try await store.queuePage(QueueRequest(filter: .all, phase: .main, sessionID: session, limit: 10))
        #expect(page.map(\.id) == ["b", "a"])
        #expect(page.allSatisfy { $0.decision == .unreviewed && $0.phase == .main })
    }

    @Test func cursorIsInclusiveOrExclusive() async throws {
        let assets = [photo("a", day: 1), photo("b", day: 2), photo("c", day: 3)]
        let store = try await makeStore(assets)
        let cursor = assets[1].sortKey
        let inclusive = try await store.queuePage(QueueRequest(filter: .all, phase: .main, sessionID: session, cursor: cursor, cursorInclusive: true, limit: 10))
        #expect(inclusive.map(\.id) == ["b", "a"])
        let exclusive = try await store.queuePage(QueueRequest(filter: .all, phase: .main, sessionID: session, cursor: cursor, cursorInclusive: false, limit: 10))
        #expect(exclusive.map(\.id) == ["a"])
    }

    @Test func sameDateTiesAreStable() async throws {
        let assets = [photo("x1", day: 5), photo("x3", day: 5), photo("x2", day: 5)]
        let store = try await makeStore(assets)
        let page = try await store.queuePage(QueueRequest(filter: .all, phase: .main, sessionID: session, limit: 10))
        #expect(page.map(\.id) == ["x3", "x2", "x1"])
        let afterFirst = try await store.queuePage(QueueRequest(filter: .all, phase: .main, sessionID: session, cursor: page[0].asset.sortKey, cursorInclusive: false, limit: 10))
        #expect(afterFirst.map(\.id) == ["x2", "x1"])
    }

    @Test func monthAndUndatedFilters() async throws {
        let undated = AssetSummary(id: "u", creationDate: nil, pixelWidth: 1, pixelHeight: 1)
        let store = try await makeStore([photo("jan", day: 10), photo("feb", day: 40), undated])
        let february = try #require(MonthKey(year: 2024, month: 2))
        let monthPage = try await store.queuePage(QueueRequest(filter: .month(february), phase: .main, sessionID: session, limit: 10))
        #expect(monthPage.map(\.id) == ["feb"])
        let undatedPage = try await store.queuePage(QueueRequest(filter: .undated, phase: .main, sessionID: session, limit: 10))
        #expect(undatedPage.map(\.id) == ["u"])
        let all = try await store.queuePage(QueueRequest(filter: .all, phase: .main, sessionID: session, limit: 10))
        #expect(all.map(\.id) == ["feb", "jan", "u"])
    }

    @Test func excludesGivenIDs() async throws {
        let store = try await makeStore([photo("a", day: 1), photo("b", day: 2)])
        let page = try await store.queuePage(QueueRequest(filter: .all, phase: .main, sessionID: session, excluding: ["b"], limit: 10))
        #expect(page.map(\.id) == ["a"])
    }

    @Test func deferredPhaseOrdersByDeferralAndExcludesHandledInSession() async throws {
        let store = try await makeStore([photo("a", day: 1), photo("b", day: 2), photo("c", day: 3)])
        let earlier = try await store.startSession(scope: .everything, at: t0)
        try await store.applyDecision(.deferred, to: "b", sessionID: earlier.id, at: t0.addingTimeInterval(10))
        try await store.applyDecision(.deferred, to: "a", sessionID: earlier.id, at: t0.addingTimeInterval(20))
        let current = try await store.startSession(scope: .everything, at: t0.addingTimeInterval(100))

        let page = try await store.queuePage(QueueRequest(filter: .all, phase: .deferred, sessionID: current.id, limit: 10))
        #expect(page.map(\.id) == ["b", "a"])
        #expect(page.first?.reason == .previouslyDeferred(since: t0.addingTimeInterval(10)))

        // Repasser « b » pendant la session courante l'exclut jusqu'à la prochaine session.
        try await store.applyDecision(.deferred, to: "b", sessionID: current.id, at: t0.addingTimeInterval(200))
        let after = try await store.queuePage(QueueRequest(filter: .all, phase: .deferred, sessionID: current.id, limit: 10))
        #expect(after.map(\.id) == ["a"])

        let next = try await store.startSession(scope: .everything, at: t0.addingTimeInterval(300))
        let nextPage = try await store.queuePage(QueueRequest(filter: .all, phase: .deferred, sessionID: next.id, limit: 10))
        #expect(nextPage.map(\.id) == ["a", "b"])
    }

    @Test func keptPhaseListsOnlyKeptPhotos() async throws {
        let store = try await makeStore([photo("a", day: 1), photo("b", day: 2), photo("c", day: 3)])
        try await store.applyDecision(.kept, to: "a", sessionID: nil, at: t0)
        try await store.applyDecision(.kept, to: "c", sessionID: nil, at: t0)
        try await store.applyDecision(.markedForDeletion, to: "b", sessionID: nil, at: t0)
        let review = try await store.startSession(scope: SessionScope(filter: .all, pool: .keptReview), at: t0.addingTimeInterval(10))
        let page = try await store.queuePage(QueueRequest(filter: .all, phase: .kept, sessionID: review.id, limit: 10))
        #expect(page.map(\.id) == ["c", "a"])
        #expect(page.first?.reason == .reviewingKept(since: t0))
        #expect(try await store.remainingCount(for: review) == 2)
    }

    @Test func remainingCountCoversMainAndDeferred() async throws {
        let store = try await makeStore([photo("a", day: 1), photo("b", day: 2), photo("c", day: 3), photo("d", day: 4)])
        let earlier = try await store.startSession(scope: .everything, at: t0)
        try await store.applyDecision(.deferred, to: "a", sessionID: earlier.id, at: t0)
        try await store.applyDecision(.kept, to: "b", sessionID: earlier.id, at: t0)
        let current = try await store.startSession(scope: .everything, at: t0.addingTimeInterval(10))
        // c, d non examinées + a passée lors d'une session précédente.
        #expect(try await store.remainingCount(for: current) == 3)
    }

    @Test func inaccessiblePhotosAreNeverQueued() async throws {
        let store = try await makeStore([photo("a", day: 1), photo("b", day: 2)])
        try await store.apply(ReconciliationPlan(markInaccessible: ["b"]))
        let page = try await store.queuePage(QueueRequest(filter: .all, phase: .main, sessionID: session, limit: 10))
        #expect(page.map(\.id) == ["a"])
    }
}

// MARK: - Index et réconciliation

@Suite("Store – index")
struct StoreIndexTests {
    @Test func upsertReportsInsertedUpdatedAndContentChanges() async throws {
        let store = try PhotoSwipeStore(url: nil)
        let g1 = try await store.beginSyncGeneration()
        let first = try await store.upsertAssets([photo("a", day: 1), photo("b", day: 2)], generation: g1, calendar: utcCalendar)
        #expect(first == UpsertResult(inserted: 2, updated: 0, contentChanged: []))

        let g2 = try await store.beginSyncGeneration()
        #expect(g2 == g1 + 1)
        let edited = photo("b", day: 2, modified: 1_800_000_000)
        let second = try await store.upsertAssets([photo("a", day: 1), edited], generation: g2, calendar: utcCalendar)
        #expect(second == UpsertResult(inserted: 0, updated: 2, contentChanged: ["b"]))
    }

    @Test func notSeenListsPhotosMissingFromLatestPass() async throws {
        let store = try PhotoSwipeStore(url: nil)
        let g1 = try await store.beginSyncGeneration()
        _ = try await store.upsertAssets([photo("a", day: 1), photo("b", day: 2)], generation: g1, calendar: utcCalendar)
        let g2 = try await store.beginSyncGeneration()
        _ = try await store.upsertAssets([photo("a", day: 1)], generation: g2, calendar: utcCalendar)
        #expect(try await store.assetsNotSeen(since: g2) == ["b"])
    }

    @Test func purgeRemovesDecisionsButInaccessibleKeepsThem() async throws {
        let store = try await makeStore([photo("a", day: 1), photo("b", day: 2)])
        try await store.applyDecision(.markedForDeletion, to: "a", sessionID: nil, at: t0)
        try await store.applyDecision(.kept, to: "b", sessionID: nil, at: t0)
        try await store.apply(ReconciliationPlan(markInaccessible: ["b"], purge: ["a"]))

        #expect(try await store.asset("a") == nil)
        #expect(try await store.decision(for: "a") == nil)
        #expect(try await store.visibility(of: "b") == .inaccessible)
        #expect(try await store.decision(for: "b")?.decision == .kept)
        #expect(try await store.decisionCounts().totalAccessible == 0)
    }

    @Test func reappearingPhotoRegainsVisibilityAndDecision() async throws {
        let store = try await makeStore([photo("a", day: 1)])
        try await store.applyDecision(.kept, to: "a", sessionID: nil, at: t0)
        try await store.apply(ReconciliationPlan(markInaccessible: ["a"]))
        let generation = try await store.beginSyncGeneration()
        _ = try await store.upsertAssets([photo("a", day: 1)], generation: generation, calendar: utcCalendar)
        #expect(try await store.visibility(of: "a") == .accessible)
        #expect(try await store.decision(for: "a")?.decision == .kept)
    }

    @Test func monthSummariesGroupAndCount() async throws {
        let undated = AssetSummary(id: "u", creationDate: nil, pixelWidth: 1, pixelHeight: 1)
        let store = try await makeStore([photo("j1", day: 1), photo("j2", day: 2), photo("f1", day: 40), undated])
        try await store.applyDecision(.kept, to: "j1", sessionID: nil, at: t0)
        try await store.applyDecision(.deferred, to: "j2", sessionID: nil, at: t0)
        let months = try await store.monthSummaries()
        #expect(months.map(\.month) == [MonthKey(year: 2024, month: 2), MonthKey(year: 2024, month: 1), nil])
        let january = try #require(months.first { $0.month == MonthKey(year: 2024, month: 1) })
        #expect(january.total == 2)
        #expect(january.kept == 1)
        #expect(january.deferred == 1)
        #expect(january.unreviewed == 0)
        #expect(january.remaining == 1)
    }
}

// MARK: - Sessions et réinitialisation

@Suite("Store – sessions")
struct StoreSessionTests {
    @Test func startingASessionEndsThePreviousOne() async throws {
        let store = try await makeStore([photo("a", day: 1)])
        let first = try await store.startSession(scope: .everything, at: t0)
        let second = try await store.startSession(scope: SessionScope(filter: .undated), at: t0.addingTimeInterval(1))
        #expect(try await store.activeSession()?.id == second.id)
        #expect(try await store.session(first.id)?.endedAt == t0.addingTimeInterval(1))
    }

    @Test func cursorPersists() async throws {
        let store = try await makeStore([photo("a", day: 1)])
        let session = try await store.startSession(scope: .everything, at: t0)
        let key = photo("a", day: 1).sortKey
        try await store.updateCursor(sessionID: session.id, cursor: key)
        #expect(try await store.activeSession()?.cursor == key)
    }

    @Test func statsIgnoreUndoneEvents() async throws {
        let store = try await makeStore([photo("a", day: 1), photo("b", day: 2), photo("c", day: 3)])
        let session = try await store.startSession(scope: .everything, at: t0)
        try await store.applyDecision(.kept, to: "a", sessionID: session.id, at: t0)
        let mark = try await store.applyDecision(.markedForDeletion, to: "b", sessionID: session.id, at: t0)
        try await store.applyDecision(.deferred, to: "c", sessionID: session.id, at: t0)
        _ = try await store.undo(eventID: mark.id)
        #expect(try await store.sessionStats(session.id) == SessionStats(kept: 1, markedForDeletion: 0, deferred: 1))
    }

    @Test func undoableEventsKeepOnlyLatestPerPhoto() async throws {
        let store = try await makeStore([photo("a", day: 1), photo("b", day: 2)])
        let session = try await store.startSession(scope: .everything, at: t0)
        try await store.applyDecision(.deferred, to: "a", sessionID: session.id, at: t0)
        try await store.applyDecision(.kept, to: "b", sessionID: session.id, at: t0)
        let latestA = try await store.applyDecision(.markedForDeletion, to: "a", sessionID: session.id, at: t0)
        let events = try await store.undoableEvents(sessionID: session.id, limit: 10)
        #expect(events.map(\.event.id) == [latestA.id, events[1].event.id])
        #expect(events.map(\.asset.id) == ["a", "b"])
        #expect(events[0].event.previousDecision == .deferred)
    }

    @Test func resetDecisionsKeepsIndex() async throws {
        let store = try await makeStore([photo("a", day: 1)])
        _ = try await store.startSession(scope: .everything, at: t0)
        try await store.applyDecision(.kept, to: "a", sessionID: nil, at: t0)
        try await store.resetDecisions()
        #expect(try await store.decision(for: "a") == nil)
        #expect(try await store.activeSession() == nil)
        #expect(try await store.assetCount() == 1)
    }

    @Test func eraseAllRemovesEverything() async throws {
        let url = temporaryDatabaseURL()
        let store = try makeFileStore(at: url)
        let generation = try await store.beginSyncGeneration()
        _ = try await store.upsertAssets([photo("a", day: 1)], generation: generation, calendar: utcCalendar)
        try await store.applyDecision(.kept, to: "a", sessionID: nil, at: t0)
        _ = try await store.startSession(scope: .everything, at: t0)
        try await store.eraseAll()
        #expect(try await store.assetCount() == 0)
        #expect(try await store.decision(for: "a") == nil)
        #expect(try await store.activeSession() == nil)
        #expect(try await store.beginSyncGeneration() == 1)
    }
}
