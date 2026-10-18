import Foundation

/// État d'autorisation d'accès à la photothèque, indépendant de PhotoKit.
public enum LibraryAuthorization: Sendable, Hashable {
    case notDetermined
    /// Contrôle parental ou gestion de l'appareil : l'utilisateur ne peut pas accorder l'accès.
    case restricted
    case denied
    /// Accès limité aux photos choisies par l'utilisateur.
    case limited
    case full

    public var allowsReading: Bool {
        self == .full || self == .limited
    }
}

/// Abstraction de la photothèque. L'implémentation PhotoKit vit dans l'application ;
/// les tests utilisent `InMemoryPhotoLibrary`.
public protocol PhotoLibraryService: Sendable {
    func authorizationStatus() -> LibraryAuthorization

    /// Affiche la demande système si l'état est indéterminé, puis renvoie le nouvel état.
    func requestAuthorization() async -> LibraryAuthorization

    /// Énumère les photos accessibles (hors vidéos et photos masquées) par lots, dans le sens demandé.
    func assetBatches(batchSize: Int, order: SortOrder) -> AsyncThrowingStream<[AssetSummary], any Error>

    /// Parmi `ids`, ceux qui existent encore et sont visibles avec l'autorisation actuelle,
    /// y compris les photos masquées. En accès limité, une photo non autorisée est
    /// indiscernable d'une photo supprimée : cette méthode ne permet donc pas de conclure
    /// à une suppression dans ce mode.
    func existingAssetIDs(among ids: [AssetID]) async -> Set<AssetID>

    /// Émet un événement à chaque changement de la photothèque ou de la sélection autorisée.
    func changeNotifications() -> AsyncStream<Void>
}

extension PhotoLibraryService {
    /// Énumération de la plus récente à la plus ancienne.
    public func assetBatches(batchSize: Int) -> AsyncThrowingStream<[AssetSummary], any Error> {
        assetBatches(batchSize: batchSize, order: .newestFirst)
    }
}
