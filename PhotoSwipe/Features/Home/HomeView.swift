import PhotoSwipeCore
import PhotoSwipeFeatures
import SwiftUI

/// Destinations de navigation depuis l'accueil.
enum Route: Hashable {
    case months
    case sort(SessionScope)
    case resume
    case deletion
}

/// Accueil épuré : une action principale avec la progression, la sélection en attente,
/// les catégories reconnues sans analyse et quelques raccourcis.
struct HomeView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var path: [Route] = []
    @State private var isShowingSettings = false

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
                subtitle: Text(DisplayFormat.scopeTitle(resumable.record.scope)) + Text(verbatim: " · ") + Text("\(resumable.remaining) restantes"),
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

    @ViewBuilder
    private var categoriesSection: some View {
        if overview.screenshotsToSort > 0 {
            Section {
                NavigationLink(value: Route.sort(SessionScope(filter: .screenshots))) {
                    CountRow(title: "Captures d'écran", systemImage: "camera.viewfinder", count: overview.screenshotsToSort)
                }
            } header: {
                Text("Par catégorie")
            } footer: {
                Text("Détectées par iOS, sans analyse de vos images. D'autres catégories (documents, reçus…) arriveront plus tard.")
            }
        }
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
        }
    }
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
