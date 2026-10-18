import Foundation
import Testing
import PhotoSwipeCore
import PhotoSwipeStore
@testable import PhotoSwipeFeatures

/// Hacheur de test : empreintes imposées par identifiant, appels enregistrés.
final class FakeHasher: ResourceHashing, @unchecked Sendable {
    private let lock = NSLock()
    private var partialCalls: [AssetID] = []
    private var fullCalls: [AssetID] = []
    private let partial: [String: DigestOutcome]
    private let full: [String: DigestOutcome]

    init(partial: [String: DigestOutcome], full: [String: DigestOutcome]) {
        self.partial = partial
        self.full = full
    }

    var partialRequests: [AssetID] { lock.withLock { partialCalls } }
    var fullRequests: [AssetID] { lock.withLock { fullCalls } }

    func partialDigest(for id: AssetID, allowsNetwork: Bool) async -> DigestOutcome {
        lock.withLock { partialCalls.append(id) }
        return partial[id.rawValue] ?? .unavailable
    }

    func fullDigest(for id: AssetID, expectedBytes: Int64, allowsNetwork: Bool) async -> DigestOutcome {
        lock.withLock { fullCalls.append(id) }
        return full[id.rawValue] ?? .unavailable
    }
}

private func sibling(_ id: String, bytes: Int64 = 4_000_000) -> AssetSummary {
    AssetSummary(
        id: AssetID(id),
        creationDate: Date(timeIntervalSince1970: 1_700_000_000),
        pixelWidth: 4000,
        pixelHeight: 3000,
        byteSize: bytes
    )
}

@MainActor
@Suite("Vérification des doublons exacts")
struct DuplicateScanTests {
    @Test func hashesFullyOnlyWhenPartialDigestsCollide() async throws {
        let assets = [sibling("a"), sibling("b"), sibling("c"), sibling("e"), sibling("f"), sibling("lonely", bytes: 123)]
        let store = try await indexedStore(assets)
        let hasher = FakeHasher(
            partial: [
                "a": .digest("P1"), "b": .digest("P1"), "c": .digest("P2"),
                "e": .ineligible, "f": .unavailable,
            ],
            full: ["a": .digest("F1"), "b": .digest("F1")]
        )
        let coordinator = DuplicateScanCoordinator(store: store, hasher: hasher)
        coordinator.start()
        await coordinator.waitUntilIdle()

        #expect(coordinator.phase == .finished)
        // Un fichier sans sosie de même taille n'est jamais lu.
        #expect(!hasher.partialRequests.contains("lonely"))
        // L'empreinte complète n'est demandée que pour les deux fichiers dont l'empreinte partielle est partagée.
        #expect(Set(hasher.fullRequests) == ["a", "b"])
        #expect(coordinator.ineligible == 1)
        #expect(coordinator.unverifiable == 1)

        let groups = try await store.exactDuplicateGroups()
        #expect(groups.count == 1)
        #expect(Set(groups[0].members.map(\.id)) == ["a", "b"])
        #expect(groups[0].isExact)
    }

    @Test func unavailableFilesAreNotRetriedInTheSamePass() async throws {
        let store = try await indexedStore([sibling("a"), sibling("b")])
        let hasher = FakeHasher(partial: [:], full: [:])
        let coordinator = DuplicateScanCoordinator(store: store, hasher: hasher)
        coordinator.start()
        await coordinator.waitUntilIdle()
        #expect(coordinator.phase == .finished)
        #expect(hasher.partialRequests.count == 2)
        #expect(coordinator.unverifiable == 2)
        #expect(try await store.exactDuplicateGroups().isEmpty)
    }

    @Test func secondPassSkipsWhatIsAlreadyDigested() async throws {
        let store = try await indexedStore([sibling("a"), sibling("b")])
        let hasher = FakeHasher(
            partial: ["a": .digest("P"), "b": .digest("P")],
            full: ["a": .digest("F"), "b": .digest("F")]
        )
        let coordinator = DuplicateScanCoordinator(store: store, hasher: hasher)
        coordinator.start()
        await coordinator.waitUntilIdle()
        let firstPassCalls = hasher.partialRequests.count + hasher.fullRequests.count
        coordinator.start()
        await coordinator.waitUntilIdle()
        #expect(hasher.partialRequests.count + hasher.fullRequests.count == firstPassCalls)
        #expect(try await store.exactDuplicateGroups().count == 1)
    }

    @Test func pausesThenResumesOnItsOwn() async throws {
        let store = try await indexedStore([sibling("a"), sibling("b")])
        let flag = PauseFlag()
        flag.isPaused = true
        let hasher = FakeHasher(
            partial: ["a": .digest("P"), "b": .digest("P")],
            full: ["a": .digest("F"), "b": .digest("F")]
        )
        let coordinator = DuplicateScanCoordinator(
            store: store,
            hasher: hasher,
            pacing: { flag.isPaused ? .paused : .full },
            pauseInterval: .milliseconds(5)
        )
        coordinator.start()
        for _ in 0..<200 where coordinator.phase != .paused {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(coordinator.phase == .paused)
        #expect(hasher.partialRequests.isEmpty)
        flag.isPaused = false
        await coordinator.waitUntilIdle()
        #expect(coordinator.phase == .finished)
        #expect(try await store.exactDuplicateGroups().count == 1)
    }

    @Test func stopCancelsCleanly() async throws {
        let store = try await indexedStore([sibling("a"), sibling("b")])
        let hasher = FakeHasher(partial: ["a": .digest("P"), "b": .digest("P")], full: ["a": .digest("F"), "b": .digest("F")])
        let coordinator = DuplicateScanCoordinator(store: store, hasher: hasher)
        coordinator.start()
        coordinator.stop()
        await coordinator.waitUntilIdle()
        #expect(!coordinator.isActive)
        #expect(coordinator.phase != .finished)
    }
}

@MainActor
@Suite("Cadence de l'analyse")
struct AnalysisPacingTests {
    @Test func throttlingSlowsTheWorkInsteadOfStoppingIt() async throws {
        let store = try await indexedStore(library(6))
        let coordinator = AnalysisCoordinator(
            store: store,
            analyzer: FakeAnalyzer { _ in labeled("cat") },
            pacing: { .throttled(.milliseconds(2)) }
        )
        coordinator.start()
        await coordinator.waitUntilIdle()
        #expect(coordinator.phase == .finished)
        #expect(coordinator.progress == AnalysisProgress(total: 6, analyzed: 6))
        // Une fois terminée, plus aucune cadence réduite n'est affichée.
        #expect(!coordinator.isThrottled)
    }
}
