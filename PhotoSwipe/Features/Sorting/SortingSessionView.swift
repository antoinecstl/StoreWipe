import PhotoSwipeCore
import PhotoSwipeFeatures
import SwiftUI

/// Écran de swipe : la photo occupe l'essentiel de l'écran, les boutons offrent une
/// alternative complète aux gestes et restent accessibles d'une seule main.
struct SortingSessionView: View {
    @Bindable var model: SortingSessionModel
    let onReviewDeferred: () -> Void
    let onReviewSelection: () -> Void
    let onExit: () -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @State private var swipeOffset: CGSize = .zero
    @State private var isCommitting = false
    @State private var decisionCount = 0
    @State private var cardSize: CGSize = .zero
    @State private var isShowingPauseSummary = false

    var body: some View {
        VStack(spacing: 14) {
            if model.state == .failed {
                ContentUnavailableView {
                    Label("Impossible de charger les photos", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Vos décisions précédentes sont intactes. Revenez à l'accueil puis réessayez.")
                } actions: {
                    Button("Retour à l'accueil", action: onExit)
                }
            } else if model.state == .completed {
                SessionSummaryView(
                    stats: model.stats,
                    isComplete: true,
                    onUndo: model.canUndo ? { model.undo() } : nil,
                    onContinue: nil,
                    onReviewDeferred: model.stats.deferred > 0 ? onReviewDeferred : nil,
                    onReviewSelection: model.stats.markedForDeletion > 0 ? onReviewSelection : nil,
                    onFinish: onExit
                )
            } else {
                SessionHeader(item: model.current, stats: model.stats, remaining: model.remainingCount)
                cardStack
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onGeometryChange(for: CGSize.self) { proxy in
                        proxy.size
                    } action: { size in
                        cardSize = size
                    }
                DecisionControls(
                    canUndo: model.canUndo && !isCommitting,
                    isEnabled: model.current != nil && !isCommitting,
                    onUndo: undo,
                    onAction: commit
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .navigationTitle(DisplayFormat.scopeTitle(model.scope))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.state != .completed {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Terminer") {
                        isShowingPauseSummary = true
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingPauseSummary) {
            SessionSummaryView(
                stats: model.stats,
                isComplete: false,
                onUndo: nil,
                onContinue: { isShowingPauseSummary = false },
                onReviewDeferred: nil,
                onReviewSelection: model.stats.markedForDeletion > 0
                    ? {
                        isShowingPauseSummary = false
                        onReviewSelection()
                    }
                    : nil,
                onFinish: {
                    isShowingPauseSummary = false
                    onExit()
                }
            )
            .presentationDetents([.medium, .large])
        }
        .sensoryFeedback(.impact(weight: .light), trigger: decisionCount)
        .onChange(of: model.current?.id, initial: true) {
            updatePrefetch()
        }
        .onChange(of: cardSize) {
            updatePrefetch()
        }
        .onChange(of: environment.sync.revision) {
            if model.state == .completed || model.isWaitingForItems {
                model.reloadQueue()
            }
        }
        .alert(issueTitle, isPresented: issueIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(issueMessage)
        }
    }

    // MARK: - Pile

    @ViewBuilder
    private var cardStack: some View {
        ZStack {
            if let next = model.upcoming.first {
                AssetCardBackground {
                    AssetImageView(id: next.id, pointSize: cardSize)
                }
                .scaleEffect(0.94)
                .opacity(0.5)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            if let item = model.current {
                SwipeablePhotoCard(
                    item: item,
                    offset: $swipeOffset,
                    isInteractive: !isCommitting,
                    onCommit: commit,
                    onUnavailable: { model.dropUnavailableCurrent() }
                )
                .id(item.id)
                .transition(.opacity)
            } else {
                ProgressView("Chargement des photos…")
            }
        }
    }

    // MARK: - Actions

    private func commit(_ action: SortAction) {
        guard !isCommitting, model.current != nil else { return }
        decisionCount += 1
        if reduceMotion {
            model.perform(action)
            swipeOffset = .zero
            return
        }
        isCommitting = true
        let width = max(cardSize.width, 320)
        let height = max(cardSize.height, 480)
        let target: CGSize
        switch action {
        case .keep: target = CGSize(width: width * 1.5, height: swipeOffset.height)
        case .markForDeletion: target = CGSize(width: -width * 1.5, height: swipeOffset.height)
        case .skip: target = CGSize(width: 0, height: -height * 1.3)
        }
        withAnimation(.easeOut(duration: 0.2)) {
            swipeOffset = target
        } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                model.perform(action)
                swipeOffset = .zero
            }
            isCommitting = false
        }
    }

    private func undo() {
        guard !isCommitting else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            model.undo()
        }
    }

    private func updatePrefetch() {
        let size = DisplayGeometry.pixelSize(for: cardSize, scale: displayScale)
        let ids = Array(model.upcoming.prefix(3).map(\.id))
        environment.images.updatePrefetch(ids, targetPixelSize: size, allowNetwork: environment.settings.allowsNetworkForDisplay)
    }

    // MARK: - Erreurs

    private var issueIsPresented: Binding<Bool> {
        Binding(
            get: { model.issue != nil },
            set: { isPresented in
                if !isPresented { model.issue = nil }
            }
        )
    }

    private var issueTitle: LocalizedStringKey {
        switch model.issue {
        case .saveFailed: "Décision non enregistrée"
        case .undoUnavailable: "Annulation impossible"
        case .loadFailed: "Chargement impossible"
        case nil: ""
        }
    }

    private var issueMessage: LocalizedStringKey {
        switch model.issue {
        case .saveFailed: "La dernière décision n'a pas pu être enregistrée. La photo vous est de nouveau proposée."
        case .undoUnavailable: "Cette photo a été modifiée depuis ailleurs dans l'app. Sa décision actuelle est conservée."
        case .loadFailed: "Les photos suivantes n'ont pas pu être chargées. Vos décisions sont intactes."
        case nil: ""
        }
    }
}

/// En-tête : date de la photo, raisons de sa présence et progression de la session.
struct SessionHeader: View {
    let item: QueueItem?
    let stats: SessionStats
    let remaining: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.map { DisplayFormat.photoDate($0.asset.creationDate) } ?? " ")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 8)
                Text("\(remaining) restantes")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let item {
                BadgeRow(item: item)
            }
            ProgressView(value: Double(stats.examined), total: Double(max(stats.examined + remaining, 1)))
                .accessibilityLabel(Text("Progression de la session"))
                .accessibilityValue(Text("Triées : \(stats.examined). Restantes : \(remaining)."))
        }
    }
}

/// Indices factuels issus des métadonnées (jamais d'une analyse non disponible).
struct BadgeRow: View {
    let item: QueueItem

    private struct Badge: Hashable {
        let title: String
        let systemImage: String
    }

    var body: some View {
        let badges = makeBadges()
        if !badges.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(badges, id: \.self) { badge in
                        Label(badge.title, systemImage: badge.systemImage)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color(.tertiarySystemFill)))
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func makeBadges() -> [Badge] {
        var badges: [Badge] = []
        if let reason = DisplayFormat.reason(for: item) {
            badges.append(Badge(title: reason, systemImage: "clock.arrow.circlepath"))
        }
        let asset = item.asset
        if asset.isFavorite {
            badges.append(Badge(title: String(localized: "Favori"), systemImage: "heart.fill"))
        }
        if asset.subtypes.contains(.screenshot) {
            badges.append(Badge(title: String(localized: "Capture d'écran"), systemImage: "camera.viewfinder"))
        }
        if asset.subtypes.contains(.livePhoto) {
            badges.append(Badge(title: String(localized: "Live Photo"), systemImage: "livephoto"))
        }
        if asset.subtypes.contains(.burst) {
            badges.append(Badge(title: String(localized: "Rafale"), systemImage: "square.stack.3d.down.right"))
        }
        return badges
    }
}

/// Fond et découpe communs aux cartes photo.
struct AssetCardBackground<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}
