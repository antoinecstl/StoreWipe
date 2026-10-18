import Foundation

/// Étiquette de contenu d'une image (identifiant du classifieur du système, en minuscules).
public struct ImageLabel: Sendable, Hashable {
    public let name: String
    public let confidence: Double

    public init(name: String, confidence: Double) {
        self.name = name
        self.confidence = confidence
    }
}

/// Résultat de l'analyse locale d'une image. Ne contient ni pixel ni texte reconnu :
/// seulement des mesures et des étiquettes.
public struct ImageAnalysis: Sendable, Hashable {
    public var labels: [ImageLabel]
    /// Part de la surface de l'image couverte par du texte (0…1).
    public var textCoverage: Double
    /// Nombre de caractères reconnus (le texte lui-même n'est jamais conservé).
    public var textCharacterCount: Int
    /// Le système juge l'image « utilitaire » : reçu, document, note, capture sans intérêt de souvenir.
    public var isUtility: Bool
    /// Score global d'esthétique du système (environ -1 à 1, plus bas = moins réussie).
    public var aestheticsScore: Double

    public init(
        labels: [ImageLabel],
        textCoverage: Double,
        textCharacterCount: Int,
        isUtility: Bool,
        aestheticsScore: Double
    ) {
        self.labels = labels
        self.textCoverage = textCoverage
        self.textCharacterCount = textCharacterCount
        self.isUtility = isUtility
        self.aestheticsScore = aestheticsScore
    }
}

/// Analyse d'une image de la photothèque, entièrement sur l'appareil.
public protocol ImageAnalyzing: Sendable {
    /// - Returns: `nil` si l'image n'est pas disponible localement (par exemple uniquement dans iCloud) :
    ///   l'analyse n'utilise jamais le réseau.
    func analyze(_ id: AssetID) async throws -> ImageAnalysis?
}

/// Avancement de l'analyse des photos accessibles.
public struct AnalysisProgress: Sendable, Hashable {
    public var total: Int
    public var analyzed: Int

    public init(total: Int = 0, analyzed: Int = 0) {
        self.total = total
        self.analyzed = analyzed
    }

    public var fraction: Double { total > 0 ? Double(analyzed) / Double(total) : 0 }
    public var isComplete: Bool { total > 0 && analyzed >= total }
}

/// Nombre de photos analysées portant une étiquette donnée.
public struct LabelStatistic: Sendable, Hashable, Identifiable {
    public let label: String
    public let count: Int

    public init(label: String, count: Int) {
        self.label = label
        self.count = count
    }

    public var id: String { label }
}
