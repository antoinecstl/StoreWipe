import Foundation

/// Nature d'un élément de la photothèque.
public enum MediaKind: Int, Sendable, Hashable, CaseIterable {
    case image = 0
    case video = 1
}

/// Taille des fichiers de la photothèque : part mesurée et total.
public struct SizeCoverage: Sendable, Hashable {
    public var measured: Int
    public var total: Int

    public init(measured: Int = 0, total: Int = 0) {
        self.measured = measured
        self.total = total
    }

    public var isComplete: Bool { total > 0 && measured >= total }
    public var fraction: Double { total > 0 ? Double(measured) / Double(total) : 0 }
}

/// Effectif et volume d'un ensemble de fichiers dont la taille est connue.
public struct SizeSummary: Sendable, Hashable {
    public var count: Int
    public var bytes: Int64

    public init(count: Int = 0, bytes: Int64 = 0) {
        self.count = count
        self.bytes = bytes
    }
}

/// Fichier volumineux avec sa décision courante (`.unreviewed` si aucune).
public struct LargeAsset: Sendable, Hashable, Identifiable {
    public let asset: AssetSummary
    public let decision: Decision

    public init(asset: AssetSummary, decision: Decision) {
        self.asset = asset
        self.decision = decision
    }

    public var id: AssetID { asset.id }
}

/// Mesure de la taille des fichiers d'origine, sur l'appareil.
public protocol AssetSizing: Sendable {
    /// Taille totale en octets des ressources de chaque élément. Un élément dont la taille est
    /// inconnue (par exemple uniquement dans iCloud sans information) est simplement absent du résultat.
    func byteSizes(for ids: [AssetID]) async -> [AssetID: Int64]
}

/// Exemplaire d'un groupe de doublons probables.
public struct DuplicateMember: Sendable, Hashable, Identifiable {
    public let asset: AssetSummary
    public let decision: Decision

    public init(asset: AssetSummary, decision: Decision) {
        self.asset = asset
        self.decision = decision
    }

    public var id: AssetID { asset.id }
}

/// Photos ou vidéos qui ont mêmes dimensions, même date de création à la seconde et même taille
/// en octets. C'est un indice fort mais pas une preuve : une comparaison d'empreintes est prévue.
public struct DuplicateGroup: Sendable, Hashable, Identifiable {
    public let members: [DuplicateMember]

    public init(members: [DuplicateMember]) {
        self.members = members
    }

    public var id: AssetID { suggestedKeeper }

    /// Exemplaire proposé à la conservation. Règle affichée : déjà conservé, puis favori,
    /// puis le premier dans l'ordre des identifiants.
    public var suggestedKeeper: AssetID {
        let ordered = members.sorted { lhs, rhs in
            let left = (lhs.decision == .kept ? 0 : 1, lhs.asset.isFavorite ? 0 : 1, lhs.asset.id.rawValue)
            let right = (rhs.decision == .kept ? 0 : 1, rhs.asset.isFavorite ? 0 : 1, rhs.asset.id.rawValue)
            return left < right
        }
        return ordered[0].asset.id
    }

    /// Volume que libérerait la suppression de tous les exemplaires sauf un (si les tailles sont connues).
    public var reclaimableBytes: Int64 {
        let size = members.first?.asset.byteSize ?? 0
        return size * Int64(max(0, members.count - 1))
    }
}
