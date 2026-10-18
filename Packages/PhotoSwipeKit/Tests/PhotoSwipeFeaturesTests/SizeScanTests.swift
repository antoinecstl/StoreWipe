import Foundation
import Testing
import PhotoSwipeCore
import PhotoSwipeStore
@testable import PhotoSwipeFeatures

struct FakeSizer: AssetSizing {
    let sizes: @Sendable (AssetID) -> Int64?

    func byteSizes(for ids: [AssetID]) async -> [AssetID: Int64] {
        var result: [AssetID: Int64] = [:]
        for id in ids {
            if let size = sizes(id) { result[id] = size }
        }
        return result
    }
}

@MainActor
@Suite("Mesure des tailles et volume à supprimer")
struct SizeScanTests {
    @Test func measuresEverythingAndSkipsUnknownWithoutLooping() async throws {
        let store = try await indexedStore(library(450))
        let sizer = FakeSizer { id in id.rawValue == "p003" ? nil : 2_000_000 }
        let coordinator = SizeScanCoordinator(store: store, sizer: sizer)
        coordinator.start()
        await coordinator.waitUntilIdle()
        #expect(coordinator.phase == .finished)
        #expect(coordinator.coverage == SizeCoverage(measured: 449, total: 450))
        #expect(coordinator.revision > 0)
    }

    @Test func stopThenRestartCompletesTheWork() async throws {
        let store = try await indexedStore(library(60))
        let coordinator = SizeScanCoordinator(store: store, sizer: FakeSizer { _ in 1_000 })
        coordinator.start()
        coordinator.stop()
        await coordinator.waitUntilIdle()
        #expect(!coordinator.isActive)
        coordinator.start()
        await coordinator.waitUntilIdle()
        #expect(coordinator.coverage == SizeCoverage(measured: 60, total: 60))
    }

    @Test func deletionReviewSumsMeasuredSizesOnly() async throws {
        let assets = [
            AssetSummary(id: "a", creationDate: Date(timeIntervalSince1970: 1_700_000_000), pixelWidth: 10, pixelHeight: 10, byteSize: 5_000_000),
            AssetSummary(id: "b", creationDate: Date(timeIntervalSince1970: 1_700_100_000), pixelWidth: 10, pixelHeight: 10, byteSize: 7_000_000),
            AssetSummary(id: "c", creationDate: Date(timeIntervalSince1970: 1_700_200_000), pixelWidth: 10, pixelHeight: 10),
        ]
        let photoLibrary = InMemoryPhotoLibrary(assets: assets)
        let store = try await indexedStore(assets)
        for id in ["a", "b", "c"] {
            try await store.applyDecision(.markedForDeletion, to: AssetID(id), sessionID: nil, at: Date())
        }
        let model = DeletionReviewModel(store: store, library: photoLibrary, deleter: photoLibrary)
        await model.load()
        #expect(model.selectedSize == SizeSummary(count: 2, bytes: 12_000_000))
        await model.toggle("b")
        #expect(model.selectedSize == SizeSummary(count: 1, bytes: 5_000_000))
    }

    @Test func sampleLibraryIncludesVideosWithSizes() {
        let sample = SampleLibrary.assets(count: 100)
        let videos = sample.filter { $0.mediaKind == .video }
        #expect(!videos.isEmpty)
        #expect(videos.allSatisfy { $0.duration != nil && $0.byteSize != nil })
        #expect(sample.allSatisfy { $0.byteSize != nil })
    }
}
