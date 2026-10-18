import Foundation

/// Sous-types d'un asset utiles au tri, indépendants de PhotoKit.
public struct AssetSubtypes: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Capture d'écran, d'après les métadonnées système (`PHAssetMediaSubtype.photoScreenshot`).
    public static let screenshot = AssetSubtypes(rawValue: 1 << 0)
    /// Live Photo : l'asset regroupe une image et une vidéo associées.
    public static let livePhoto = AssetSubtypes(rawValue: 1 << 1)
    public static let hdr = AssetSubtypes(rawValue: 1 << 2)
    public static let panorama = AssetSubtypes(rawValue: 1 << 3)
    public static let depthEffect = AssetSubtypes(rawValue: 1 << 4)
    /// Image représentative d'une rafale.
    public static let burst = AssetSubtypes(rawValue: 1 << 5)
}

/// Miroir minimal d'un asset de la photothèque. Ne contient aucun pixel ni texte extrait.
public struct AssetSummary: Sendable, Hashable, Identifiable {
    public let id: AssetID
    public let creationDate: Date?
    public let modificationDate: Date?
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let subtypes: AssetSubtypes
    public let burstIdentifier: String?
    public let isFavorite: Bool
    public let mediaKind: MediaKind
    /// Durée en secondes (vidéos uniquement).
    public let duration: TimeInterval?
    /// Taille totale des fichiers en octets, si elle a été mesurée.
    public let byteSize: Int64?

    public init(
        id: AssetID,
        creationDate: Date?,
        modificationDate: Date? = nil,
        pixelWidth: Int,
        pixelHeight: Int,
        subtypes: AssetSubtypes = [],
        burstIdentifier: String? = nil,
        isFavorite: Bool = false,
        mediaKind: MediaKind = .image,
        duration: TimeInterval? = nil,
        byteSize: Int64? = nil
    ) {
        self.id = id
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.subtypes = subtypes
        self.burstIdentifier = burstIdentifier
        self.isFavorite = isFavorite
        self.mediaKind = mediaKind
        self.duration = duration
        self.byteSize = byteSize
    }

    /// Date utilisée pour l'ordre des piles. Les photos sans date de création sont placées à la fin.
    public var sortDate: Date {
        creationDate ?? Date(timeIntervalSince1970: 0)
    }

    public var sortKey: SortKey {
        SortKey(date: sortDate.timeIntervalSince1970, id: id)
    }

    /// Empreinte de contenu servant à détecter une modification de l'image (retouche,
    /// recadrage, changement de ressources). Elle n'est pas une preuve d'identité binaire.
    ///
    /// Les favoris et l'appartenance aux albums en sont volontairement exclus : ce sont
    /// des métadonnées qui n'invalident pas une analyse visuelle.
    public var contentFingerprint: String {
        let modification = modificationDate.map { String(format: "%.3f", $0.timeIntervalSince1970) } ?? "-"
        let base = "\(modification)|\(pixelWidth)x\(pixelHeight)|\(subtypes.rawValue)"
        // Le format des images ne change pas : leurs analyses déjà enregistrées restent valables.
        return mediaKind == .video ? base + "|video|\(Int(duration ?? 0))" : base
    }
}

/// Clé d'ordre d'une pile de tri : date décroissante puis identifiant décroissant.
public struct SortKey: Sendable, Hashable {
    public let date: Double
    public let id: AssetID

    public init(date: Double, id: AssetID) {
        self.date = date
        self.id = id
    }
}
