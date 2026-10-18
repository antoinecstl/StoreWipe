import PhotoSwipeCore
import PhotoSwipeFeatures
import SwiftUI

/// Destinations de navigation depuis l'accueil.
enum Route: Hashable {
    case months
    case sort(SessionScope)
    case resume
    case deletion
    case newCategory
    case largeFiles
    case duplicates
}

/// Accueil épuré : une action principale avec la progression, la sélection en attente,
/// les catégories reconnues sans analyse et quelques raccourcis.
struct HomeView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var path: [Route] = []
    @State private var isShowingSettings = false
    @State private var pendingBulk: BulkTarget?

    private var overview: LibraryOverviewModel { environment.overview }
    private var counts: DecisionCounts { overview.counts }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    primaryCard
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                notices
                deletionSection
                freeUpSection
                categoriesSection
                Section("Trier autrement") {
                    NavigationLink(value: Route.months) {
                        Label("Trier par mois", systemImage: "calendar")
                    }
                    if counts.deferred > 0 {
                        NavigationLink(value: Route.sort(SessionScope(filter: .all, pool: .deferredOnly))) {
                            CountRow(title: "Photos passées", systemImage: "forward", count: counts.deferred)
                        }
                    }
                    if counts.kept > 0 {
                        NavigationLink(value: Route.sort(SessionScope(filter: .all, pool: .keptReview))) {
                            CountRow(title: "Revoir les photos conservées", systemImage: "checkmark.circle", count: counts.kept)
                        }
                    }
                }
                syncStatus
            }
            .navigationTitle("PhotoSwipe")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Label("Réglages", systemImage: "gearshape")
                    }
                }
            }
            .navigationDestination(for: Route.self) { route in
                destination(for: route)
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsView()
            }
            .refreshable {
                environment.sync.requestSync()
                await overview.refresh()
            }
            // Rafraîchissement différé pendant l'indexation (anti-rebond par annulation de tâche).
            .task(id: environment.sync.revision) {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await overview.refresh()
                environment.resumeBackgroundWork()
            }
            .task(id: environment.analysis.revision) {
                await overview.refresh()
            }
            .confirmationDialog(
                "Marquer \(pendingBulk?.count ?? 0) photos ?",
                isPresented: Binding(get: { pendingBulk != nil }, set: { if !$0 { pendingBulk = nil } }),
                titleVisibility: .visible,
                presenting: pendingBulk
            ) { target in
                Button("Tout marquer à supprimer", role: .destructive) {
                    Task { await environment.markAllForDeletion(filter: target.filter) }
                }
                Button("Annuler", role: .cancel) {}
            } message: { target in
                Text("« \(target.title) » : \(target.count) photos iront dans la sélection à supprimer. Rien n'est supprimé : vous reverrez la sélection et pourrez en retirer avant de confirmer.")
            }
            .onChange(of: path) { _, newPath in
                if newPath.isEmpty {
                    Task { await overview.refresh() }
                }
            }
        }
    }

    /// Part des photos déjà tranchées (conservées ou à supprimer). Les photos passées restent à trier.
    private var sortedFraction: Double? {
        guard counts.totalAccessible > 0 else { return nil }
        let sorted = counts.totalAccessible - overview.remainingToSort
        return Double(sorted) / Double(counts.totalAccessible)
    }

    // MARK: - Action principale

    @ViewBuilder
    private var primaryCard: some View {
        if let resumable = overview.resumable {
            PrimaryActionCard(
                title: "Reprendre le tri",
                subtitle: Text(DisplayFormat.scopeTitle(resumable.record.scope, categories: overview.categories.map(\.category))) + Text(verbatim: " · ") + Text("\(resumable.remaining) restantes"),
                systemImage: "play.fill",
                style: .prominent
            ) {
                path.append(.resume)
            }
        } else if !overview.hasLoaded {
            PrimaryActionCard(title: "Chargement…", subtitle: nil, systemImage: "hourglass", style: .informational, action: nil)
        } else if overview.remainingToSort > 0 {
            PrimaryActionCard(
                title: counts.unreviewed == counts.totalAccessible ? "Commencer le tri" : "Continuer le tri",
                subtitle: Text("\(overview.remainingToSort) photos à trier"),
                systemImage: "play.fill",
                style: .prominent,
                progress: sortedFraction
            ) {
                path.append(.sort(.everything))
            }
        } else if environment.sync.phase == .running {
            PrimaryActionCard(
                title: "Préparation de vos photos…",
                subtitle: Text("Vous pourrez commencer dans un instant."),
                systemImage: "hourglass",
                style: .informational,
                action: nil
            )
        } else if counts.totalAccessible == 0 {
            if environment.authorization == .limited {
                PrimaryActionCard(
                    title: "Aucune photo autorisée",
                    subtitle: Text("Autorisez des photos pour commencer le tri."),
                    systemImage: "photo.on.rectangle",
                    style: .informational,
                    action: nil
                )
            } else {
                PrimaryActionCard(
                    title: "Aucune photo",
                    subtitle: Text("Votre photothèque ne contient pas de photo à trier."),
                    systemImage: "photo.on.rectangle",
                    style: .informational,
                    action: nil
                )
            }
        } else {
            PrimaryActionCard(
                title: "Tout est trié",
                subtitle: Text("Les nouvelles photos apparaîtront ici."),
                systemImage: "checkmark.seal",
                style: .informational,
                action: nil
            )
        }
    }

    // MARK: - Sélection et catégories

    @ViewBuilder
    private var deletionSection: some View {
        Section {
            if counts.markedForDeletion > 0 {
                NavigationLink(value: Route.deletion) {
                    HStack(spacing: 14) {
                        Image(systemName: "trash.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Color.red.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(counts.markedForDeletion) photos à supprimer")
                                .font(.headline)
                            Text("Revoir la sélection, puis supprimer")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Label {
                    Text("Aucune photo en attente de suppression.")
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Suppression")
        } footer: {
            Text("Un swipe ne supprime rien. Vous confirmez ici, puis iOS demande une dernière validation. Les photos restent récupérables 30 jours dans « Supprimés récemment ».")
        }
    }

    /// Raccourcis pour libérer de la place : fichiers les plus lourds et doublons probables.
    @ViewBuilder
    private var freeUpSection: some View {
        Section {
            NavigationLink(value: Route.largeFiles) {
                Label("Gros fichiers", systemImage: "externaldrive")
            }
            NavigationLink(value: Route.duplicates) {
                Label("Doublons probables", systemImage: "square.on.square")
            }
        } header: {
            Text("Libérer de la place")
        } footer: {
            if environment.sizing.phase == .running {
                Text("Mesure de la taille des fichiers en cours : \(environment.sizing.coverage.measured) sur \(environment.sizing.coverage.total).")
            }
        }
    }

    @ViewBuilder
    private var categoriesSection: some View {
        Section {
            if environment.settings.analysisEnabled {
                analysisStatus
            } else {
                analysisIntro
            }
            if overview.screenshotsToSort > 0 {
                NavigationLink(value: Route.sort(SessionScope(filter: .screenshots))) {
                    CountRow(title: "Captures d'écran", systemImage: "camera.viewfinder", count: overview.screenshotsToSort)
                }
                .contextMenu {
                    bulkButton(title: String(localized: "Captures d'écran"), filter: .screenshots, count: overview.screenshotsToSort)
                }
                .swipeActions(edge: .trailing) {
                    bulkButton(title: String(localized: "Captures d'écran"), filter: .screenshots, count: overview.screenshotsToSort)
                        .tint(.red)
                }
            }
            if overview.videosToSort > 0 {
                NavigationLink(value: Route.sort(SessionScope(filter: .videos))) {
                    CountRow(title: "Vidéos", systemImage: "video", count: overview.videosToSort)
                }
                .contextMenu {
                    bulkButton(title: String(localized: "Vidéos"), filter: .videos, count: overview.videosToSort)
                }
                .swipeActions(edge: .trailing) {
                    bulkButton(title: String(localized: "Vidéos"), filter: .videos, count: overview.videosToSort)
                        .tint(.red)
                }
            }
            ForEach(visibleCategories) { summary in
                NavigationLink(value: Route.sort(SessionScope(filter: .category(summary.category.key)))) {
                    CountRow(
                        title: LocalizedStringKey(summary.category.name),
                        systemImage: summary.category.symbol,
                        count: summary.toSort
                    )
                }
                .contextMenu {
                    if summary.toSort > 0 {
                        bulkButton(title: summary.category.name, filter: .category(summary.category.key), count: summary.toSort)
                    }
                    if !summary.category.isBuiltIn {
                        Button("Supprimer cette catégorie", role: .destructive) {
                            Task { await environment.deleteCategory(summary.category) }
                        }
                    }
                }
                .swipeActions(edge: .trailing) {
                    if summary.toSort > 0 {
                        bulkButton(title: summary.category.name, filter: .category(summary.category.key), count: summary.toSort)
                            .tint(.red)
                    }
                }
            }
            if environment.settings.analysisEnabled {
                NavigationLink(value: Route.newCategory) {
                    Label("Créer une catégorie", systemImage: "plus.circle")
                }
            }
        } header: {
            Text("Tri intelligent")
        } footer: {
            Text("Tout est analysé sur cet iPhone, rien n'est envoyé. Appui long ou glissement sur une catégorie pour tout marquer « à supprimer » : vous revoyez et confirmez ensuite la sélection.")
        }
    }

    /// Catégories à afficher : celles qui ont des photos à trier, et toutes celles de l'utilisateur.
    private var visibleCategories: [LibraryOverviewModel.CategorySummary] {
        overview.categories.filter { $0.toSort > 0 || !$0.category.isBuiltIn }
    }

    private func bulkButton(title: String, filter: SessionScope.Filter, count: Int) -> some View {
        Button {
            pendingBulk = BulkTarget(title: title, filter: filter, count: count)
        } label: {
            Label("Tout marquer à supprimer", systemImage: "trash")
        }
    }

    private var analysisIntro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Reconnaître mes photos", systemImage: "sparkles")
                .font(.headline)
            Text("PhotoSwipe peut repérer sur votre iPhone les documents, reçus, photos peu réussies, ou ce que vous choisissez (animaux, repas…), et vous les proposer par pile.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Activer l'analyse") {
                environment.setAnalysisEnabled(true)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var analysisStatus: some View {
        let analysis = environment.analysis
        let progress = analysis.progress
        VStack(alignment: .leading, spacing: 8) {
            switch analysis.phase {
            case .running:
                Label("Analyse en cours", systemImage: "wand.and.stars")
                    .font(.subheadline.weight(.semibold))
                ProgressView(value: progress.fraction)
                Text("\(progress.analyzed) sur \(progress.total) photos")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            case .paused:
                Label("Analyse en pause", systemImage: "pause.circle")
                    .font(.subheadline.weight(.semibold))
                Text("Mode économie d'énergie ou iPhone chaud : elle reprendra d'elle-même.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .finished:
                Label("Analyse terminée", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                Text("\(progress.analyzed) sur \(progress.total) photos analysées")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                if analysis.skippedCount > 0 {
                    Text("\(analysis.skippedCount) photos ignorées (uniquement dans iCloud ou illisibles).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .idle:
                Label("Analyse arrêtée", systemImage: "stop.circle")
                    .font(.subheadline.weight(.semibold))
                if progress.total > 0 {
                    Text("\(progress.analyzed) sur \(progress.total) photos analysées")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button("Reprendre l'analyse") {
                    environment.resumeAnalysisIfNeeded()
                }
                .font(.footnote)
            }
            Button("Désactiver l'analyse", role: .destructive) {
                environment.setAnalysisEnabled(false)
            }
            .font(.footnote)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Avertissements

    @ViewBuilder
    private var notices: some View {
        if environment.storageIssue == .cannotOpenDatabase {
            Section {
                Label {
                    Text("Vos décisions ne peuvent pas être enregistrées sur cet iPhone pour le moment. Redémarrez l'app ; si le problème persiste, effacez les données de l'app dans les Réglages.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        if environment.authorization == .limited {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Accès limité", systemImage: "photo.badge.checkmark")
                        .font(.headline)
                    Text("PhotoSwipe ne voit que les photos que vous avez autorisées.")
                        .foregroundStyle(.secondary)
                    if environment.canManageLimitedSelection {
                        Button("Modifier la sélection") {
                            Task { await environment.manageLimitedSelection() }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        if environment.sync.lastPlan?.purgeSuspended == true {
            Section {
                Label {
                    Text("De nombreuses photos semblent avoir disparu de la photothèque. Par précaution, leurs décisions sont conservées.")
                } icon: {
                    Image(systemName: "info.circle")
                }
            }
        }
        if environment.sync.phase == .failed {
            Section {
                Label {
                    Text("La lecture de la photothèque a échoué. Tirez vers le bas pour réessayer.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
            }
        }
    }

    @ViewBuilder
    private var syncStatus: some View {
        if environment.sync.phase == .running {
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Lecture de la photothèque… \(environment.sync.processedCount) photos lues")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .months:
            MonthListView { path.append($0) }
        case .sort(let scope):
            SortingScreen(source: .scope(scope), onExit: { path.removeAll() }, onReviewSelection: { path = [.deletion] })
        case .resume:
            SortingScreen(source: .resume, onExit: { path.removeAll() }, onReviewSelection: { path = [.deletion] })
        case .deletion:
            DeletionReviewView()
        case .newCategory:
            CategoryEditorView()
        case .largeFiles:
            LargeFilesView()
        case .duplicates:
            DuplicatesView()
        }
    }
}

/// Catégorie ou pile dont l'utilisateur veut tout marquer « à supprimer » (après confirmation).
struct BulkTarget: Identifiable {
    let title: String
    let filter: SessionScope.Filter
    let count: Int
    var id: String { title }
}

struct CountRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let count: Int

    var body: some View {
        LabeledContent {
            Text(count, format: .number)
                .monospacedDigit()
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}

struct PrimaryActionCard: View {
    enum Style {
        case prominent
        case informational
    }

    let title: LocalizedStringKey
    let subtitle: Text?
    let systemImage: String
    let style: Style
    var progress: Double?
    let action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2)
                .frame(width: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title3.bold())
                if let subtitle {
                    subtitle
                        .font(.subheadline)
                        .opacity(0.9)
                }
                if let progress, style == .prominent {
                    ProgressView(value: min(max(progress, 0), 1))
                        .tint(.white)
                        .padding(.top, 2)
                        .accessibilityLabel(Text("Progression du tri"))
                        .accessibilityValue(Text(progress, format: .percent.precision(.fractionLength(0))))
                }
            }
            Spacer(minLength: 0)
            if action != nil {
                Image(systemName: "chevron.right")
                    .font(.headline)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(style == .prominent ? Color.white : Color.primary)
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(style == .prominent ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)))
        )
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(action != nil ? .isButton : [])
    }
}
