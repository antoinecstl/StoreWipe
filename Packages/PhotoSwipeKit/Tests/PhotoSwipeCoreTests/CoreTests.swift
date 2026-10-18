import Foundation
import Testing
@testable import PhotoSwipeCore

private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

@Suite("MonthKey")
struct MonthKeyTests {
    @Test func buildsFromDateInCalendarTimeZone() throws {
        // 2024-03-31T23:30:00Z
        let date = Date(timeIntervalSince1970: 1_711_927_800)
        #expect(MonthKey(date: date, calendar: utcCalendar) == MonthKey(year: 2024, month: 3))

        var paris = Calendar(identifier: .gregorian)
        paris.timeZone = TimeZone(identifier: "Europe/Paris")!
        #expect(MonthKey(date: date, calendar: paris) == MonthKey(year: 2024, month: 4))
    }

    @Test func rawValueRoundTrip() throws {
        let key = try #require(MonthKey(year: 2023, month: 11))
        #expect(key.rawValue == 202311)
        #expect(MonthKey(rawValue: 202311) == key)
        #expect(key.description == "2023-11")
    }

    @Test func rejectsInvalidMonths() {
        #expect(MonthKey(year: 2024, month: 0) == nil)
        #expect(MonthKey(year: 2024, month: 13) == nil)
        #expect(MonthKey(rawValue: 202400) == nil)
    }

    @Test func intervalCoversWholeMonth() throws {
        let key = try #require(MonthKey(year: 2024, month: 2))
        let interval = try #require(key.dateInterval(in: utcCalendar))
        #expect(interval.duration == 29 * 86_400)
    }

    @Test func ordering() throws {
        let earlier = try #require(MonthKey(year: 2023, month: 12))
        let later = try #require(MonthKey(year: 2024, month: 1))
        #expect(earlier < later)
    }
}

@Suite("SessionScope")
struct SessionScopeTests {
    @Test(arguments: [
        SessionScope.everything,
        SessionScope(filter: .month(MonthKey(year: 2024, month: 3)!), pool: .standard),
        SessionScope(filter: .undated, pool: .deferredOnly),
        SessionScope(filter: .month(MonthKey(year: 1999, month: 12)!), pool: .keptReview),
        SessionScope(filter: .all, pool: .keptReview),
        SessionScope(filter: .screenshots, pool: .standard),
        SessionScope(filter: .screenshots, pool: .deferredOnly),
        SessionScope(filter: .all, pool: .standard, order: .oldestFirst),
        SessionScope(filter: .month(MonthKey(year: 2024, month: 3)!), pool: .keptReview, order: .oldestFirst),
    ])
    func storageRoundTrip(scope: SessionScope) {
        #expect(SessionScope(storageValue: scope.storageValue) == scope)
    }

    @Test(arguments: ["", "standard", "unknown|all", "standard|month:abc", "standard|month:202413", "standard|weekly", "standard|all|newest", "standard|all|oldest|x"])
    func rejectsInvalidStorage(value: String) {
        #expect(SessionScope(storageValue: value) == nil)
    }

    @Test func standardPoolActions() {
        let scope = SessionScope.everything
        #expect(scope.targetDecision(for: .keep) == .kept)
        #expect(scope.targetDecision(for: .markForDeletion) == .markedForDeletion)
        #expect(scope.targetDecision(for: .skip) == .deferred)
        #expect(scope.phases == [.main, .deferred])
    }

    @Test func keptReviewSkipChangesNothing() {
        let scope = SessionScope(filter: .all, pool: .keptReview)
        #expect(scope.targetDecision(for: .skip) == nil)
        #expect(scope.targetDecision(for: .markForDeletion) == .markedForDeletion)
        #expect(scope.phases == [.kept])
    }

    @Test func deferredOnlyPool() {
        let scope = SessionScope(filter: .all, pool: .deferredOnly)
        #expect(scope.phases == [.deferred])
        #expect(scope.targetDecision(for: .skip) == .deferred)
    }
}

@Suite("AssetSummary")
struct AssetSummaryTests {
    private func asset(modified: Date? = nil, width: Int = 100, favorite: Bool = false) -> AssetSummary {
        AssetSummary(
            id: "a",
            creationDate: Date(timeIntervalSince1970: 1_000),
            modificationDate: modified,
            pixelWidth: width,
            pixelHeight: 50,
            isFavorite: favorite
        )
    }

    @Test func fingerprintIgnoresFavorite() {
        #expect(asset(favorite: false).contentFingerprint == asset(favorite: true).contentFingerprint)
    }

    @Test func fingerprintTracksEditsAndDimensions() {
        let base = asset()
        #expect(base.contentFingerprint != asset(modified: Date(timeIntervalSince1970: 2_000)).contentFingerprint)
        #expect(base.contentFingerprint != asset(width: 200).contentFingerprint)
    }

    @Test func undatedPhotosSortLast() {
        let undated = AssetSummary(id: "u", creationDate: nil, pixelWidth: 1, pixelHeight: 1)
        #expect(undated.sortDate == Date(timeIntervalSince1970: 0))
        #expect(undated.sortKey.date == 0)
    }
}

@Suite("SessionStats")
struct SessionStatsTests {
    @Test func recordsAndReverts() {
        var stats = SessionStats()
        stats.record(.kept, delta: 1)
        stats.record(.markedForDeletion, delta: 1)
        stats.record(.deferred, delta: 1)
        stats.record(nil, delta: 1)
        #expect(stats.examined == 4)
        stats.record(.kept, delta: -1)
        #expect(stats.kept == 0)
        #expect(stats.examined == 3)
    }
}

@Suite("ReconciliationPlanner")
struct ReconciliationPlannerTests {
    private let ids: [AssetID] = ["a", "b", "c"]

    @Test func fullAccessPurgesOnlyConfirmedMissing() {
        let plan = ReconciliationPlanner.plan(
            notSeen: ids,
            authorization: .full,
            confirmedExisting: ["b"],
            totalIndexed: 100
        )
        #expect(plan.purge == ["a", "c"])
        #expect(plan.markInaccessible == ["b"])
        #expect(!plan.purgeSuspended)
    }

    @Test func limitedAccessNeverPurges() {
        let plan = ReconciliationPlanner.plan(notSeen: ids, authorization: .limited, confirmedExisting: [], totalIndexed: 3)
        #expect(plan.purge.isEmpty)
        #expect(plan.markInaccessible == ids)
    }

    @Test(arguments: [LibraryAuthorization.denied, .restricted, .notDetermined])
    func noAccessChangesNothing(authorization: LibraryAuthorization) {
        let plan = ReconciliationPlanner.plan(notSeen: ids, authorization: authorization, confirmedExisting: [], totalIndexed: 3)
        #expect(plan == .empty)
    }

    @Test func massivePurgeIsSuspended() {
        let missing = (0..<300).map { AssetID("m\($0)") }
        let plan = ReconciliationPlanner.plan(notSeen: missing, authorization: .full, confirmedExisting: [], totalIndexed: 400)
        #expect(plan.purgeSuspended)
        #expect(plan.purge.isEmpty)
        #expect(plan.markInaccessible.count == 300)
    }

    @Test func largeButProportionallySmallPurgeProceeds() {
        let missing = (0..<300).map { AssetID("m\($0)") }
        let plan = ReconciliationPlanner.plan(notSeen: missing, authorization: .full, confirmedExisting: [], totalIndexed: 10_000)
        #expect(!plan.purgeSuspended)
        #expect(plan.purge.count == 300)
    }
}
