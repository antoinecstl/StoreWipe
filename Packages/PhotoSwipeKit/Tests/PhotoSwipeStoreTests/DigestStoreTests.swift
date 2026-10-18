import Foundation
import Testing
import PhotoSwipeCore
@testable import PhotoSwipeStore

private func item(
    _ id: String,
    day: Int = 1,
    bytes: Int64? = 1_000,
    width: Int = 100,
    height: Int = 100,
    kind: MediaKind = .image,
    modified: Double? = nil
) -> AssetSummary {
    AssetSummary(
        id: AssetID(id),
        creationDate: Date(timeIntervalSince1970: 1_704_110_400 + Double(day) * 86_400),
        modificationDate: modified.map(Date.init(timeIntervalSince1970:)),
        pixelWidth: width,
        pixelHeight: height,
        mediaKind: kind,
        duration: kind == .video ? 5 : nil,
        byteSize: bytes
    )
}

private func indexed(_ assets: [AssetSummary]) async throws -> PhotoSwipeStore {
    let store = try PhotoSwipeStore(url: nil)
    let generation = try await store.beginSyncGeneration()
    _ = try await store.upsertAssets(assets, generation: generation, calendar: utcCalendar)
    return store
}

@Suite("Store – empreintes et doublons exacts")
struct DigestStoreTests {
    @Test func migratesFromVersionThree() async throws {
        let url = temporaryDatabaseURL()
        _ = try makeFileStore(at: url)
        let connection = try SQLiteConnection(location: .file(url))
        try connection.execute("DROP INDEX assets_duplicate_key;")
        try connection.execute("DROP INDEX resource_digests_by_hash;")
        try connection.execute("DROP TABLE resource_digests;")
        try connection.execute("PRAGMA user_version = 3;")
        let store = try PhotoSwipeStore(url: url)
        #expect(try await store.digestedCount() == 0)
        #expect(PhotoSwipeStore.schemaVersion >= 4)
    }

    @Test func partialCandidatesNeedASameSizedSibling() async throws {
        let store = try await indexed([
            item("a"), item("b"),
            item("other-size", bytes: 999),
            item("other-dims", width: 101),
            item("video", kind: .video),
            item("unmeasured", bytes: nil),
        ])
        let candidates = try await store.digestCandidates(stage: .partial, limit: 10)
        #expect(Set(candidates.map(\.id)) == ["a", "b"])
        #expect(try await store.digestCandidates(stage: .partial, limit: 10, excluding: ["a"]).map(\.id) == ["b"])
        #expect(try await store.digestCandidates(stage: .full, limit: 10).isEmpty)
    }

    @Test func fullStageOnlyForSharedPartialDigests() async throws {
        let store = try await indexed([item("a"), item("b"), item("c")])
        try await store.savePartialDigest(for: "a", eligible: true, partial: "P1", at: Date())
        try await store.savePartialDigest(for: "b", eligible: true, partial: "P1", at: Date())
        try await store.savePartialDigest(for: "c", eligible: true, partial: "P2", at: Date())
        let full = try await store.digestCandidates(stage: .full, limit: 10)
        #expect(Set(full.map(\.id)) == ["a", "b"])
        // Les éléments déjà dotés d'une empreinte valide ne sont plus candidats à l'étape partielle.
        #expect(try await store.digestCandidates(stage: .partial, limit: 10).isEmpty)
        #expect(try await store.digestedCount() == 3)
    }

    @Test func ineligibleItemsNeverReachTheFullStage() async throws {
        let store = try await indexed([item("a"), item("b")])
        try await store.savePartialDigest(for: "a", eligible: true, partial: "P1", at: Date())
        try await store.savePartialDigest(for: "b", eligible: false, partial: nil, at: Date())
        #expect(try await store.digestCandidates(stage: .full, limit: 10).isEmpty)
        #expect(try await store.digestCandidates(stage: .partial, limit: 10).isEmpty)
    }

    @Test func exactGroupsRequireTheSameFullDigest() async throws {
        let store = try await indexed([item("a"), item("b"), item("c"), item("d", day: 9), item("v1", bytes: 5_000, kind: .video), item("v2", bytes: 5_000, kind: .video)])
        for id in ["a", "b", "c", "d"] {
            try await store.savePartialDigest(for: AssetID(id), eligible: true, partial: "P", at: Date())
        }
        try await store.saveFullDigest(for: "a", full: "F1", at: Date())
        try await store.saveFullDigest(for: "b", full: "F1", at: Date())
        try await store.saveFullDigest(for: "c", full: "F2", at: Date())
        try await store.saveFullDigest(for: "d", full: "F1", at: Date())
        for id in ["v1", "v2"] {
            try await store.savePartialDigest(for: AssetID(id), eligible: true, partial: "V", at: Date())
            try await store.saveFullDigest(for: AssetID(id), full: "FV", at: Date())
        }
        let groups = try await store.exactDuplicateGroups()
        #expect(groups.count == 2)
        #expect(groups.allSatisfy(\.isExact))
        // La vidéo (plus lourde) libère le plus de place : elle vient d'abord.
        #expect(Set(groups[0].members.map(\.id)) == ["v1", "v2"])
        // Même empreinte, même date ou non : c'est le contenu qui compte.
        #expect(Set(groups[1].members.map(\.id)) == ["a", "b", "d"])
        #expect(groups[1].reclaimableBytes == 2_000)
    }

    @Test func modifiedFileInvalidatesItsDigest() async throws {
        let store = try await indexed([item("a"), item("b")])
        for id in ["a", "b"] {
            try await store.savePartialDigest(for: AssetID(id), eligible: true, partial: "P", at: Date())
            try await store.saveFullDigest(for: AssetID(id), full: "F", at: Date())
        }
        #expect(try await store.exactDuplicateGroups().count == 1)
        // « a » est retouchée : son empreinte de modification change, le résultat n'est plus fiable.
        let generation = try await store.beginSyncGeneration()
        _ = try await store.upsertAssets([item("a", modified: 1_800_000_000), item("b")], generation: generation, calendar: utcCalendar)
        #expect(try await store.exactDuplicateGroups().isEmpty)
        // « a » a perdu son empreinte et redevient candidate ; « b », inchangée, n'a rien à refaire.
        #expect(try await store.digestCandidates(stage: .partial, limit: 10).map(\.id) == ["a"])
    }

    @Test func fullDigestIgnoredWhenTheItemChangedMeanwhile() async throws {
        let store = try await indexed([item("a"), item("b")])
        try await store.savePartialDigest(for: "a", eligible: true, partial: "P", at: Date())
        let generation = try await store.beginSyncGeneration()
        _ = try await store.upsertAssets([item("a", modified: 1_800_000_000), item("b")], generation: generation, calendar: utcCalendar)
        try await store.saveFullDigest(for: "a", full: "F", at: Date())
        #expect(try await store.digestedCount() == 0)
    }

    @Test func markedItemsLeaveExactGroupsAndPurgeRemovesDigests() async throws {
        let store = try await indexed([item("a"), item("b"), item("c")])
        for id in ["a", "b", "c"] {
            try await store.savePartialDigest(for: AssetID(id), eligible: true, partial: "P", at: Date())
            try await store.saveFullDigest(for: AssetID(id), full: "F", at: Date())
        }
        #expect(try await store.exactDuplicateGroups().first?.members.count == 3)
        try await store.applyDecision(.markedForDeletion, to: "a", sessionID: nil, at: Date())
        #expect(try await store.exactDuplicateGroups().first?.members.count == 2)
        try await store.purge(["b"])
        #expect(try await store.digestedCount() == 1)
        #expect(try await store.exactDuplicateGroups().isEmpty)
        try await store.eraseAll()
        #expect(try await store.digestedCount() == 0)
    }
}
