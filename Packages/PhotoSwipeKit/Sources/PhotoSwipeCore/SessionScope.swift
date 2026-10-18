import Foundation

/// Sens de présentation des photos datées.
public enum SortOrder: String, Sendable, Hashable, CaseIterable {
    case newestFirst
    case oldestFirst
}

/// Périmètre d'une session de tri : quelles photos (filtre) et dans quel état (réserve).
public struct SessionScope: Sendable, Hashable {
    public enum Filter: Sendable, Hashable {
        case all
        case month(MonthKey)
        /// Photos sans date de création.
        case undated
        /// Captures d'écran, d'après les métadonnées système (aucune analyse d'image).
        case screenshots
    }

    public enum Pool: String, Sendable, Hashable, CaseIterable {
        /// Photos non examinées, puis photos passées lors de sessions précédentes.
        case standard
        /// Uniquement les photos passées lors de sessions précédentes.
        case deferredOnly
        /// Revue explicite des photos déjà conservées.
        case keptReview
    }

    public var filter: Filter
    public var pool: Pool
    public var order: SortOrder

    public init(filter: Filter, pool: Pool = .standard, order: SortOrder = .newestFirst) {
        self.filter = filter
        self.pool = pool
        self.order = order
    }

    public static let everything = SessionScope(filter: .all, pool: .standard)

    /// Phases de la pile, dans l'ordre de présentation.
    public var phases: [QueuePhase] {
        switch pool {
        case .standard: [.main, .deferred]
        case .deferredOnly: [.deferred]
        case .keptReview: [.kept]
        }
    }

    /// Décision à enregistrer pour une action. `nil` signifie « ne rien changer »
    /// (passer une photo déjà conservée pendant une revue).
    public func targetDecision(for action: SortAction) -> Decision? {
        switch (pool, action) {
        case (_, .keep): .kept
        case (_, .markForDeletion): .markedForDeletion
        case (.keptReview, .skip): nil
        case (_, .skip): .deferred
        }
    }

    // MARK: Représentation stable pour la persistance

    /// Représentation textuelle stable, indépendante de l'encodage Swift (ex. `standard|month:202403`).
    public var storageValue: String {
        let filterValue: String
        switch filter {
        case .all: filterValue = "all"
        case .month(let month): filterValue = "month:\(month.rawValue)"
        case .undated: filterValue = "undated"
        case .screenshots: filterValue = "screenshots"
        }
        // Le sens n'est écrit que s'il diffère de l'ancien comportement : les sessions existantes restent lisibles.
        let orderSuffix = order == .oldestFirst ? "|oldest" : ""
        return "\(pool.rawValue)|\(filterValue)\(orderSuffix)"
    }

    public init?(storageValue: String) {
        let parts = storageValue.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard (2...3).contains(parts.count), let pool = Pool(rawValue: parts[0]) else { return nil }
        let order: SortOrder
        if parts.count == 3 {
            guard parts[2] == "oldest" else { return nil }
            order = .oldestFirst
        } else {
            order = .newestFirst
        }
        let filter: Filter
        switch parts[1] {
        case "all":
            filter = .all
        case "undated":
            filter = .undated
        case "screenshots":
            filter = .screenshots
        case let value where value.hasPrefix("month:"):
            guard let raw = Int(value.dropFirst("month:".count)), let month = MonthKey(rawValue: raw) else { return nil }
            filter = .month(month)
        default:
            return nil
        }
        self.init(filter: filter, pool: pool, order: order)
    }
}

/// Phase d'une pile de tri.
public enum QueuePhase: Int, Sendable, Hashable {
    /// Photos non examinées, de la plus récente à la plus ancienne.
    case main
    /// Photos passées lors d'une session précédente, de la plus anciennement passée à la plus récente.
    case deferred
    /// Photos conservées (revue explicite uniquement).
    case kept
}
