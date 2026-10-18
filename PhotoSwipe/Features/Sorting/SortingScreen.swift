import PhotoSwipeCore
import PhotoSwipeFeatures
import SwiftUI

/// Conteneur d'une session : ouverture (nouvelle ou reprise), puis écran de tri.
struct SortingScreen: View {
    enum Source: Hashable {
        case scope(SessionScope)
        case resume
    }

    let source: Source
    let onExit: () -> Void
    let onReviewSelection: () -> Void

    @Environment(AppEnvironment.self) private var environment
    @State private var model: SortingSessionModel?
    @State private var didFail = false

    var body: some View {
        Group {
            if let model {
                SortingSessionView(
                    model: model,
                    onReviewDeferred: { reviewDeferred(of: model.scope) },
                    onReviewSelection: onReviewSelection,
                    onExit: onExit
                )
            } else if didFail {
                ContentUnavailableView {
                    Label("Impossible d'ouvrir cette session", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Vos décisions précédentes sont intactes. Réessayez dans un instant.")
                } actions: {
                    Button("Réessayer") {
                        Task { await load(source) }
                    }
                }
            } else {
                ProgressView("Préparation…")
            }
        }
        .task {
            if model == nil {
                await load(source)
            }
        }
        .onDisappear {
            let model = model
            let overview = environment.overview
            Task {
                await model?.flush()
                await overview.refresh()
            }
        }
    }

    private func load(_ source: Source) async {
        didFail = false
        do {
            switch source {
            case .scope(let scope):
                model = try await environment.openSession(scope: scope)
            case .resume:
                if let resumed = try await environment.resumeActiveSession() {
                    model = resumed
                } else {
                    model = try await environment.openSession(scope: .everything)
                }
            }
        } catch {
            didFail = true
        }
    }

    /// Enchaîne sur une session limitée aux photos passées, dans le même filtre.
    private func reviewDeferred(of scope: SessionScope) {
        let previous = model
        Task {
            await previous?.flush()
            model = nil
            await load(.scope(SessionScope(filter: scope.filter, pool: .deferredOnly)))
        }
    }
}
