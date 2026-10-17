import PhotoSwipeCore
import SwiftUI

/// Carte de la photo courante : swipe horizontal pour décider, pincement et double-tap pour zoomer.
///
/// Garde-fous contre les décisions accidentelles :
/// - quand la photo est zoomée (ou en cours de pincement), un glissement déplace l'image
///   et ne peut jamais valider une décision ;
/// - un pincement commencé pendant un swipe annule le swipe ;
/// - un geste trop vertical ou trop court revient à sa position initiale.
struct SwipeablePhotoCard: View {
    let item: QueueItem
    @Binding var offset: CGSize
    let isInteractive: Bool
    let onCommit: (SortAction) -> Void
    let onUnavailable: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var zoomScale: CGFloat = 1
    @State private var pinchScale: CGFloat = 1
    @State private var isPinching = false
    @State private var panOffset: CGSize = .zero
    @State private var panStart: CGSize = .zero
    @State private var dragMode: DragMode?
    @State private var pendingAction: SortAction?
    @State private var containerSize: CGSize = .zero

    private enum DragMode {
        case swipe
        case pan
    }

    static let commitDistance: CGFloat = 110
    static let maximumZoom: CGFloat = 5

    private var effectiveScale: CGFloat { max(1, zoomScale * pinchScale) }
    private var isZoomed: Bool { effectiveScale > 1.01 || isPinching }
    /// Au-delà d'un certain zoom, une version plus détaillée de l'image est demandée.
    private var zoomFactor: CGFloat { zoomScale > 1.5 ? 2.5 : 1 }

    var body: some View {
        AssetCardBackground {
            AssetImageView(id: item.id, pointSize: containerSize, zoomFactor: zoomFactor, onUnavailable: onUnavailable)
                .scaleEffect(effectiveScale)
                .offset(isZoomed ? panOffset : .zero)
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            containerSize = size
        }
        .overlay(alignment: .topLeading) {
            DecisionStamp(kind: .keep)
                .opacity(stampOpacity(for: .keep))
                .padding(16)
        }
        .overlay(alignment: .topTrailing) {
            DecisionStamp(kind: .delete)
                .opacity(stampOpacity(for: .markForDeletion))
                .padding(16)
        }
        .overlay(alignment: .bottomTrailing) {
            if zoomScale > 1.01 {
                Button {
                    withAnimation(.spring(duration: 0.3)) { resetZoom() }
                } label: {
                    Label("Taille réelle", systemImage: "arrow.down.right.and.arrow.up.left")
                        .labelStyle(.iconOnly)
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(.thinMaterial, in: Circle())
                }
                .padding(12)
                .accessibilityLabel(Text("Revenir à la taille initiale"))
            }
        }
        .offset(isZoomed ? .zero : offset)
        .rotationEffect(rotation)
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .simultaneousGesture(magnifyGesture)
        .onTapGesture(count: 2, perform: toggleZoom)
        .sensoryFeedback(trigger: pendingAction) { _, newValue in
            newValue == nil ? nil : .selection
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Photo du \(DisplayFormat.photoDate(item.asset.creationDate))"))
        .accessibilityHint(Text("Actions : conserver, à supprimer, passer. Pincez ou touchez deux fois pour zoomer."))
        .accessibilityAddTraits(.isImage)
        .accessibilityAction(named: Text("Conserver")) { onCommit(.keep) }
        .accessibilityAction(named: Text("À supprimer")) { onCommit(.markForDeletion) }
        .accessibilityAction(named: Text("Passer")) { onCommit(.skip) }
        .accessibilityZoomAction { action in
            if action.direction == .zoomIn {
                zoomScale = min(zoomScale + 1, Self.maximumZoom)
            } else {
                zoomScale = max(zoomScale - 1, 1)
                if zoomScale <= 1.01 { resetZoom() }
            }
        }
    }

    // MARK: - Gestes

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard isInteractive else { return }
                if dragMode == nil {
                    dragMode = isZoomed ? .pan : .swipe
                }
                switch dragMode {
                case .pan:
                    panOffset = clampedPan(CGSize(
                        width: panStart.width + value.translation.width,
                        height: panStart.height + value.translation.height
                    ))
                case .swipe:
                    offset = value.translation
                    pendingAction = Self.action(for: value.translation)
                case nil:
                    break
                }
            }
            .onEnded { value in
                defer { dragMode = nil }
                switch dragMode {
                case .pan:
                    panStart = panOffset
                case .swipe:
                    if isInteractive, !isPinching, let action = Self.committedAction(for: value) {
                        pendingAction = nil
                        onCommit(action)
                    } else {
                        cancelSwipe()
                    }
                case nil:
                    break
                }
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard isInteractive else { return }
                if !isPinching {
                    isPinching = true
                    // Un pincement ne doit jamais aboutir à une décision.
                    if dragMode == .swipe { dragMode = .pan }
                    cancelSwipe()
                }
                pinchScale = value.magnification
            }
            .onEnded { value in
                zoomScale = min(max(zoomScale * value.magnification, 1), Self.maximumZoom)
                pinchScale = 1
                isPinching = false
                if zoomScale <= 1.01 {
                    withAnimation(.spring(duration: 0.3)) { resetZoom() }
                } else {
                    panOffset = clampedPan(panOffset)
                    panStart = panOffset
                }
            }
    }

    private func toggleZoom() {
        guard isInteractive else { return }
        withAnimation(.spring(duration: 0.3)) {
            if zoomScale > 1.01 {
                resetZoom()
            } else {
                zoomScale = 2.5
            }
        }
    }

    private func resetZoom() {
        zoomScale = 1
        pinchScale = 1
        panOffset = .zero
        panStart = .zero
    }

    private func cancelSwipe() {
        pendingAction = nil
        guard offset != .zero else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            offset = .zero
        }
    }

    private func clampedPan(_ proposed: CGSize) -> CGSize {
        let maxX = max(0, (effectiveScale - 1) * containerSize.width / 2)
        let maxY = max(0, (effectiveScale - 1) * containerSize.height / 2)
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }

    // MARK: - Seuils

    /// Action atteinte pendant le geste (retour visuel et haptique).
    static func action(for translation: CGSize) -> SortAction? {
        guard abs(translation.width) > abs(translation.height) * 0.8 else { return nil }
        if translation.width > commitDistance { return .keep }
        if translation.width < -commitDistance { return .markForDeletion }
        return nil
    }

    /// Action validée en fin de geste : distance suffisante, ou lancer franc dans une direction.
    static func committedAction(for value: DragGesture.Value) -> SortAction? {
        let translation = value.translation
        guard abs(translation.width) > abs(translation.height) * 0.8 else { return nil }
        let predicted = value.predictedEndTranslation.width
        if translation.width > commitDistance || (translation.width > 40 && predicted > commitDistance * 2.2) {
            return .keep
        }
        if translation.width < -commitDistance || (translation.width < -40 && predicted < -commitDistance * 2.2) {
            return .markForDeletion
        }
        return nil
    }

    private func stampOpacity(for action: SortAction) -> Double {
        guard !isZoomed else { return 0 }
        let progress = Double(offset.width / Self.commitDistance)
        switch action {
        case .keep: return min(max(progress, 0), 1)
        case .markForDeletion: return min(max(-progress, 0), 1)
        case .skip: return 0
        }
    }

    private var rotation: Angle {
        guard !reduceMotion, !isZoomed else { return .zero }
        return .degrees(Double(offset.width / 22))
    }
}

/// Étiquette affichée pendant le swipe : texte + icône, jamais la couleur seule.
struct DecisionStamp: View {
    enum Kind {
        case keep
        case delete
    }

    let kind: Kind

    var body: some View {
        Label(title, systemImage: kind == .keep ? "checkmark.circle.fill" : "trash.fill")
            .font(.title3.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(kind == .keep ? Color.keepTint : Color.deleteTint))
            .accessibilityHidden(true)
    }

    private var title: LocalizedStringKey {
        kind == .keep ? "Conserver" : "À supprimer"
    }
}

extension Color {
    /// Couleurs de décision définies dans le catalogue (contraste vérifié avec du texte blanc).
    static let keepTint = Color("KeepTint")
    static let deleteTint = Color("DeleteTint")
}
