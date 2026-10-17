import Foundation

/// Périmètre d'une session de tri : quelles photos (filtre) et dans quel état (réserve).
public struct SessionScope: Sendable, Hashable {
    public enum Filter: Sendable, Hashable {
        case all
        case month(MonthKey)
        /// Photos sans date de création.
        case undated
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

    public init(filter: Filter, pool: Pool = .standard) {
        self.filter = filter
        self.pool = pool
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
        }
        return "\(pool.rawValue)|\(filterValue)"
    }

    public init?(storageValue: String) {
        let parts = storageValue.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let pool = Pool(rawValue: parts[0]) else { return nil }
        let filter: Filter
        switch parts[1] {
        case "all":
            filter = .all
        case "undated":
            filter = .undated
        case let value where value.hasPrefix("month:"):
            guard let raw = Int(value.dropFirst("month:".count)), let month = MonthKey(rawValue: raw) else { return nil }
            filter = .month(month)
        default:
            return nil
        }
        self.init(filter: filter, pool: pool)
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
