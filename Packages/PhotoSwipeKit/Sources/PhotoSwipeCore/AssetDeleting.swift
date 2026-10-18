import Foundation

/// Suppression de photos via le système. Volontairement distincte de `PhotoLibraryService` :
/// le moteur de tri n'a aucun accès à cette capacité, seul l'écran de confirmation l'utilise.
public protocol AssetDeleting: Sendable {
    /// Demande au système de supprimer les photos (alerte de confirmation d'iOS).
    /// - Returns: `false` si l'utilisateur a refusé dans l'alerte système (rien n'est supprimé).
    func deleteAssets(_ ids: [AssetID]) async throws -> Bool
}
