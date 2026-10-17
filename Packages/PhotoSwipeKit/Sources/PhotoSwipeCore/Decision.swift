import Foundation

/// Décision de l'utilisateur sur une photo. Indépendante de tout état d'analyse.
///
/// Aucune de ces valeurs ne supprime une photo : `markedForDeletion` signifie seulement
/// « en attente de confirmation dans la sélection à supprimer ».
public enum Decision: Int, Sendable, Hashable, CaseIterable {
    /// Jamais examinée, ou décision annulée. Représentée en base par l'absence de ligne.
    case unreviewed = 0
    case kept = 1
    case markedForDeletion = 2
    /// Passée sans décision : reproposée lors d'une session ultérieure.
    case deferred = 3
}

/// Action déclenchée par un swipe ou un bouton.
public enum SortAction: Sendable, Hashable, CaseIterable {
    case keep
    case markForDeletion
    case skip
}

public struct DecisionRecord: Sendable, Hashable {
    public let assetID: AssetID
    public let decision: Decision
    public let decidedAt: Date
    public let sessionID: SessionID?

    public init(assetID: AssetID, decision: Decision, decidedAt: Date, sessionID: SessionID?) {
        self.assetID = assetID
        self.decision = decision
        self.decidedAt = decidedAt
        self.sessionID = sessionID
    }
}

/// Trace d'un changement de décision. Elle permet l'annulation, y compris après un
/// redémarrage de l'application, et le calcul des statistiques de session.
public struct DecisionEvent: Sendable, Hashable, Identifiable {
    public let id: Int64
    public let sessionID: SessionID?
    public let assetID: AssetID
    public let previousDecision: Decision
    public let previousDecidedAt: Date?
    public let newDecision: Decision
    public let createdAt: Date

    public init(
        id: Int64,
        sessionID: SessionID?,
        assetID: AssetID,
        previousDecision: Decision,
        previousDecidedAt: Date?,
        newDecision: Decision,
        createdAt: Date
    ) {
        self.id = id
        self.sessionID = sessionID
        self.assetID = assetID
        self.previousDecision = previousDecision
        self.previousDecidedAt = previousDecidedAt
        self.newDecision = newDecision
        self.createdAt = createdAt
    }
}

public enum UndoOutcome: Sendable, Equatable {
    /// La décision précédente a été rétablie.
    case restored(Decision)
    /// La décision a été modifiée ailleurs depuis (ou déjà annulée) : rien n'a été changé.
    case stale
}
