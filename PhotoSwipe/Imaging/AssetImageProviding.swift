import CoreGraphics
import PhotoSwipeCore
import UIKit

/// Événements de chargement d'une image de la photothèque.
enum AssetImageEvent {
    /// Progression d'un téléchargement iCloud (0…1).
    case progress(Double)
    /// Image disponible ; une version dégradée (basse résolution) peut précéder la version finale.
    case image(UIImage, isDegraded: Bool)
    /// La photo n'est pas sur l'appareil et le téléchargement iCloud n'est pas autorisé.
    case requiresNetwork
    /// La photo n'existe plus ou n'est plus autorisée.
    case unavailable
    case failed
}

/// Chargement des images à une résolution adaptée à l'écran, avec préchargement borné.
/// Aucune copie complète des photos n'est conservée par l'application.
@MainActor
protocol AssetImageProviding: AnyObject {
    func images(for id: AssetID, targetPixelSize: CGSize, allowNetwork: Bool) -> AsyncStream<AssetImageEvent>
    /// Remplace l'ensemble des photos préchargées (fenêtre glissante de quelques photos).
    func updatePrefetch(_ ids: [AssetID], targetPixelSize: CGSize, allowNetwork: Bool)
    /// Vide les caches mémoire.
    func reset()
}

enum DisplayGeometry {
    /// Plafond de résolution demandé, même en zoom, pour borner la mémoire.
    static let maximumPixelDimension: CGFloat = 4096

    /// Taille en pixels à demander pour une zone d'affichage donnée. Les mêmes paramètres
    /// doivent être utilisés pour l'affichage et le préchargement pour profiter du cache.
    static func pixelSize(for pointSize: CGSize, scale: CGFloat, zoomFactor: CGFloat = 1) -> CGSize {
        guard pointSize.width > 0, pointSize.height > 0, scale > 0 else { return .zero }
        var width = (pointSize.width * scale * zoomFactor).rounded()
        var height = (pointSize.height * scale * zoomFactor).rounded()
        let longest = max(width, height)
        if longest > maximumPixelDimension {
            let ratio = maximumPixelDimension / longest
            width = (width * ratio).rounded()
            height = (height * ratio).rounded()
        }
        return CGSize(width: width, height: height)
    }
}
