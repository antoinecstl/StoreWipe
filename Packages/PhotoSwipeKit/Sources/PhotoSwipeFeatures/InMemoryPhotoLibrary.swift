import Foundation
import PhotoSwipeCore
import Synchronization

/// Photothèque simulée, fidèle aux règles de visibilité de PhotoKit :
/// photos masquées exclues de l'énumération, accès limité à une sélection.
/// Utilisée par les tests et par le mode démonstration de l'app (DEBUG).
public final class InMemoryPhotoLibrary: PhotoLibraryService {
    private struct State {
        var assets: [AssetID: AssetSummary] = [:]
        var hidden: Set<AssetID> = []
        var limitedSelection: Set<AssetID> = []
        var authorization: LibraryAuthorization
        var authorizationOnRequest: LibraryAuthorization
        var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
        var enumerationCount = 0
        var userRefusesDeletion = false
        var undeletable: Set<AssetID> = []
    }

    private let state: Mutex<State>

    public init(
        assets: [AssetSummary] = [],
        authorization: LibraryAuthorization = .full,
        authorizationOnRequest: LibraryAuthorization = .full
    ) {
        var initial = State(authorization: authorization, authorizationOnRequest: authorizationOnRequest)
        for asset in assets {
            initial.assets[asset.id] = asset
        }
        state = Mutex(initial)
    }

    // MARK: PhotoLibraryService

    public func authorizationStatus() -> LibraryAuthorization {
        state.withLock { $0.authorization }
    }

    public func requestAuthorization() async -> LibraryAuthorization {
        state.withLock { state in
            if state.authorization == .notDetermined {
                state.authorization = state.authorizationOnRequest
            }
            return state.authorization
        }
    }

    public func assetBatches(batchSize: Int) -> AsyncThrowingStream<[AssetSummary], any Error> {
        let snapshot: [AssetSummary] = state.withLock { state in
            state.enumerationCount += 1
            return Self.visibleAssets(in: state)
        }
        let size = max(1, batchSize)
        return AsyncThrowingStream { continuation in
            var index = 0
            while index < snapshot.count {
                let end = min(index + size, snapshot.count)
                continuation.yield(Array(snapshot[index..<end]))
                index = end
            }
            continuation.finish()
        }
    }

    public func existingAssetIDs(among ids: [AssetID]) async -> Set<AssetID> {
        state.withLock { state in
            Set(ids.filter { id in
                guard state.assets[id] != nil else { return false }
                switch state.authorization {
                case .full: return true
                case .limited: return state.limitedSelection.contains(id)
                case .notDetermined, .restricted, .denied: return false
                }
            })
        }
    }

    public func changeNotifications() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let token = UUID()
        state.withLock { $0.continuations[token] = continuation }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.continuations.removeValue(forKey: token) }
        }
        return stream
    }

    // MARK: Simulation

    public var enumerationCount: Int { state.withLock { $0.enumerationCount } }

    public var allAssetIDs: Set<AssetID> { state.withLock { Set($0.assets.keys) } }

    public func add(_ assets: [AssetSummary], notify: Bool = true) {
        state.withLock { state in
            for asset in assets {
                state.assets[asset.id] = asset
            }
        }
        if notify { notifyChange() }
    }

    /// Simule une suppression faite dans Photos, hors de l'application.
    public func remove(_ ids: [AssetID], notify: Bool = true) {
        state.withLock { state in
            for id in ids {
                state.assets.removeValue(forKey: id)
                state.hidden.remove(id)
                state.limitedSelection.remove(id)
            }
        }
        if notify { notifyChange() }
    }

    public func setHidden(_ ids: [AssetID], hidden: Bool, notify: Bool = true) {
        state.withLock { state in
            if hidden {
                state.hidden.formUnion(ids)
            } else {
                state.hidden.subtract(ids)
            }
        }
        if notify { notifyChange() }
    }

    public func setAuthorization(_ authorization: LibraryAuthorization, notify: Bool = true) {
        state.withLock { $0.authorization = authorization }
        if notify { notifyChange() }
    }

    public func setLimitedSelection(_ ids: Set<AssetID>, notify: Bool = true) {
        state.withLock { $0.limitedSelection = ids }
        if notify { notifyChange() }
    }

    public func notifyChange() {
        let continuations = state.withLock { Array($0.continuations.values) }
        for continuation in continuations {
            continuation.yield()
        }
    }

    /// Simule un refus de l'utilisateur dans l'alerte de suppression d'iOS.
    public func setUserRefusesDeletion(_ refuses: Bool) {
        state.withLock { $0.userRefusesDeletion = refuses }
    }

    /// Photos que le système ne parvient pas à supprimer (suppression partielle).
    public func setUndeletable(_ ids: Set<AssetID>) {
        state.withLock { $0.undeletable = ids }
    }

    private static func visibleAssets(in state: State) -> [AssetSummary] {
        let candidates: [AssetSummary]
        switch state.authorization {
        case .full:
            candidates = Array(state.assets.values)
        case .limited:
            candidates = state.assets.values.filter { state.limitedSelection.contains($0.id) }
        case .notDetermined, .restricted, .denied:
            candidates = []
        }
        return candidates
            .filter { !state.hidden.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.sortDate != rhs.sortDate { return lhs.sortDate > rhs.sortDate }
                return lhs.id.rawValue > rhs.id.rawValue
            }
    }
}

extension InMemoryPhotoLibrary: AssetDeleting {
    public func deleteAssets(_ ids: [AssetID]) async throws -> Bool {
        let confirmed = state.withLock { state -> Bool in
            if state.userRefusesDeletion { return false }
            for id in ids where !state.undeletable.contains(id) {
                state.assets.removeValue(forKey: id)
                state.hidden.remove(id)
                state.limitedSelection.remove(id)
            }
            return true
        }
        if confirmed { notifyChange() }
        return confirmed
    }
}

/// Génère une photothèque fictive déterministe (tests, aperçus, mode démonstration).
public enum SampleLibrary {
    /// `count` photos réparties sur `months` mois, à partir de `newest` en remontant le temps.
    public static func assets(
        count: Int,
        months: Int = 6,
        newest: Date = Date(timeIntervalSince1970: 1_760_000_000),
        idPrefix: String = "sample"
    ) -> [AssetSummary] {
        guard count > 0 else { return [] }
        let span = Double(max(months, 1)) * 30 * 86_400
        let step = span / Double(count)
        return (0..<count).map { index -> AssetSummary in
            let id = AssetID(idPrefix + "-" + String(format: "%05d", index))
            let offset: TimeInterval = -Double(index) * step
            let isPortrait = index % 3 == 0
            let subtypes: AssetSubtypes = index % 7 == 0 ? [.screenshot] : []
            return AssetSummary(
                id: id,
                creationDate: newest.addingTimeInterval(offset),
                pixelWidth: isPortrait ? 3024 : 4032,
                pixelHeight: isPortrait ? 4032 : 3024,
                subtypes: subtypes,
                isFavorite: index % 11 == 0
            )
        }
    }
}
