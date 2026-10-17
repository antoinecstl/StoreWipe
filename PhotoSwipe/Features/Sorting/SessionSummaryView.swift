import PhotoSwipeCore
import SwiftUI

/// Bilan d'une session, en pause ou terminée. Les compteurs viennent des décisions
/// réellement enregistrées. Aucun volume n'est affiché tant qu'il n'est pas mesuré.
struct SessionSummaryView: View {
    let stats: SessionStats
    let isComplete: Bool
    let onUndo: (() -> Void)?
    let onContinue: (() -> Void)?
    let onReviewDeferred: (() -> Void)?
    let onFinish: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        StatTile(title: "Examinées", value: stats.examined, systemImage: "eye")
                        StatTile(title: "Conservées", value: stats.kept, systemImage: "checkmark.circle")
                    }
                    GridRow {
                        StatTile(title: "À supprimer", value: stats.markedForDeletion, systemImage: "trash")
                        StatTile(title: "Passées", value: stats.deferred, systemImage: "forward")
                    }
                }
                if stats.markedForDeletion > 0 {
                    Text("Rien n'a été supprimé : les photos à supprimer attendent votre confirmation dans la sélection.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                actions
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: isComplete ? "checkmark.seal.fill" : "pause.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            if isComplete {
                Text("Tout est trié ici")
                    .font(.title2.bold())
                Text("Il n'y a plus de photo à examiner dans cette session.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Session en pause")
                    .font(.title2.bold())
                Text("Votre progression est enregistrée : vous reprendrez exactement ici.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 12) {
            if let onContinue {
                Button(action: onContinue) {
                    Text("Continuer le tri").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            if let onReviewDeferred {
                Button(action: onReviewDeferred) {
                    Text("Revoir les photos passées").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            Button(action: onFinish) {
                Group {
                    if isComplete {
                        Text("Retour à l'accueil")
                    } else {
                        Text("Terminer pour l'instant")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            if let onUndo {
                Button("Annuler la dernière décision", action: onUndo)
                    .buttonStyle(.borderless)
            }
        }
    }
}

private struct StatTile: View {
    let title: LocalizedStringKey
    let value: Int
    let systemImage: String

    var body: some View {
        VStack(spacing: 6) {
            Text(value, format: .number)
                .font(.title.bold())
                .monospacedDigit()
            Label(title, systemImage: systemImage)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemBackground)))
        .accessibilityElement(children: .combine)
    }
}
