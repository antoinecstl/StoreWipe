import PhotoSwipeCore
import SwiftUI

/// Photos et vidéos les plus volumineuses, pour libérer de la place en quelques gestes.
/// Rien n'est supprimé ici : la sélection rejoint « À supprimer », à revoir puis confirmer.
struct LargeFilesView: View {
    @Environment(AppEnvironment.self) private var environment

    enum KindFilter: Hashable {
        case all
        case images
        case videos

        var kind: MediaKind? {
            switch self {
            case .all: nil
            case .images: .image
            case .videos: .video
            }
        }
    }

    private static let thresholdsInMegabytes = [10, 50, 100, 250, 500, 1000]

    @State private var filter: KindFilter = .all
    @State private var thresholdMB = 50
    @State private var items: [LargeAsset] = []
    @State private var summary = SizeSummary()
    @State private var selection: Set<AssetID> = []
    @State private var isLoading = true
    @State private var isConfirming = false
    @State private var lastMarked: Int?

    private struct LoadKey: Hashable {
        let filter: KindFilter
        let threshold: Int
        let revision: Int
        let marked: Int
    }

    private var minBytes: Int64 { Int64(thresholdMB) * 1_000_000 }
    private var coverage: SizeCoverage { environment.sizing.coverage }

    var body: some View {
        List {
            controls
            if !coverage.isComplete && coverage.total > 0 {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: coverage.fraction)
                        Text("Taille mesurée pour \(coverage.measured) éléments sur \(coverage.total). La liste se complète pendant la mesure.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                if isLoading && items.isEmpty {
                    ProgressView()
                } else if items.isEmpty {
                    ContentUnavailableView(
                        "Aucun fichier de cette taille",
                        systemImage: "externaldrive",
                        description: Text("Essayez un seuil plus bas ou attendez la fin de la mesure.")
                    )
                }
                ForEach(items) { entry in
                    Button {
                        toggle(entry.id)
                    } label: {
                        row(entry)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("\(summary.count) fichiers · \(DisplayFormat.byteCount(summary.bytes))")
                    .textCase(nil)
            } footer: {
                if summary.count > items.count {
                    Text("Les \(items.count) plus lourds sont affichés.")
                }
            }
        }
        .navigationTitle("Gros fichiers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(selection.count == items.count && !items.isEmpty ? "Tout désélectionner" : "Tout sélectionner") {
                    if selection.count == items.count {
                        selection = []
                    } else {
                        selection = Set(items.map(\.id))
                    }
                }
                .disabled(items.isEmpty)
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .task(id: LoadKey(filter: filter, threshold: thresholdMB, revision: environment.sizing.revision, marked: lastMarked ?? 0)) {
            await load()
        }
        .confirmationDialog(
            "Marquer \(selection.count) fichiers ?",
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("Marquer à supprimer", role: .destructive) {
                Task { await markSelection() }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Ils iront dans la sélection à supprimer. Rien n'est supprimé : vous la reverrez et confirmerez ensuite.")
        }
    }

    // MARK: - Contrôles

    private var controls: some View {
        Section {
            Picker("Type", selection: $filter) {
                Text("Tout").tag(KindFilter.all)
                Text("Photos").tag(KindFilter.images)
                Text("Vidéos").tag(KindFilter.videos)
            }
            .pickerStyle(.segmented)
            Picker("Taille minimale", selection: $thresholdMB) {
                ForEach(Self.thresholdsInMegabytes, id: \.self) { value in
                    Text(value >= 1000 ? "\(value / 1000) Go" : "\(value) Mo").tag(value)
                }
            }
        }
    }

    private func row(_ entry: LargeAsset) -> some View {
        HStack(spacing: 12) {
            AssetImageView(id: entry.id, pointSize: CGSize(width: 120, height: 120))
                .frame(width: 60, height: 60)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    if entry.asset.mediaKind == .video {
                        Image(systemName: "play.fill")
                            .font(.caption2)
                            .padding(4)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(3)
                            .accessibilityHidden(true)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: DisplayFormat.byteCount(entry.asset.byteSize ?? 0))
                    .font(.headline.monospacedDigit())
                Text(verbatim: subtitle(for: entry))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: selection.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(selection.contains(entry.id) ? Color.accentColor : Color.secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selection.contains(entry.id) ? .isSelected : [])
    }

    private func subtitle(for entry: LargeAsset) -> String {
        var parts: [String] = []
        if entry.asset.mediaKind == .video {
            parts.append(String(localized: "Vidéo"))
            if let duration = entry.asset.duration {
                parts.append(DisplayFormat.duration(duration))
            }
        } else {
            parts.append(String(localized: "Photo"))
        }
        parts.append(DisplayFormat.shortDate(entry.asset.creationDate ?? .distantPast))
        if entry.decision == .kept {
            parts.append(String(localized: "Conservée"))
        }
        return parts.joined(separator: " · ")
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            Button {
                isConfirming = true
            } label: {
                let size = selectedBytes
                Label(
                    selection.isEmpty
                        ? String(localized: "Sélectionnez des fichiers")
                        : String(localized: "Marquer \(selection.count) à supprimer · \(DisplayFormat.byteCount(size))"),
                    systemImage: "trash"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(selection.isEmpty)
            if let lastMarked, lastMarked > 0 {
                Text("\(lastMarked) fichiers ajoutés à la sélection à supprimer.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var selectedBytes: Int64 {
        items.filter { selection.contains($0.id) }.reduce(0) { $0 + ($1.asset.byteSize ?? 0) }
    }

    // MARK: - Données

    private func toggle(_ id: AssetID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let store = environment.store
        items = (try? await store.largestAssets(kind: filter.kind, minBytes: minBytes, limit: 300)) ?? []
        summary = (try? await store.largeSummary(kind: filter.kind, minBytes: minBytes)) ?? SizeSummary()
        selection = selection.intersection(Set(items.map(\.id)))
        await environment.sizing.refreshCoverage()
    }

    private func markSelection() async {
        let ids = Array(selection)
        let count = await environment.markForDeletion(ids)
        selection = []
        lastMarked = count
    }
}
