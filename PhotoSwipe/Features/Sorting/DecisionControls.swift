import PhotoSwipeCore
import SwiftUI

/// Boutons de décision : alternative complète au swipe, en bas d'écran pour l'usage à une main.
/// Raccourcis clavier : ← à supprimer, → conserver, ↓ passer, ⌘Z annuler.
struct DecisionControls: View {
    let canUndo: Bool
    let isEnabled: Bool
    let onUndo: () -> Void
    let onAction: (SortAction) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            ControlButton(title: "Annuler", systemImage: "arrow.uturn.backward", style: .secondary, action: onUndo)
                .disabled(!canUndo)
                .keyboardShortcut("z", modifiers: .command)
            ControlButton(title: "À supprimer", systemImage: "trash", style: .primary(.deleteTint)) {
                onAction(.markForDeletion)
            }
            .disabled(!isEnabled)
            .keyboardShortcut(.leftArrow, modifiers: [])
            ControlButton(title: "Passer", systemImage: "forward", style: .secondary) {
                onAction(.skip)
            }
            .disabled(!isEnabled)
            .keyboardShortcut(.downArrow, modifiers: [])
            ControlButton(title: "Conserver", systemImage: "checkmark", style: .primary(.keepTint)) {
                onAction(.keep)
            }
            .disabled(!isEnabled)
            .keyboardShortcut(.rightArrow, modifiers: [])
        }
    }
}

struct ControlButton: View {
    enum Style {
        case primary(Color)
        case secondary
    }

    let title: LocalizedStringKey
    let systemImage: String
    let style: Style
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .body) private var primaryDiameter: CGFloat = 64
    @ScaledMetric(relativeTo: .body) private var secondaryDiameter: CGFloat = 50

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(isPrimary ? .title2.weight(.semibold) : .title3)
                    .foregroundStyle(isPrimary ? Color.white : Color.primary)
                    .frame(width: diameter, height: diameter)
                    .background(Circle().fill(fill))
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
    }

    private var isPrimary: Bool {
        if case .primary = style { return true }
        return false
    }

    private var fill: Color {
        switch style {
        case .primary(let color): color
        case .secondary: Color(.tertiarySystemFill)
        }
    }

    /// Diamètre adapté à Dynamic Type, plafonné pour garder les quatre boutons sur une ligne.
    private var diameter: CGFloat {
        isPrimary ? min(primaryDiameter, 88) : min(secondaryDiameter, 72)
    }
}
