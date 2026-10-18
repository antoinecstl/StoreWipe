import PhotoSwipeCore
import PhotoSwipeFeatures
import SwiftUI

/// Doublons : exacts (octets identiques, prouvés par empreinte SHA-256) puis probables (mêmes dimensions,
/// seconde de prise de vue et taille, non vérifiés). Un exemplaire est toujours conservé ; les autres
/// rejoignent la sélection à supprimer, à revoir avant toute suppression.
struct DuplicatesView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var exactGroups: [DuplicateGroup] = []
    @State private var probableGroups: [DuplicateGroup] = []
    @State private var isLoading = true
    @State private var pendingResolution: Resolution?

    private enum Resolution: Identifiable {
        case exact
        case probable
        var id: Int { self == .exact ? 0 : 1 }
    }

    private var scan: DuplicateScanCoordinator { environment.duplicateScan }

    var body: some View {
        List {
            verificationSection
            if !exactGroups.isEmpty {
                Section {
                    ForEach(exactGroups) { group in
                        link(to: group)
                    }
                } header: {
                    HStack {
                        Text("\(exactGroups.count) groupes exacts · \(DisplayFormat.byteCount(reclaimable(exactGroups))) en double")
                            .textCase(nil)
                        Spacer()
                        Button("Tout résoudre") { pendingResolution = .exact }
                            .font(.footnote)
                            .textCase(nil)
                    }
                } footer: {
                    Text("Fichiers strictement identiques, métadonnées comprises (empreinte SHA-256 complète).")
                }
            }
            Section {
                if isLoading && probableGroups.isEmpty {
                    ProgressView()
                } else if probableGroups.isEmpty && exactGroups.isEmpty {
                    ContentUnavailableView(
                        "Aucun doublon trouvé",
                        systemImage: "square.on.square",
                        description: Text("Les tailles sont mesurées en arrière-plan ; lancez ensuite la vérification exacte.")
                    )
                }
                ForEach(probableGroups) { group in
                    link(to: group)
                }
            } header: {
                if !probableGroups.isEmpty {
                    HStack {
                        Text("\(probableGroups.count) groupes probables · \(DisplayFormat.byteCount(reclaimable(probableGroups))) en double")
                            .textCase(nil)
                        Spacer()
                        Button("Tout résoudre") { pendingResolution = .probable }
                            .font(.footnote)
                            .textCase(nil)
                    }
                }
            } footer: {
                if !probableGroups.isEmpty {
                    Text("Mêmes dimensions, même seconde de prise de vue et même taille : très probablement identiques, mais non vérifiés octet par octet. Regardez avant de confirmer. Supprimer un exemplaire le retire aussi de ses albums.")
                }
            }
        }
        .navigationTitle("Doublons")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: environment.sizing.revision + scan.revision * 1000) {
            await load()
        }
        .confirmationDialog(
            "Appliquer les suggestions ?",
            isPresented: Binding(get: { pendingResolution != nil }, set: { if !$0 { pendingResolution = nil } }),
            titleVisibility: .visible,
            presenting: pendingResolution
        ) { resolution in
            Button("Appliquer", role: .destructive) {
                Task { await apply(resolution) }
            }
            Button("Annuler", role: .cancel) {}
        } message: { _ in
            Text("Dans chaque groupe, l'exemplaire déjà conservé, sinon le favori, sinon le premier est gardé. Les autres vont dans la sélection à supprimer : rien n'est supprimé avant votre confirmation.")
        }
    }

    // MARK: - Vérification exacte

    @ViewBuilder
    private var verificationSection: some View {
        Section {
            switch scan.phase {
            case .running, .paused:
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(scan.phase == .paused ? "Vérification en pause" : "Vérification en cours")
                            .font(.subheadline.weight(.semibold))
                    }
                    Text("\(scan.processed) fichiers lus")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if scan.isThrottled {
                        Text("Ralentie pour ménager l'iPhone.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button("Arrêter", role: .destructive) {
                        scan.stop()
                    }
                    .font(.footnote)
                }
            case .idle, .finished:
                VStack(alignment: .leading, spacing: 8) {
                    if scan.phase == .finished {
                        Label("Vérification terminée", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                        Text(summary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button(scan.phase == .finished ? "Revérifier" : "Vérifier les doublons exacts") {
                        scan.start()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(environment.sizing.coverage.measured == 0)
                }
            }
        } header: {
            Text("Vérification exacte")
        } footer: {
            Text("Compare les octets (SHA-256) uniquement entre fichiers de même taille. Les photos modifiées, Live Photos, rafales et RAW+JPEG ne sont pas comparées. Tout se passe sur l'iPhone ; un fichier uniquement dans iCloud n'est lu que si vous l'autorisez dans les Réglages.")
        }
    }

    private var summary: String {
        var parts = [String(localized: "\(exactGroups.count) groupes exacts")]
        if scan.ineligible > 0 {
            parts.append(String(localized: "\(scan.ineligible) non comparables"))
        }
        if scan.unverifiable > 0 {
            parts.append(String(localized: "\(scan.unverifiable) non vérifiables (iCloud)"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Données

    private func link(to group: DuplicateGroup) -> some View {
        NavigationLink {
            DuplicateGroupView(group: group) {
                Task { await load() }
            }
        } label: {
            DuplicateRow(group: group)
        }
    }

    private func reclaimable(_ groups: [DuplicateGroup]) -> Int64 {
        groups.reduce(0) { $0 + $1.reclaimableBytes }
    }

    private func load() async {
        isLoading = true
        let store = environment.store
        let exact = (try? await store.exactDuplicateGroups()) ?? []
        let probable = (try? await store.duplicateGroups()) ?? []
        // Un groupe probable déjà couvert par un groupe exact n'est pas montré deux fois.
        let covered = exact.map { Set($0.members.map(\.id)) }
        exactGroups = exact
        probableGroups = probable.filter { group in
            let ids = Set(group.members.map(\.id))
            return !covered.contains { ids.isSubset(of: $0) }
        }
        isLoading = false
    }

    private func apply(_ resolution: Resolution) async {
        let groups = resolution == .exact ? exactGroups : probableGroups
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
                HStack(spacing: 4) {
                    Text("\(group.members.count) exemplaires")
                        .font(.headline)
                    if group.isExact {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .accessibilityLabel(Text("Identiques, vérifié"))
                    }
                }
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
    @State private var preview: AssetSummary?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(
                    group.isExact ? "Octets identiques (SHA-256)" : "Doublons probables, non vérifiés",
                    systemImage: group.isExact ? "checkmark.seal.fill" : "questionmark.circle"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(group.isExact ? Color.green : Color.orange)
                Text("Touchez un exemplaire pour le conserver ; l'œil ouvre l'aperçu. Par défaut : celui déjà conservé, sinon le favori, sinon le premier.")
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
        .fullScreenCover(item: $preview) { asset in
            MediaPreviewScreen(asset: asset)
        }
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
        return VStack(spacing: 6) {
            Button {
                keeper = member.id
            } label: {
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
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isKept ? Text("Exemplaire conservé") : Text("Exemplaire à supprimer"))
            .accessibilityHint(Text("Touchez pour conserver celui-ci"))
            .overlay(alignment: .topLeading) {
                Button {
                    preview = member.asset
                } label: {
                    Image(systemName: "eye.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.55))
                        .padding(6)
                }
                .accessibilityLabel(Text("Aperçu"))
            }
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
}
