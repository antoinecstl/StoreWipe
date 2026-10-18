import Foundation
import Testing
import PhotoSwipeCore
import PhotoSwipeStore
@testable import PhotoSwipeFeatures

struct FakeAnalyzer: ImageAnalyzing {
    let result: @Sendable (AssetID) throws -> ImageAnalysis?

    func analyze(_ id: AssetID) async throws -> ImageAnalysis? {
        try result(id)
    }
}

struct AnalyzerFailure: Error {}

@MainActor
final class PauseFlag {
    var isPaused = false
}

func labeled(_ name: String) -> ImageAnalysis {
    ImageAnalysis(
        labels: [ImageLabel(name: name, confidence: 0.9)],
        textCoverage: 0,
        textCharacterCount: 0,
        isUtility: false,
        aestheticsScore: 0.2
    )
}

@MainActor
@Suite("Analyse des photos")
struct AnalysisCoordinatorTests {
    @Test func analysesEveryPhotoAndFinishes() async throws {
        let store = try await indexedStore(library(30))
        let coordinator = AnalysisCoordinator(store: store, analyzer: FakeAnalyzer { _ in labeled("cat") })
        coordinator.start()
        await coordinator.waitUntilIdle()
        #expect(coordinator.phase == .finished)
        #expect(coordinator.progress == AnalysisProgress(total: 30, analyzed: 30))
        #expect(coordinator.skippedCount == 0)
        #expect(coordinator.revision > 0)
        #expect(try await store.labelStatistics().first?.count == 30)
    }

    @Test func skipsUnavailableAndFailingPhotosWithoutLooping() async throws {
        let store = try await indexedStore(library(6))
        let analyzer = FakeAnalyzer { id in
            switch id.rawValue {
            case "p01": return nil
            case "p03": throw AnalyzerFailure()
            default: return labeled("dog")
            }
        }
        let coordinator = AnalysisCoordinator(store: store, analyzer: analyzer)
        coordinator.start()
        await coordinator.waitUntilIdle()
        #expect(coordinator.phase == .finished)
        #expect(coordinator.skippedCount == 2)
        #expect(coordinator.progress == AnalysisProgress(total: 6, analyzed: 4))
    }

    @Test func pausesThenResumesByItself() async throws {
        let store = try await indexedStore(library(5))
        let flag = PauseFlag()
        flag.isPaused = true
        let coordinator = AnalysisCoordinator(
            store: store,
            analyzer: FakeAnalyzer { _ in labeled("cat") },
            shouldPause: { flag.isPaused },
            pauseInterval: .milliseconds(5)
        )
        coordinator.start()
        for _ in 0..<200 where coordinator.phase != .paused {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(coordinator.phase == .paused)
        #expect(coordinator.progress.analyzed == 0)
        flag.isPaused = false
        await coordinator.waitUntilIdle()
        #expect(coordinator.phase == .finished)
        #expect(coordinator.progress.analyzed == 5)
    }

    @Test func stopCancelsAndLeavesSavedResults() async throws {
        let store = try await indexedStore(library(40))
        let coordinator = AnalysisCoordinator(store: store, analyzer: FakeAnalyzer { _ in labeled("cat") })
        coordinator.start()
        coordinator.stop()
        await coordinator.waitUntilIdle()
        #expect(coordinator.phase != .finished)
        #expect(!coordinator.isActive)
        // Une relance termine le travail sans refaire ce qui est déjà enregistré.
        coordinator.start()
        await coordinator.waitUntilIdle()
        #expect(coordinator.progress == AnalysisProgress(total: 40, analyzed: 40))
    }

    @Test func newPhotosAreAnalysedOnRestart() async throws {
        let store = try await indexedStore(library(3))
        let coordinator = AnalysisCoordinator(store: store, analyzer: FakeAnalyzer { _ in labeled("cat") })
        coordinator.start()
        await coordinator.waitUntilIdle()
        let generation = try await store.beginSyncGeneration()
        _ = try await store.upsertAssets(library(3) + [photo("new", day: 50)], generation: generation, calendar: utcCalendar)
        coordinator.start()
        await coordinator.waitUntilIdle()
        #expect(coordinator.progress == AnalysisProgress(total: 4, analyzed: 4))
    }

    @Test func overviewListsCategoriesAfterAnalysis() async throws {
        let store = try await indexedStore(library(4))
        let analyzer = FakeAnalyzer { id in
            id.rawValue == "p00" || id.rawValue == "p01"
                ? ImageAnalysis(labels: [], textCoverage: 0.5, textCharacterCount: 300, isUtility: true, aestheticsScore: -0.5)
                : labeled("cat")
        }
        let coordinator = AnalysisCoordinator(store: store, analyzer: analyzer)
        coordinator.start()
        await coordinator.waitUntilIdle()
        let overview = LibraryOverviewModel(store: store)
        await overview.refresh()
        let documents = try #require(overview.categories.first { $0.category.key == BuiltInCategories.documents.key })
        #expect(documents.toSort == 2)
        #expect(documents.total == 2)
        #expect(overview.analysisProgress.isComplete)
    }
}
