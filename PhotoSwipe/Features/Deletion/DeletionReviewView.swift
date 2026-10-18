import PhotoSwipeCore
import PhotoSwipeFeatures
import SwiftUI

/// Revue de la sélection « à supprimer » : on retire d'un toucher les photos qu'on veut
/// finalement garder, puis on confirme. La suppression elle-même est faite par iOS, qui
/// redemande une confirmation ; les photos vont dans « Supprimés récemment ».
struct DeletionReviewView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: DeletionReviewModel?
    @State private var isConfirming = false

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Sélection à supprimer")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard model == nil else { return }
            let created = environment.makeDeletionReview()
            await created.load()
            model = created
        }
    }

    @ViewBuilder
    private func content(_ model: DeletionReviewModel) -> some View {
        if model.items.isEmpty {
            ContentUnavailableView(
                "Aucune photo à supprimer",
                systemImage: "checkmark.circle",
                description: Text("Les photos que vous glissez vers la gauche apparaîtront ici avant toute suppression.")
            )
            .overlay(alignment: .bottom) { resultBanner(model) }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Touchez une photo pour la garder. Rien n'est supprimé avant votre confirmation.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 4)], spacing: 4) {
                        ForEach(model.items) { asset in
                            DeletionCell(
                                id: asset.id,
                                isSelected: model.isSelected(asset.id)
                            ) {
                                Task { await model.toggle(asset.id) }
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .padding(.vertical, 12)
            }
            .safeAreaInset(edge: .bottom) { bottomBar(model) }
            .confirmationDialog(
                "Supprimer \(model.selectedCount) photos ?",
                isPresented: $isConfirming,
                titleVisibility: .visible
            ) {
                Button("Continuer", role: .destructive) {
                    Task { await model.confirmDeletion() }
                }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("Les photos seront déplacées dans « Supprimés récemment » et restent récupérables 30 jours. Si vos photos sont dans iCloud, elles seront aussi supprimées de vos autres appareils. iOS vous demandera une dernière confirmation.")
            }
            .alert(
                outcomeTitle(model.outcome),
                isPresented: Binding(
                    get: { model.outcome != nil },
                    set: { if !$0 { model.dismissOutcome() } }
                )
            ) {
                Button("OK") { model.dismissOutcome() }
            } message: {
                Text(outcomeMessage(model.outcome))
            }
        }
    }

    private func bottomBar(_ model: DeletionReviewModel) -> some View {
        VStack(spacing: 8) {
            Button(role: .destructive) {
                isConfirming = true
            } label: {
                if model.isDeleting {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Label("Supprimer \(model.selectedCount) photos", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.selectedCount == 0 || model.isDeleting)
            if model.selectedCount < model.items.count {
                Text("\(model.items.count - model.selectedCount) photos retirées de la sélection seront conservées.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.bar)
    }

    /// Bannière de résultat quand la dernière photo vient d'être supprimée (la grille a disparu).
    @ViewBuilder
    private func resultBanner(_ model: DeletionReviewModel) -> some View {
        if case .deleted(let count, _)? = model.outcome {
            Label("\(count) photos supprimées", systemImage: "checkmark.circle.fill")
                .padding(12)
                .background(.thinMaterial, in: Capsule())
                .padding(.bottom, 24)
        }
    }

    private func outcomeTitle(_ outcome: DeletionReviewModel.Outcome?) -> LocalizedStringKey {
        switch outcome {
        case .deleted(let count, let failed):
            failed == 0 ? "\(count) photos supprimées" : "Suppression partielle"
        case .cancelled: "Aucune photo supprimée"
        case .failed: "Suppression impossible"
        case nil: ""
        }
    }

    private func outcomeMessage(_ outcome: DeletionReviewModel.Outcome?) -> LocalizedStringKey {
        switch outcome {
        case .deleted(let count, let failed):
            failed == 0
                ? "Elles sont dans « Supprimés récemment » pendant 30 jours."
                : "\(count) photos supprimées, \(failed) n'ont pas pu l'être et restent dans la sélection."
        case .cancelled: "Vous avez annulé : rien n'a été modifié."
        case .failed: "Réessayez dans un instant. Vos photos sont intactes."
        case nil: ""
        }
    }
}

private struct DeletionCell: View {
    let id: AssetID
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            AssetImageView(id: id, pointSize: CGSize(width: 160, height: 160))
                .frame(minWidth: 0, maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .background(Color(.secondarySystemBackground))
                .clipped()
                .opacity(isSelected ? 1 : 0.35)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: isSelected ? "trash.circle.fill" : "checkmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isSelected ? Color.red : Color.green)
                        .padding(6)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSelected ? Text("Photo à supprimer") : Text("Photo conservée"))
        .accessibilityHint(Text("Touchez pour changer"))
    }
}
