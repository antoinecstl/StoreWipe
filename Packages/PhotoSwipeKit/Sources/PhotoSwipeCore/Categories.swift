import Foundation

/// Règle d'appartenance à une catégorie. Les conditions positives sont combinées par « ou »,
/// les exclusions par « et ». Une photo n'appartient jamais à une catégorie sans avoir été analysée
/// (hors captures d'écran, connues par les métadonnées).
public struct CategoryRule: Sendable, Hashable {
    /// Étiquettes du classifieur (minuscules) qui placent une photo dans la catégorie.
    public var labels: Set<String>
    public var minLabelConfidence: Double
    /// Images jugées « utilitaires » par le système.
    public var includesUtility: Bool
    /// Seuil de couverture de texte (documents, reçus, notes).
    public var minTextCoverage: Double?
    /// Seuil d'esthétique : photos dont le score est inférieur ou égal.
    public var maxAesthetics: Double?
    public var excludesScreenshots: Bool
    public var excludesUtility: Bool

    public init(
        labels: Set<String> = [],
        minLabelConfidence: Double = 0.5,
        includesUtility: Bool = false,
        minTextCoverage: Double? = nil,
        maxAesthetics: Double? = nil,
        excludesScreenshots: Bool = false,
        excludesUtility: Bool = false
    ) {
        self.labels = labels
        self.minLabelConfidence = minLabelConfidence
        self.includesUtility = includesUtility
        self.minTextCoverage = minTextCoverage
        self.maxAesthetics = maxAesthetics
        self.excludesScreenshots = excludesScreenshots
        self.excludesUtility = excludesUtility
    }

    /// Règle d'une catégorie créée par l'utilisateur : une ou plusieurs étiquettes.
    public static func custom(labels: Set<String>) -> CategoryRule {
        CategoryRule(labels: labels, minLabelConfidence: 0.5)
    }

    public var hasPositiveCondition: Bool {
        !labels.isEmpty || includesUtility || minTextCoverage != nil || maxAesthetics != nil
    }
}

/// Catégorie de photos proposée comme pile de tri.
public struct PhotoCategory: Sendable, Hashable, Identifiable {
    /// Clé stable : `builtin:<nom>` ou `custom:<identifiant>`.
    public let key: String
    public var name: String
    /// Nom de symbole SF Symbols.
    public var symbol: String
    public var rule: CategoryRule

    public init(key: String, name: String, symbol: String, rule: CategoryRule) {
        self.key = key
        self.name = name
        self.symbol = symbol
        self.rule = rule
    }

    public var id: String { key }
    public var isBuiltIn: Bool { key.hasPrefix(Self.builtInPrefix) }
    public var customID: Int64? {
        guard key.hasPrefix(Self.customPrefix) else { return nil }
        return Int64(key.dropFirst(Self.customPrefix.count))
    }

    public static let builtInPrefix = "builtin:"
    public static let customPrefix = "custom:"

    public static func customKey(_ id: Int64) -> String { customPrefix + String(id) }
}

/// Catégories fournies avec l'app. Les seuils sont des points de départ à ajuster d'après les résultats réels.
public enum BuiltInCategories {
    /// Reçus, documents, notes : jugés utilitaires par le système ou très couverts de texte.
    public static let documents = PhotoCategory(
        key: "builtin:documents",
        name: "Documents, reçus et notes",
        symbol: "doc.text",
        rule: CategoryRule(
            includesUtility: true,
            minTextCoverage: 0.25,
            excludesScreenshots: true
        )
    )

    /// Photos que le système juge peu réussies (hors images utilitaires et captures d'écran).
    public static let lowQuality = PhotoCategory(
        key: "builtin:low-quality",
        name: "Photos peu réussies",
        symbol: "exclamationmark.triangle",
        rule: CategoryRule(
            maxAesthetics: -0.3,
            excludesScreenshots: true,
            excludesUtility: true
        )
    )

    public static let all: [PhotoCategory] = [documents, lowQuality]

    public static func category(forKey key: String) -> PhotoCategory? {
        all.first { $0.key == key }
    }
}

/// Aide à la recherche d'étiquettes : les étiquettes du système sont en anglais, on les retrouve
/// aussi avec quelques mots français courants.
public enum LabelSearch {
    private static let frenchHints: [String: [String]] = [
        "chat": ["cat"], "chien": ["dog"], "animal": ["animal", "pet"], "oiseau": ["bird"],
        "voiture": ["car", "vehicle"], "moto": ["motorcycle"], "vélo": ["bicycle"], "velo": ["bicycle"],
        "plage": ["beach"], "mer": ["sea", "ocean", "water"], "montagne": ["mountain"], "neige": ["snow"],
        "ciel": ["sky"], "nuage": ["cloud"], "coucher": ["sunset"], "soleil": ["sun", "sunset"],
        "arbre": ["tree"], "fleur": ["flower"], "forêt": ["forest"], "foret": ["forest"],
        "ville": ["city", "street"], "rue": ["street"], "bâtiment": ["building"], "batiment": ["building"],
        "maison": ["house", "building"], "nourriture": ["food"], "repas": ["food", "meal"], "plat": ["dish", "food"],
        "boisson": ["drink"], "personne": ["people", "adult"], "enfant": ["child"], "bébé": ["baby"], "bebe": ["baby"],
        "groupe": ["people", "crowd"], "selfie": ["people"], "texte": ["text"], "document": ["document"],
        "papier": ["paper", "document"], "reçu": ["receipt"], "recu": ["receipt"], "ticket": ["receipt"],
        "écran": ["screen", "screenshot"], "ecran": ["screen", "screenshot"], "livre": ["book"], "affiche": ["poster"],
        "tableau": ["whiteboard", "painting"], "mur": ["wall"], "nuit": ["night"], "sport": ["sport"],
        "musique": ["music"], "concert": ["concert", "crowd"], "voyage": ["landmark", "travel"],
    ]

    /// Libellé lisible d'une étiquette (`hot_dog` devient `hot dog`).
    public static func displayName(_ label: String) -> String {
        label.replacingOccurrences(of: "_", with: " ")
    }

    /// Vrai si `label` correspond à la saisie (étiquette anglaise ou mot français courant).
    public static func matches(label: String, query: String) -> Bool {
        let needle = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !needle.isEmpty else { return true }
        let readable = displayName(label).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if readable.contains(needle) { return true }
        for (french, english) in frenchHints {
            let foldedFrench = french.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            guard foldedFrench.hasPrefix(needle) || needle.hasPrefix(foldedFrench) else { continue }
            if english.contains(where: { readable.contains($0) }) { return true }
        }
        return false
    }
}
