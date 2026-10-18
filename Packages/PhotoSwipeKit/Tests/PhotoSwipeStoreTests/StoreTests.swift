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

@Suite("Store – captures d'écran et purge")
struct ScreenshotAndPurgeTests {
    private func indexed() async throws -> PhotoSwipeStore {
        let store = try PhotoSwipeStore(url: nil)
        let generation = try await store.beginSyncGeneration()
        let shot = { (id: String, day: Int) in
            AssetSummary(
                id: AssetID(id),
                creationDate: Date(timeIntervalSince1970: 1_704_110_400 + Double(day) * 86_400),
                pixelWidth: 1170,
                pixelHeight: 2532,
                subtypes: [.screenshot]
            )
        }
        _ = try await store.upsertAssets(
            [shot("s1", 1), shot("s2", 2), photo("p1", day: 3), photo("p2", day: 4)],
            generation: generation,
            calendar: utcCalendar
        )
        return store
    }

    @Test func screenshotFilterSelectsOnlyScreenshots() async throws {
        let store = try await indexed()
        let session = try await store.startSession(scope: SessionScope(filter: .screenshots), at: Date())
        let page = try await store.queuePage(
            QueueRequest(filter: .screenshots, phase: .main, sessionID: session.id, limit: 10)
        )
        #expect(Set(page.map(\.id)) == ["s1", "s2"])
    }

    @Test func toSortCountIgnoresHandledScreenshots() async throws {
        let store = try await indexed()
        #expect(try await store.toSortCount(filter: .screenshots) == 2)
        try await store.applyDecision(.kept, to: "s1", sessionID: nil, at: Date())
        #expect(try await store.toSortCount(filter: .screenshots) == 1)
        // Une capture passée reste à trier.
        try await store.applyDecision(.deferred, to: "s2", sessionID: nil, at: Date())
        #expect(try await store.toSortCount(filter: .screenshots) == 1)
        #expect(try await store.toSortCount(filter: .all) == 3)
    }

    @Test func purgeRemovesAssetsDecisionsAndEventsOnly() async throws {
        let store = try await indexed()
        try await store.applyDecision(.markedForDeletion, to: "s1", sessionID: nil, at: Date())
        try await store.applyDecision(.markedForDeletion, to: "p1", sessionID: nil, at: Date())
        try await store.purge(["s1"])
        #expect(try await store.asset("s1") == nil)
        #expect(try await store.decision(for: "s1") == nil)
        #expect(try await store.asset("p1") != nil)
        #expect(try await store.decision(for: "p1")?.decision == .markedForDeletion)
        try await store.purge([])
        #expect(try await store.assetCount() == 3)
    }
}

// MARK: - Analyses et catégories

func analysis(
    _ labels: [String: Double] = [:],
    coverage: Double = 0,
    utility: Bool = false,
    aesthetics: Double = 0.3
) -> ImageAnalysis {
    ImageAnalysis(
        labels: labels.map { ImageLabel(name: $0.key, confidence: $0.value) },
        textCoverage: coverage,
        textCharacterCount: Int(coverage * 1000),
        isUtility: utility,
        aestheticsScore: aesthetics
    )
}

@Suite("Store – analyses et catégories")
struct AnalysisStoreTests {
    private func indexed(_ assets: [AssetSummary]) async throws -> PhotoSwipeStore {
        let store = try PhotoSwipeStore(url: nil)
        let generation = try await store.beginSyncGeneration()
        _ = try await store.upsertAssets(assets, generation: generation, calendar: utcCalendar)
        return store
    }

    private func screenshot(_ id: String, day: Int) -> AssetSummary {
        AssetSummary(
            id: AssetID(id),
            creationDate: Date(timeIntervalSince1970: 1_704_110_400 + Double(day) * 86_400),
            pixelWidth: 1170,
            pixelHeight: 2532,
            subtypes: [.screenshot]
        )
    }

    @Test func migratesFromVersionOne() async throws {
        let url = temporaryDatabaseURL()
        _ = try makeFileStore(at: url)
        let connection = try SQLiteConnection(location: .file(url))
        try connection.execute("DROP TABLE analysis_labels;")
        try connection.execute("DROP TABLE analyses;")
        try connection.execute("DROP TABLE categories;")
        try connection.execute("DROP INDEX assets_by_size;")
        try connection.execute("ALTER TABLE assets DROP COLUMN media_type;")
        try connection.execute("ALTER TABLE assets DROP COLUMN duration;")
        try connection.execute("ALTER TABLE assets DROP COLUMN byte_size;")
        try connection.execute("PRAGMA user_version = 1;")
        let store = try PhotoSwipeStore(url: url)
        #expect(try await store.analysisProgress() == AnalysisProgress())
        #expect(try await store.customCategories().isEmpty)
        #expect(PhotoSwipeStore.schemaVersion >= 2)
    }

    @Test func tracksProgressAndReanalysesModifiedPhotos() async throws {
        let store = try await indexed([photo("a", day: 1), photo("b", day: 2)])
        #expect(try await store.analysisProgress() == AnalysisProgress(total: 2, analyzed: 0))
        let pending = try await store.assetsToAnalyze(limit: 10)
        #expect(Set(pending.map(\.id)) == ["a", "b"])
        try await store.saveAnalysis(analysis(["cat": 0.9]), for: pending[0], at: Date())
        #expect(try await store.analysisProgress() == AnalysisProgress(total: 2, analyzed: 1))
        #expect(try await store.assetsToAnalyze(limit: 10, excluding: [pending[1].id]).isEmpty)

        // La photo est retouchée : son empreinte change, elle redevient à analyser.
        let generation = try await store.beginSyncGeneration()
        _ = try await store.upsertAssets([photo(pending[0].id.rawValue, day: 1, modified: 1_800_000_000)], generation: generation, calendar: utcCalendar)
        #expect(try await store.analysisProgress().analyzed == 0)
    }

    @Test func customCategoryMatchesByLabelAndConfidence() async throws {
        let store = try await indexed([photo("a", day: 1), photo("b", day: 2), photo("c", day: 3)])
        let assets = try await store.assetsToAnalyze(limit: 10)
        let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        try await store.saveAnalysis(analysis(["cat": 0.9, "animal": 0.8]), for: byID["a"]!, at: Date())
        try await store.saveAnalysis(analysis(["dog": 0.7]), for: byID["b"]!, at: Date())
        try await store.saveAnalysis(analysis(["cat": 0.2]), for: byID["c"]!, at: Date())

        let pets = try await store.addCategory(name: "Animaux", labels: ["cat", "dog"], at: Date())
        #expect(pets.customID != nil)
        #expect(try await store.matchCount(rule: pets.rule) == 2)
        #expect(try await store.toSortCount(filter: .category(pets.key)) == 2)

        let session = try await store.startSession(scope: SessionScope(filter: .category(pets.key)), at: Date())
        let page = try await store.queuePage(QueueRequest(filter: .category(pets.key), phase: .main, sessionID: session.id, limit: 10))
        #expect(Set(page.map(\.id)) == ["a", "b"])
        #expect(try await store.remainingCount(for: session) == 2)

        let stats = try await store.labelStatistics()
        #expect(stats.first { $0.label == "cat" }?.count == 1)

        try await store.deleteCategory(id: pets.customID!)
        #expect(try await store.customCategories().isEmpty)
        #expect(try await store.toSortCount(filter: .category(pets.key)) == 0)
    }

    @Test func builtInDocumentsAndLowQualityRules() async throws {
        let store = try await indexed([
            photo("receipt", day: 1), photo("scan", day: 2), photo("blurry", day: 3),
            photo("nice", day: 4), screenshot("shot", day: 5), photo("object", day: 6),
        ])
        let assets = Dictionary(uniqueKeysWithValues: try await store.assetsToAnalyze(limit: 10).map { ($0.id, $0) })
        try await store.saveAnalysis(analysis(coverage: 0.1, utility: true, aesthetics: -0.8), for: assets["receipt"]!, at: Date())
        // Jugée utilitaire mais sans texte : un objet, pas un document.
        try await store.saveAnalysis(analysis(coverage: 0, utility: true, aesthetics: 0.1), for: assets["object"]!, at: Date())
        try await store.saveAnalysis(analysis(coverage: 0.4), for: assets["scan"]!, at: Date())
        try await store.saveAnalysis(analysis(aesthetics: -0.6), for: assets["blurry"]!, at: Date())
        try await store.saveAnalysis(analysis(aesthetics: 0.7), for: assets["nice"]!, at: Date())
        try await store.saveAnalysis(analysis(coverage: 0.5, utility: true), for: assets["shot"]!, at: Date())

        func ids(_ category: PhotoCategory) async throws -> Set<AssetID> {
            let session = try await store.startSession(scope: SessionScope(filter: .category(category.key)), at: Date())
            let page = try await store.queuePage(QueueRequest(filter: .category(category.key), phase: .main, sessionID: session.id, limit: 20))
            return Set(page.map(\.id))
        }
        // Les captures d'écran ont leur propre pile ; une image utilitaire n'est pas « peu réussie ».
        #expect(try await ids(BuiltInCategories.documents) == ["receipt", "scan"])
        #expect(try await ids(BuiltInCategories.lowQuality) == ["blurry"])
    }

    @Test func unanalysedPhotosBelongToNoCategory() async throws {
        let store = try await indexed([photo("a", day: 1)])
        #expect(try await store.toSortCount(filter: .category(BuiltInCategories.documents.key)) == 0)
        #expect(try await store.toSortCount(filter: .category("custom:999")) == 0)
        #expect(try await store.category(forKey: "nonsense") == nil)
    }

    @Test func purgeAndEraseRemoveAnalyses() async throws {
        let store = try await indexed([photo("a", day: 1), photo("b", day: 2)])
        for asset in try await store.assetsToAnalyze(limit: 10) {
            try await store.saveAnalysis(analysis(["cat": 0.9]), for: asset, at: Date())
        }
        try await store.purge(["a"])
        #expect(try await store.analysisProgress() == AnalysisProgress(total: 1, analyzed: 1))
        #expect(try await store.labelStatistics().first?.count == 1)
        try await store.addCategory(name: "X", labels: ["cat"], at: Date())
        try await store.eraseAll()
        #expect(try await store.labelStatistics().isEmpty)
        #expect(try await store.customCategories().isEmpty)
    }

    @Test func markAllToSortIsJournaledAndSkipsHandledPhotos() async throws {
        let store = try await indexed([screenshot("s1", day: 1), screenshot("s2", day: 2), screenshot("s3", day: 3), photo("p", day: 4)])
        try await store.applyDecision(.kept, to: "s1", sessionID: nil, at: Date())
        try await store.applyDecision(.deferred, to: "s3", sessionID: nil, at: Date())
        let count = try await store.markAllToSort(filter: .screenshots, as: .markedForDeletion, at: Date())
        #expect(count == 2)
        #expect(try await store.decision(for: "s1")?.decision == .kept)
        #expect(try await store.decision(for: "s2")?.decision == .markedForDeletion)
        #expect(try await store.decision(for: "s3")?.decision == .markedForDeletion)
        #expect(try await store.decision(for: "p") == nil)
        #expect(Set(try await store.markedForDeletion().map(\.id)) == ["s2", "s3"])
        // Rien de plus à marquer.
        #expect(try await store.markAllToSort(filter: .screenshots, as: .markedForDeletion, at: Date()) == 0)
    }
}

@Suite("Recherche d'étiquettes")
struct LabelSearchTests {
    @Test func matchesEnglishAndFrenchWords() {
        #expect(LabelSearch.matches(label: "cat", query: "cat"))
        #expect(LabelSearch.matches(label: "cat", query: "Chat"))
        #expect(LabelSearch.matches(label: "beach", query: "plage"))
        #expect(LabelSearch.matches(label: "hot_dog", query: "hot dog"))
        #expect(LabelSearch.matches(label: "receipt", query: "reçu"))
        #expect(!LabelSearch.matches(label: "dog", query: "chat"))
        #expect(LabelSearch.matches(label: "anything", query: "  "))
        #expect(LabelSearch.displayName("hot_dog") == "hot dog")
    }
}
