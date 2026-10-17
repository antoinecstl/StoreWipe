import Foundation

/// Raison pour laquelle une photo est présentée dans la pile.
public enum PresentationReason: Sendable, Hashable {
    case unreviewed
    case previouslyDeferred(since: Date?)
    case reviewingKept(since: Date?)
}

/// Photo prête à être présentée dans une pile de tri.
public struct QueueItem: Sendable, Hashable, Identifiable {
    public let asset: AssetSummary
    /// Décision au moment où l'élément a été chargé.
    public let decision: Decision
    public let decidedAt: Date?
    public let phase: QueuePhase

    public init(asset: AssetSummary, decision: Decision, decidedAt: Date?, phase: QueuePhase) {
        self.asset = asset
        self.decision = decision
        self.decidedAt = decidedAt
        self.phase = phase
    }

    public var id: AssetID { asset.id }

    public var reason: PresentationReason {
        switch decision {
        case .unreviewed, .markedForDeletion: .unreviewed
        case .deferred: .previouslyDeferred(since: decidedAt)
        case .kept: .reviewingKept(since: decidedAt)
        }
    }
}

/// Session de tri persistée.
public struct SortingSessionRecord: Sendable, Hashable, Identifiable {
    public let id: SessionID
    public let scope: SessionScope
    public let startedAt: Date
    public var endedAt: Date?
    /// Position de reprise (incluse) pour les phases ordonnées par date.
    public var cursor: SortKey?

    public init(id: SessionID, scope: SessionScope, startedAt: Date, endedAt: Date? = nil, cursor: SortKey? = nil) {
        self.id = id
        self.scope = scope
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.cursor = cursor
    }
}

/// Compteurs d'une session, calculés à partir des décisions non annulées.
public struct SessionStats: Sendable, Hashable {
    public var kept: Int
    public var markedForDeletion: Int
    public var deferred: Int
    /// Photos revues sans changement (revue des conservées) ; non persisté.
    public var reviewedWithoutChange: Int

    public init(kept: Int = 0, markedForDeletion: Int = 0, deferred: Int = 0, reviewedWithoutChange: Int = 0) {
        self.kept = kept
        self.markedForDeletion = markedForDeletion
        self.deferred = deferred
        self.reviewedWithoutChange = reviewedWithoutChange
    }

    public static let zero = SessionStats()

    public var examined: Int { kept + markedForDeletion + deferred + reviewedWithoutChange }

    public mutating func record(_ decision: Decision?, delta: Int) {
        switch decision {
        case .kept: kept += delta
        case .markedForDeletion: markedForDeletion += delta
        case .deferred: deferred += delta
        case .unreviewed: break
        case nil: reviewedWithoutChange += delta
        }
    }
}

/// Totaux par décision pour les photos accessibles.
public struct DecisionCounts: Sendable, Hashable {
    public var totalAccessible: Int
    public var unreviewed: Int
    public var kept: Int
    public var markedForDeletion: Int
    public var deferred: Int

    public init(totalAccessible: Int = 0, unreviewed: Int = 0, kept: Int = 0, markedForDeletion: Int = 0, deferred: Int = 0) {
        self.totalAccessible = totalAccessible
        self.unreviewed = unreviewed
        self.kept = kept
        self.markedForDeletion = markedForDeletion
        self.deferred = deferred
    }

    public static let zero = DecisionCounts()
}

/// Résumé d'un mois pour l'écran « Trier par mois ». `month == nil` : photos sans date.
public struct MonthSummary: Sendable, Hashable, Identifiable {
    public let month: MonthKey?
    public let total: Int
    public let unreviewed: Int
    public let kept: Int
    public let markedForDeletion: Int
    public let deferred: Int

    public init(month: MonthKey?, total: Int, unreviewed: Int, kept: Int, markedForDeletion: Int, deferred: Int) {
        self.month = month
        self.total = total
        self.unreviewed = unreviewed
        self.kept = kept
        self.markedForDeletion = markedForDeletion
        self.deferred = deferred
    }

    public var id: Int { month?.rawValue ?? 0 }

    public var filter: SessionScope.Filter {
        month.map(SessionScope.Filter.month) ?? .undated
    }

    /// Photos restant à trier (non examinées + passées).
    public var remaining: Int { unreviewed + deferred }
}
