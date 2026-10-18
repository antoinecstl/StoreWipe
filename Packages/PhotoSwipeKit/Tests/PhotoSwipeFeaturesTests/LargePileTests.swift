import Foundation
import Testing
import PhotoSwipeCore
import PhotoSwipeStore
@testable import PhotoSwipeFeatures

private func sized(_ id: String, day: Int, megabytes: Int?, kind: MediaKind = .image) -> AssetSummary {
    AssetSummary(
        id: AssetID(id),
        creationDate: Date(timeIntervalSince1970: 1_704_110_400 + Double(day) * 86_400),
        pixelWidth: 4000,
        pixelHeight: 3000,
        mediaKind: kind,
        duration: kind == .video ? 30 : nil,
        byteSize: megabytes.map { Int64($0) * 1_000_000 }
    )
}

@MainActor
@Suite("Pile des gros fichiers")
struct LargePileTests {
    private let assets = [
        sized("p0", day: 1, megabytes: 10),
        sized("p1", day: 2, megabytes: 80),
        sized("p2", day: 3, megabytes: 200, kind: .video),
        sized("p3", day: 4, megabytes: 60),
        sized("p4", day: 5, megabytes: nil),
        sized("p5", day: 6, megabytes: 50),
    ]

    private func drain(_ model: SortingSessionModel) async -> [AssetID] {
        var presented: [AssetID] = []
        while let current = model.current {
            presented.append(current.id)
            model.perform(.keep)
            await model.flush()
        }
        return presented
    }

    @Test func presentsHeaviestFirstAndSkipsSmallOrUnmeasured() async throws {
        let store = try await indexedStore(assets)
        let scope = SessionScope(filter: .large(megabytes: 50, kind: nil))
        let model = try await open(scope, store: store, clock: TestClock())
        #expect(model.remainingCount == 4)
        // 200, 80, 60, puis 50 Mo : seuil inclus, plus petit et non mesuré écartés.
        #expect(await drain(model) == ["p2", "p1", "p3", "p5"])
        #expect(model.state == .completed)
    }

    @Test func dateOrderSettingDoesNotReorderBySize() async throws {
        let store = try await indexedStore(assets)
        let scope = SessionScope(filter: .large(megabytes: 50, kind: nil), pool: .standard, order: .oldestFirst)
        let model = try await open(scope, store: store, clock: TestClock())
        #expect(await drain(model) == ["p2", "p1", "p3", "p5"])
    }

    @Test func resumesAfterTheLastHandledSize() async throws {
        let store = try await indexedStore(assets)
        let scope = SessionScope(filter: .large(megabytes: 50, kind: nil))
        let clock = TestClock()
        let first = try await open(scope, store: store, clock: clock)
        first.perform(.keep)
        first.perform(.markForDeletion)
        await first.flush()
        #expect(first.current?.id == "p3")

        let resumed = try await open(scope, store: store, clock: clock)
        #expect(resumed.current?.id == "p3")
        #expect(resumed.remainingCount == 2)
    }

    @Test func kindFilterKeepsOnlyVideosOrPhotos() async throws {
        let store = try await indexedStore(assets)
        let videos = try await open(SessionScope(filter: .large(megabytes: 1, kind: .video)), store: store, clock: TestClock())
        #expect(await drain(videos) == ["p2"])
        let photos = try await open(SessionScope(filter: .large(megabytes: 50, kind: .image)), store: store, clock: TestClock())
        #expect(await drain(photos) == ["p1", "p3", "p5"])
    }

    @Test func skippedFilesReturnInALaterSession() async throws {
        let store = try await indexedStore(assets)
        let scope = SessionScope(filter: .large(megabytes: 50, kind: nil))
        let clock = TestClock()
        let model = try await open(scope, store: store, clock: clock)
        model.perform(.skip)
        await model.flush()
        // Dans la session en cours, la photo passée n'est pas reproposée.
        #expect(await drain(model) == ["p1", "p3", "p5"])
        // Dans la session suivante, elle revient.
        let next = try await open(scope, store: store, clock: clock)
        #expect(next.current?.id == "p2")
    }

    @Test func overviewSummarisesWhatIsLeftToSort() async throws {
        let store = try await indexedStore(assets)
        try await store.applyDecision(.kept, to: "p1", sessionID: nil, at: Date())
        let overview = LibraryOverviewModel(store: store)
        overview.largeThresholdMegabytes = 50
        await overview.refresh()
        // p2 (200) + p3 (60) + p5 (50) restent à trier ; p1 est déjà conservée.
        #expect(overview.largeToSort == SizeSummary(count: 3, bytes: 310_000_000))
    }
}
