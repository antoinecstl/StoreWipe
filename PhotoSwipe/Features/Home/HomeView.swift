import PhotoSwipeCore
import PhotoSwipeFeatures
import SwiftUI

/// Destinations de navigation depuis l'accueil.
enum Route: Hashable {
    case months
    case sort(SessionScope)
    case resume
}

/// Accueil épuré : une action principale, quelques raccourcis, la sélection en attente.
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
                Section {
                    CountRow(title: "Photos à supprimer", systemImage: "trash", count: counts.markedForDeletion)
                } header: {
                    Text("Sélection à supprimer")
                } footer: {
                    Text("Aucune photo n'est supprimée tant que vous n'avez pas confirmé cette sélection.")
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
                title: "Commencer le tri",
                subtitle: Text("\(overview.remainingToSort) photos à trier"),
                systemImage: "play.fill",
                style: .prominent
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
            SortingScreen(source: .scope(scope)) { path.removeAll() }
        case .resume:
            SortingScreen(source: .resume) { path.removeAll() }
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
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.bold())
                if let subtitle {
                    subtitle
                        .font(.subheadline)
                        .opacity(0.9)
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
                .fill(style == .prominent ? Color.accentColor : Color(.secondarySystemGroupedBackground))
        )
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(action != nil ? .isButton : [])
    }
}
