import Foundation
import Observation
import OSLog
import PhotoSwipeCore
import PhotoSwipeFeatures
import PhotoSwipeStore

/// Problème de stockage local détecté au lancement.
enum StorageIssue: Equatable {
    /// La base n'a pas pu être ouverte : l'app fonctionne avec une base en mémoire
    /// et prévient que les décisions ne seront pas conservées.
    case cannotOpenDatabase
}

/// Racine de composition : crée et relie les services de l'application.
@MainActor
@Observable
final class AppEnvironment {
    let store: PhotoSwipeStore
    let library: any PhotoLibraryService
    let images: any AssetImageProviding
    let settings: AppSettings
    let sync: LibrarySyncCoordinator
    let overview: LibraryOverviewModel
    let storageIssue: StorageIssue?
    let isDemoMode: Bool
    private(set) var authorization: LibraryAuthorization

    /// Délai minimal entre deux synchronisations complètes déclenchées par le retour au premier plan.
    private static let foregroundResyncInterval: TimeInterval = 300

    init(
        store: PhotoSwipeStore,
        library: any PhotoLibraryService,
        images: any AssetImageProviding,
        settings: AppSettings,
        storageIssue: StorageIssue?,
        isDemoMode: Bool
    ) {
        self.store = store
        self.library = library
        self.images = images
        self.settings = settings
        self.storageIssue = storageIssue
        self.isDemoMode = isDemoMode
        self.sync = LibrarySyncCoordinator(library: library, store: store)
        self.overview = LibraryOverviewModel(store: store)
        self.authorization = library.authorizationStatus()
    }

    static func makeDefault() -> AppEnvironment {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "PhotoSwipeDemoLibrary") {
            return makeDemo()
        }
        #endif
        return makeLive()
    }

    private static func makeLive() -> AppEnvironment {
        let (store, issue) = openStore(fileName: "PhotoSwipe.sqlite")
        return AppEnvironment(
            store: store,
            library: PhotoKitLibraryService(),
            images: PhotoKitImageProvider(),
            settings: AppSettings(defaults: .standard),
            storageIssue: issue,
            isDemoMode: false
        )
    }

    #if DEBUG
    /// Photothèque fictive pour le simulateur, les aperçus et les tests d'interface.
    /// Arguments : `-PhotoSwipeDemoLibrary YES`, et facultativement
    /// `-PhotoSwipeDemoAuthorization limited|denied|restricted`.
    private static func makeDemo() -> AppEnvironment {
        let assets = SampleLibrary.assets(count: 180, months: 8, idPrefix: "demo")
        let requested: LibraryAuthorization
        switch UserDefaults.standard.string(forKey: "PhotoSwipeDemoAuthorization") {
        case "limited": requested = .limited
        case "denied": requested = .denied
        case "restricted": requested = .restricted
        default: requested = .full
        }
        let library = InMemoryPhotoLibrary(
            assets: assets,
            authorization: requested == .restricted ? .restricted : .notDetermined,
            authorizationOnRequest: requested
        )
        library.setLimitedSelection(Set(assets.prefix(40).map(\.id)), notify: false)
        let (store, issue) = openStore(fileName: "PhotoSwipe-demo.sqlite")
        return AppEnvironment(
            store: store,
            library: library,
            images: DemoImageProvider(),
            settings: AppSettings(defaults: .standard, keyPrefix: "demo."),
            storageIssue: issue,
            isDemoMode: true
        )
    }
    #endif

    private static func openStore(fileName: String) -> (PhotoSwipeStore, StorageIssue?) {
        do {
            let url = try StorageLocation.databaseURL(fileName: fileName)
            return (try PhotoSwipeStore(url: url), nil)
        } catch {
            Logger.storage.error("Base locale indisponible : \(String(describing: error), privacy: .public)")
            do {
                return (try PhotoSwipeStore(url: nil), .cannotOpenDatabase)
            } catch {
                fatalError("SQLite en mémoire indisponible : \(error)")
            }
        }
    }

    // MARK: - Cycle de vie et autorisation

    /// Appelé à chaque retour au premier plan : l'autorisation peut avoir changé dans Réglages.
    func handleBecameActive() {
        let previous = authorization
        authorization = library.authorizationStatus()
        guard authorization.allowsReading, settings.hasCompletedOnboarding else { return }
        sync.startObservingChanges()
        let isStale = sync.lastCompletedAt.map { Date().timeIntervalSince($0) > Self.foregroundResyncInterval } ?? true
        if previous != authorization || isStale {
            sync.requestSync()
        }
        Task { await overview.refresh() }
    }

    /// Demande l'accès (la fenêtre système n'apparaît que si l'état est indéterminé).
    func requestAuthorization() async {
        authorization = await library.requestAuthorization()
        if authorization.allowsReading {
            sync.startObservingChanges()
            sync.requestSync()
        }
    }

    var canManageLimitedSelection: Bool {
        authorization == .limited && library is LimitedSelectionManaging
    }

    /// Ouvre le sélecteur système des photos autorisées. La synchronisation suit
    /// automatiquement via la notification de changement de la photothèque.
    func manageLimitedSelection() async {
        guard let manager = library as? LimitedSelectionManaging else { return }
        await manager.presentLimitedLibraryPicker()
        sync.requestSync()
    }

    // MARK: - Sessions

    func openSession(scope: SessionScope) async throws -> SortingSessionModel {
        try await SessionLauncher.open(scope: scope, store: store)
    }

    func resumeActiveSession() async throws -> SortingSessionModel? {
        try await SessionLauncher.resumeActive(store: store)
    }

    // MARK: - Réinitialisation

    /// Remet toutes les photos à l'état « non triée ». L'index est conservé.
    func resetDecisions() async throws {
        try await store.resetDecisions()
        await overview.refresh()
    }

    /// Efface index, décisions, sessions, caches et réglages. Ne touche à aucune photo.
    func eraseAllData() async throws {
        sync.stop()
        await sync.waitUntilIdle()
        try await store.eraseAll()
        images.reset()
        settings.reset()
        await overview.refresh()
        Logger.storage.info("Données de l'application effacées")
    }
}

/// Emplacement des données locales.
enum StorageLocation {
    /// `Application Support/PhotoSwipe/<fileName>`, exclu de la sauvegarde iCloud :
    /// les identifiants PhotoKit sont propres à cet appareil.
    static func databaseURL(fileName: String) throws -> URL {
        let fileManager = FileManager.default
        var directory = try fileManager
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("PhotoSwipe", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        return directory.appendingPathComponent(fileName)
    }
}

extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "PhotoSwipe"

    /// Les journaux ne contiennent ni image, ni identifiant de photo, ni texte extrait.
    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let library = Logger(subsystem: subsystem, category: "library")
}
