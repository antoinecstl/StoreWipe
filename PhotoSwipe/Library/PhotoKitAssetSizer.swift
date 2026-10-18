import Foundation
import Photos
import PhotoSwipeCore

/// Mesure la taille des fichiers d'origine à partir des métadonnées des ressources PhotoKit.
///
/// Aucun fichier n'est lu ni téléchargé. La clé `fileSize` n'est pas documentée par Apple : si elle
/// n'est pas disponible, la taille reste inconnue et l'app n'affiche alors aucun volume pour cet élément.
struct PhotoKitAssetSizer: AssetSizing {
    func byteSizes(for ids: [AssetID]) async -> [AssetID: Int64] {
        let identifiers = ids.map(\.rawValue)
        return await Task.detached(priority: .utility) {
            var sizes: [AssetID: Int64] = [:]
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            assets.enumerateObjects { asset, _, _ in
                var total: Int64 = 0
                var isKnown = false
                // Supprimer un élément supprime toutes ses ressources (original, version modifiée, vidéo d'une Live Photo).
                for resource in PHAssetResource.assetResources(for: asset) {
                    if let size = Self.fileSize(of: resource) {
                        total += size
                        isKnown = true
                    }
                }
                if isKnown {
                    sizes[AssetID(asset.localIdentifier)] = total
                }
            }
            return sizes
        }.value
    }

    private static func fileSize(of resource: PHAssetResource) -> Int64? {
        let key = "fileSize"
        guard resource.responds(to: NSSelectorFromString(key)) else { return nil }
        return (resource.value(forKey: key) as? NSNumber)?.int64Value
    }
}
