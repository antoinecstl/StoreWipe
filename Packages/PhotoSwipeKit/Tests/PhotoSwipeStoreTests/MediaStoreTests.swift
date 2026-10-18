import Foundation
import Testing
import PhotoSwipeCore
@testable import PhotoSwipeStore

private func media(
    _ id: String,
    day: Int,
    kind: MediaKind = .image,
    bytes: Int64? = nil,
    width: Int = 4032,
    height: Int = 3024,
    duration: Double? = nil,
    subtypes: AssetSubtypes = [],
    favorite: Bool = false
) -> AssetSummary {
    AssetSummary(
        id: AssetID(id),
        creationDate: Date(timeIntervalSince1970: 1_704_110_400 + Double(day) * 86_400),
        pixelWidth: width,
        pixelHeight: height,
        subtypes: subtypes,
        isFavorite: favorite,
        mediaKind: kind,
        duration: duration,
        byteSize: bytes
    )
}

private func indexedStore(_ assets: [AssetSummary]) async throws -> PhotoSwipeStore {
    let store = try PhotoSwipeStore(url: nil)
    let generation = try await store.beginSyncGeneration()
    _ = try await store.upsertAssets(assets, generation: generation, calendar: utcCalendar)
    return store
}

@Suite("Store – vidéos et tailles")
struct MediaStoreTests {
    @Test func migratesFromVersionTwoKeepingExistingRows() async throws {
        let url = temporaryDatabaseURL()
        let store = try makeFileStore(at: url)
        let generation = try await store.beginSyncGeneration()
        _ = try await store.upsertAssets([media("a", day: 1)], generation: generation, calendar: utcCalendar)
        let connection = try SQLiteConnection(location: .file(url))
        // Retour à un schéma v2 : colonnes supprimées puis version abaissée.
        try connection.execute("DROP INDEX assets_duplicate_key;")
        try connection.execute("DROP INDEX resource_digests_by_hash;")
        try connection.execute("DROP TABLE resource_digests;")
        try connection.execute("DROP INDEX assets_by_size;")
        try connection.execute("ALTER TABLE assets DROP COLUMN media_type;")
        try connection.execute("ALTER TABLE assets DROP COLUMN duration;")
        try connection.execute("ALTER TABLE assets DROP COLUMN byte_size;")
        try connection.execute("PRAGMA user_version = 2;")
        let reopened = try PhotoSwipeStore(url: url)
        let asset = try #require(try await reopened.asset("a"))
        #expect(asset.mediaKind == .image)
        #expect(asset.byteSize == nil)
        #expect(PhotoSwipeStore.schemaVersion >= 3)
    }

    @Test func roundTripsVideoFieldsAndSizes() async throws {
        let store = try await indexedStore([
            media("v", day: 1, kind: .video, bytes: 120_000_000, duration: 61.5),
            media("p", day: 2),
        ])
        let video = try #require(try await store.asset("v"))
        #expect(video.mediaKind == .video)
        #expect(video.duration == 61.5)
        #expect(video.byteSize == 120_000_000)
        #expect(try await store.asset("p")?.byteSize == nil)
    }

    @Test func videoFingerprintDiffersFromImageFormat() {
        let image = media("p", day: 1)
        let video = media("v", day: 1, kind: .video, duration: 10)
        #expect(!image.contentFingerprint.contains("video"))
        #expect(video.contentFingerprint.hasSuffix("|video|10"))
    }

    @Test func measuresSizesAndReportsCoverage() async throws {
        let store = try await indexedStore([media("a", day: 1), media("b", day: 2), media("c", day: 3)])
        #expect(try await store.sizeCoverage() == SizeCoverage(measured: 0, total: 3))
        let pending = try await store.assetsWithoutSize(limit: 10)
        #expect(Set(pending) == ["a", "b", "c"])
        try await store.saveSizes(["a": 5_000_000, "b": 7_000_000])
        #expect(try await store.sizeCoverage() == SizeCoverage(measured: 2, total: 3))
        #expect(try await store.assetsWithoutSize(limit: 10) == ["c"])
        #expect(try await store.assetsWithoutSize(limit: 10, excluding: ["c"]).isEmpty)
    }

    @Test func modifiedPhotoLosesItsMeasuredSize() async throws {
        let store = try await indexedStore([media("a", day: 1, bytes: 4_000_000)])
        #expect(try await store.asset("a")?.byteSize == 4_000_000)
        // Même empreinte : la taille mesurée est conservée même si l'énumération n'en fournit pas.
        var generation = try await store.beginSyncGeneration()
        _ = try await store.upsertAssets([media("a", day: 1)], generation: generation, calendar: utcCalendar)
        #expect(try await store.asset("a")?.byteSize == 4_000_000)
        // Empreinte modifiée (dimensions) : l'ancienne taille n'est plus valable.
        generation = try await store.beginSyncGeneration()
        _ = try await store.upsertAssets([media("a", day: 1, width: 2000)], generation: generation, calendar: utcCalendar)
        #expect(try await store.asset("a")?.byteSize == nil)
    }

    @Test func listsLargestAssetsFirstWithFilters() async throws {
        let store = try await indexedStore([
            media("small", day: 1, bytes: 2_000_000),
            media("photo", day: 2, bytes: 30_000_000),
            media("video", day: 3, kind: .video, bytes: 900_000_000, duration: 300),
            media("unknown", day: 4),
            media("marked", day: 5, bytes: 500_000_000),
        ])
        try await store.applyDecision(.markedForDeletion, to: "marked", sessionID: nil, at: Date())
        try await store.applyDecision(.kept, to: "photo", sessionID: nil, at: Date())

        let all = try await store.largestAssets(kind: nil, minBytes: 10_000_000, limit: 10)
        #expect(all.map(\.id) == ["video", "photo"])
        #expect(all.last?.decision == .kept)
        #expect(try await store.largestAssets(kind: .image, minBytes: 1, limit: 10).map(\.id) == ["photo", "small"])
        #expect(try await store.largestAssets(kind: .video, minBytes: 1, limit: 10).map(\.id) == ["video"])
        #expect(try await store.largestAssets(kind: nil, minBytes: 1, limit: 1).map(\.id) == ["video"])
        #expect(try await store.largeSummary(kind: nil, minBytes: 10_000_000) == SizeSummary(count: 2, bytes: 930_000_000))
    }

    @Test func excludingVideosHidesThemFromCountsAndQueues() async throws {
        let store = try await indexedStore([
            media("p1", day: 1), media("p2", day: 2), media("v", day: 3, kind: .video, bytes: 1_000, duration: 5),
        ])
        #expect(try await store.decisionCounts().totalAccessible == 3)
        await store.setIncludesVideos(false)
        #expect(try await store.decisionCounts().totalAccessible == 2)
        let session = try await store.startSession(scope: .everything, at: Date())
        let page = try await store.queuePage(QueueRequest(filter: .all, phase: .main, sessionID: session.id, limit: 10))
        #expect(Set(page.map(\.id)) == ["p1", "p2"])
        #expect(try await store.remainingCount(for: session) == 2)
        #expect(try await store.toSortCount(filter: .all) == 2)
        await store.setIncludesVideos(true)
        #expect(try await store.decisionCounts().totalAccessible == 3)
    }

    @Test func marksSpecificAssetsOnce() async throws {
        let store = try await indexedStore([media("a", day: 1), media("b", day: 2), media("c", day: 3)])
        try await store.applyDecision(.markedForDeletion, to: "b", sessionID: nil, at: Date())
        let changed = try await store.markAssets(["a", "b", "ghost"], as: .markedForDeletion, at: Date())
        #expect(changed == 1)
        #expect(Set(try await store.markedForDeletion().map(\.id)) == ["a", "b"])
        #expect(try await store.markAssets([], as: .markedForDeletion, at: Date()) == 0)
    }

    @Test func findsProbableDuplicatesBySizeDimensionsAndDate() async throws {
        let store = try await indexedStore([
            media("a1", day: 1, bytes: 3_000_000),
            media("a2", day: 1, bytes: 3_000_000, favorite: true),
            media("other-size", day: 1, bytes: 3_000_001),
            media("other-day", day: 2, bytes: 3_000_000),
            media("v1", day: 3, kind: .video, bytes: 80_000_000, duration: 10),
            media("v2", day: 3, kind: .video, bytes: 80_000_000, duration: 10),
            media("v3", day: 3, kind: .video, bytes: 80_000_000, duration: 10),
            media("burst1", day: 4, bytes: 1_000_000, subtypes: [.burst]),
            media("burst2", day: 4, bytes: 1_000_000, subtypes: [.burst]),
            media("unmeasured1", day: 5),
            media("unmeasured2", day: 5),
        ])
        let groups = try await store.duplicateGroups()
        #expect(groups.count == 2)
        // Le groupe qui libérerait le plus de place vient d'abord.
        #expect(Set(groups[0].members.map(\.id)) == ["v1", "v2", "v3"])
        #expect(groups[0].reclaimableBytes == 160_000_000)
        #expect(Set(groups[1].members.map(\.id)) == ["a1", "a2"])
        // Règle affichée : le favori est proposé à la conservation.
        #expect(groups[1].suggestedKeeper == "a2")

        // Un exemplaire déjà dans la sélection à supprimer sort du groupe.
        try await store.applyDecision(.markedForDeletion, to: "a1", sessionID: nil, at: Date())
        #expect(try await store.duplicateGroups().count == 1)
    }

    @Test func keptMemberIsSuggestedBeforeFavorite() {
        let group = DuplicateGroup(members: [
            DuplicateMember(asset: media("a", day: 1, bytes: 10, favorite: true), decision: .unreviewed),
            DuplicateMember(asset: media("b", day: 1, bytes: 10), decision: .kept),
        ])
        #expect(group.suggestedKeeper == "b")
        #expect(group.reclaimableBytes == 10)
    }
}

@Suite("Raisons d'appartenance à une catégorie")
struct CategoryReasonTests {
    private func analysis(
        labels: [ImageLabel] = [],
        coverage: Double = 0,
        utility: Bool = false,
        aesthetics: Double = 0.3
    ) -> ImageAnalysis {
        ImageAnalysis(labels: labels, textCoverage: coverage, textCharacterCount: 0, isUtility: utility, aestheticsScore: aesthetics)
    }

    @Test func documentsNeedTextForUtilityImages() {
        let rule = BuiltInCategories.documents.rule
        #expect(rule.reasons(for: analysis(coverage: 0.1, utility: true)) == [.utility])
        #expect(rule.reasons(for: analysis(coverage: 0, utility: true)).isEmpty)
        #expect(rule.reasons(for: analysis(coverage: 0.5)) == [.textCoverage(0.5)])
        #expect(rule.reasons(for: analysis(coverage: 0.5, utility: true)) == [.utility, .textCoverage(0.5)])
    }

    @Test func labelReasonsAreOrderedByConfidenceAndFiltered() {
        let rule = CategoryRule.custom(labels: ["cat", "dog"])
        let found = analysis(labels: [
            ImageLabel(name: "dog", confidence: 0.6), ImageLabel(name: "cat", confidence: 0.9),
            ImageLabel(name: "tree", confidence: 0.99), ImageLabel(name: "cat2", confidence: 0.4),
        ])
        #expect(rule.reasons(for: found) == [.label("cat", 0.9), .label("dog", 0.6)])
    }

    @Test func lowQualityReason() {
        let rule = BuiltInCategories.lowQuality.rule
        #expect(rule.reasons(for: analysis(aesthetics: -0.5)) == [.lowAesthetics(-0.5)])
        #expect(rule.reasons(for: analysis(aesthetics: 0.2)).isEmpty)
    }

    @Test func storedAnalysisCanBeReadBack() async throws {
        let store = try PhotoSwipeStore(url: nil)
        let generation = try await store.beginSyncGeneration()
        _ = try await store.upsertAssets([media("a", day: 1)], generation: generation, calendar: utcCalendar)
        let asset = try #require(try await store.asset("a"))
        #expect(try await store.analysis(for: "a") == nil)
        let saved = analysis(
            labels: [ImageLabel(name: "cat", confidence: 0.9), ImageLabel(name: "animal", confidence: 0.7)],
            coverage: 0.2, utility: true, aesthetics: -0.1
        )
        try await store.saveAnalysis(saved, for: asset, at: Date())
        let read = try #require(try await store.analysis(for: "a"))
        #expect(read.labels.map(\.name) == ["cat", "animal"])
        #expect(read.isUtility)
        #expect(read.textCoverage == 0.2)
        #expect(read.aestheticsScore == -0.1)
    }
}
