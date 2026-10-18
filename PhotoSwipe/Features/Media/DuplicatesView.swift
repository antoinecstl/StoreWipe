import PhotoSwipeCore
import SwiftUI

/// Doublons probables : mêmes dimensions, même seconde de prise de vue, même taille.
/// Un exemplaire est toujours conservé ; les autres rejoignent la sélection à supprimer.
struct DuplicatesView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var groups: [DuplicateGroup] = []
    @State private var isLoading = true
    @State private var isConfirmingAll = false

    var body: some View {
        List {
            Section {
                if isLoading && groups.isEmpty {
                    ProgressView()
                } else if groups.isEmpty {
                    ContentUnavailableView(
                        "Aucun doublon probable",
                        systemImage: "square.on.square",
                        description: Text("Les tailles sont mesurées en arrière-plan ; revenez après la mesure complète.")
                    )
                }
                ForEach(groups) { group in
                    NavigationLink {
                        DuplicateGroupView(group: group) {
                            Task { await load() }
                        }
                    } label: {
                        DuplicateRow(group: group)
                    }
                }
            } header: {
                if !groups.isEmpty {
                    Text("\(groups.count) groupes · \(DisplayFormat.byteCount(totalReclaimable)) en double")
                        .textCase(nil)
                }
            } footer: {
                Text("Mêmes dimensions, même seconde de prise de vue et même taille : très probablement identiques. L'app ne compare pas encore les octets, vérifiez donc avant de confirmer. Supprimer un exemplaire le retire aussi de ses albums.")
            }
        }
        .navigationTitle("Doublons probables")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !groups.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Tout résoudre") {
                        isConfirmingAll = true
                    }
                }
            }
        }
        .task(id: environment.sizing.revision) {
            await load()
        }
        .confirmationDialog(
            "Appliquer les suggestions à \(groups.count) groupes ?",
            isPresented: $isConfirmingAll,
            titleVisibility: .visible
        ) {
            Button("Appliquer", role: .destructive) {
                Task { await applyAll() }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Dans chaque groupe, l'exemplaire déjà conservé, sinon le favori, sinon le premier est gardé. Les autres vont dans la sélection à supprimer : rien n'est supprimé avant votre confirmation.")
        }
    }

    private var totalReclaimable: Int64 {
        groups.reduce(0) { $0 + $1.reclaimableBytes }
    }

    private func load() async {
        isLoading = true
        groups = (try? await environment.store.duplicateGroups()) ?? []
        isLoading = false
    }

    private func applyAll() async {
        for group in groups {
            await environment.resolve(group, keeping: group.suggestedKeeper)
        }
        await load()
    }
}

private struct DuplicateRow: View {
    let group: DuplicateGroup

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: -14) {
                ForEach(Array(group.members.prefix(3))) { member in
                    AssetImageView(id: member.id, pointSize: CGSize(width: 120, height: 120))
                        .frame(width: 56, height: 56)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color(.systemBackground), lineWidth: 2))
                }
            }
            .frame(width: 100, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(group.members.count) exemplaires")
                    .font(.headline)
                Text(verbatim: detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let first = group.members[0].asset
        var parts: [String] = []
        if first.mediaKind == .video {
            parts.append(String(localized: "Vidéo"))
        }
        if let date = first.creationDate {
            parts.append(DisplayFormat.shortDate(date))
        }
        parts.append(String(localized: "\(DisplayFormat.byteCount(group.reclaimableBytes)) en double"))
        return parts.joined(separator: " · ")
    }
}

/// Détail d'un groupe : on choisit l'exemplaire à garder, les autres sont marqués « à supprimer ».
struct DuplicateGroupView: View {
    let group: DuplicateGroup
    let onResolved: () -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var keeper: AssetID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Touchez l'exemplaire à conserver. Par défaut : celui déjà conservé, sinon le favori, sinon le premier.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                    ForEach(group.members) { member in
                        cell(member)
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("\(group.members.count) exemplaires")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button {
                Task {
                    await environment.resolve(group, keeping: selectedKeeper)
                    onResolved()
                    dismiss()
                }
            } label: {
                Label("Garder celui-ci, marquer les \(group.members.count - 1) autres", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }

    private var selectedKeeper: AssetID { keeper ?? group.suggestedKeeper }

    private func cell(_ member: DuplicateMember) -> some View {
        let isKept = member.id == selectedKeeper
        return Button {
            keeper = member.id
        } label: {
            VStack(spacing: 6) {
                AssetImageView(id: member.id, pointSize: CGSize(width: 300, height: 300))
                    .frame(height: 170)
                    .frame(maxWidth: .infinity)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: isKept ? "checkmark.circle.fill" : "trash.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, isKept ? Color.green : Color.red)
                            .padding(6)
                    }
                    .overlay(alignment: .bottomLeading) {
                        MediaBadge(asset: member.asset).padding(6)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(isKept ? Color.green : Color.clear, lineWidth: 3)
                    )
                HStack(spacing: 4) {
                    if member.asset.isFavorite {
                        Image(systemName: "heart.fill").foregroundStyle(.pink)
                    }
                    Text(verbatim: DisplayFormat.photoDate(member.asset.creationDate))
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isKept ? Text("Exemplaire conservé") : Text("Exemplaire à supprimer"))
        .accessibilityHint(Text("Touchez pour conserver celui-ci"))
    }
}
