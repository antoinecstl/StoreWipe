import Foundation
import Testing
import PhotoSwipeCore
import PhotoSwipeStore
@testable import PhotoSwipeFeatures

@MainActor
@Suite("Revue et suppression de la sélection")
struct DeletionReviewTests {
    private func makeModel(
        count: Int = 6,
        marked: [AssetID]
    ) async throws -> (DeletionReviewModel, InMemoryPhotoLibrary, PhotoSwipeStore) {
        let assets = library(count)
        let photoLibrary = InMemoryPhotoLibrary(assets: assets)
        let store = try await indexedStore(assets)
        for id in marked {
            try await store.applyDecision(.markedForDeletion, to: id, sessionID: nil, at: Date())
        }
        let model = DeletionReviewModel(store: store, library: photoLibrary, deleter: photoLibrary)
        await model.load()
        return (model, photoLibrary, store)
    }

    @Test func loadsOnlyTheSelection() async throws {
        let (model, _, _) = try await makeModel(marked: ["p01", "p03"])
        #expect(Set(model.items.map(\.id)) == ["p01", "p03"])
        #expect(model.selectedCount == 2)
    }

    @Test func deletesSelectionAndPurgesLocalData() async throws {
        let (model, photoLibrary, store) = try await makeModel(marked: ["p01", "p03"])
        await model.confirmDeletion()
        #expect(model.outcome == .deleted(count: 2, failed: 0))
        #expect(photoLibrary.allAssetIDs == ["p00", "p02", "p04", "p05"])
        #expect(try await store.asset("p01") == nil)
        #expect(try await store.decision(for: "p03") == nil)
        #expect(model.items.isEmpty)
        // Les photos non sélectionnées restent indexées.
        #expect(try await store.asset("p00") != nil)
    }

    @Test func refusalInSystemAlertChangesNothing() async throws {
        let (model, photoLibrary, store) = try await makeModel(marked: ["p01", "p03"])
        photoLibrary.setUserRefusesDeletion(true)
        await model.confirmDeletion()
        #expect(model.outcome == .cancelled)
        #expect(photoLibrary.allAssetIDs.count == 6)
        #expect(try await store.decision(for: "p01")?.decision == .markedForDeletion)
        #expect(model.selectedCount == 2)
    }

    @Test func partialDeletionOnlyCountsAndPurgesWhatDisappeared() async throws {
        let (model, photoLibrary, store) = try await makeModel(marked: ["p01", "p03"])
        photoLibrary.setUndeletable(["p03"])
        await model.confirmDeletion()
        #expect(model.outcome == .deleted(count: 1, failed: 1))
        #expect(try await store.asset("p01") == nil)
        #expect(try await store.asset("p03") != nil)
        #expect(try await store.decision(for: "p03")?.decision == .markedForDeletion)
        #expect(model.items.map(\.id) == ["p03"])
    }

    @Test func excludedPhotosAreKeptAndNeverDeleted() async throws {
        let (model, photoLibrary, store) = try await makeModel(marked: ["p01", "p03"])
        await model.toggle("p03")
        #expect(model.selectedCount == 1)
        #expect(try await store.decision(for: "p03")?.decision == .kept)
        await model.confirmDeletion()
        #expect(model.outcome == .deleted(count: 1, failed: 0))
        #expect(photoLibrary.allAssetIDs.contains("p03"))
        #expect(try await store.decision(for: "p03")?.decision == .kept)
    }

    @Test func togglingTwiceRestoresTheSelection() async throws {
        let (model, _, store) = try await makeModel(marked: ["p01"])
        await model.toggle("p01")
        await model.toggle("p01")
        #expect(model.selectedCount == 1)
        #expect(try await store.decision(for: "p01")?.decision == .markedForDeletion)
    }

    @Test func nothingSelectedDoesNothing() async throws {
        let (model, photoLibrary, _) = try await makeModel(marked: [])
        await model.confirmDeletion()
        #expect(model.outcome == nil)
        #expect(photoLibrary.allAssetIDs.count == 6)
    }
}
