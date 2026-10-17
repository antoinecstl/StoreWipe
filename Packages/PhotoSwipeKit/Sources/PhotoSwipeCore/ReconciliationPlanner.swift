import Foundation

/// Actions à appliquer à l'index local après une énumération complète de la photothèque.
public struct ReconciliationPlan: Sendable, Equatable {
    /// Photos qui ne sont plus visibles mais dont la suppression n'est pas démontrée :
    /// leurs décisions sont conservées et elles sont exclues des piles.
    public var markInaccessible: [AssetID]
    /// Photos dont l'absence est confirmée en accès complet : leurs données locales sont effacées.
    public var purge: [AssetID]
    /// Vrai si une purge anormalement massive a été suspendue par précaution.
    public var purgeSuspended: Bool

    public init(markInaccessible: [AssetID] = [], purge: [AssetID] = [], purgeSuspended: Bool = false) {
        self.markInaccessible = markInaccessible
        self.purge = purge
        self.purgeSuspended = purgeSuspended
    }

    public static let empty = ReconciliationPlan()

    public var isEmpty: Bool { markInaccessible.isEmpty && purge.isEmpty }
}

/// Règles de réconciliation entre l'index local et la photothèque.
///
/// Principe : un changement d'autorisation n'est jamais interprété comme une suppression.
public enum ReconciliationPlanner {
    /// Au-delà de ce nombre et de cette proportion, une purge est considérée comme suspecte
    /// (par exemple une énumération incomplète) et remplacée par un simple masquage.
    public static let massPurgeMinimumCount = 200
    public static let massPurgeRatio = 0.5

    /// - Parameters:
    ///   - notSeen: photos indexées absentes de la dernière énumération complète.
    ///   - authorization: autorisation en vigueur pendant toute l'énumération.
    ///   - confirmedExisting: parmi `notSeen`, celles que PhotoKit retrouve encore par identifiant.
    ///   - totalIndexed: nombre total de photos indexées (accessibles ou non).
    public static func plan(
        notSeen: [AssetID],
        authorization: LibraryAuthorization,
        confirmedExisting: Set<AssetID>,
        totalIndexed: Int
    ) -> ReconciliationPlan {
        switch authorization {
        case .notDetermined, .restricted, .denied:
            // Sans accès, on ne sait rien : ne rien modifier.
            return .empty
        case .limited:
            // En accès limité, une photo absente peut simplement ne plus être autorisée.
            return ReconciliationPlan(markInaccessible: notSeen)
        case .full:
            let hidden = notSeen.filter { confirmedExisting.contains($0) }
            let missing = notSeen.filter { !confirmedExisting.contains($0) }
            let isMassive = missing.count >= massPurgeMinimumCount
                && Double(missing.count) >= Double(max(totalIndexed, 1)) * massPurgeRatio
            if isMassive {
                return ReconciliationPlan(markInaccessible: notSeen, purge: [], purgeSuspended: true)
            }
            return ReconciliationPlan(markInaccessible: hidden, purge: missing)
        }
    }
}
