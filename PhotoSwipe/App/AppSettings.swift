import Foundation
import Observation
import PhotoSwipeCore

/// Préférences de l'utilisateur, stockées dans `UserDefaults`.
@MainActor
@Observable
final class AppSettings {
    private enum Key: String, CaseIterable {
        case hasCompletedOnboarding
        case allowsNetworkForDisplay
        case sortOrder
        case analysisEnabled
        case includesVideos
        case allowsNetworkForDuplicates
        case largeFileThresholdMB
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keyPrefix: String

    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: key(.hasCompletedOnboarding)) }
    }

    /// Autorise Photos à télécharger depuis iCloud la photo affichée lorsqu'elle n'est pas
    /// disponible sur l'appareil. N'affecte jamais l'analyse (qui n'existe pas encore dans
    /// cette version) ni la vérification des doublons.
    var allowsNetworkForDisplay: Bool {
        didSet { defaults.set(allowsNetworkForDisplay, forKey: key(.allowsNetworkForDisplay)) }
    }

    /// Autorise Photos à télécharger depuis iCloud les fichiers nécessaires à la vérification des doublons.
    /// Désactivé par défaut : consommation de données.
    var allowsNetworkForDuplicates: Bool {
        didSet { defaults.set(allowsNetworkForDuplicates, forKey: key(.allowsNetworkForDuplicates)) }
    }

    /// Seuil, en Mo, à partir duquel un fichier est « gros » (pile et liste des gros fichiers).
    var largeFileThresholdMB: Int {
        didSet { defaults.set(largeFileThresholdMB, forKey: key(.largeFileThresholdMB)) }
    }

    /// Inclure les vidéos dans le tri, les compteurs et les analyses.
    var includesVideos: Bool {
        didSet { defaults.set(includesVideos, forKey: key(.includesVideos)) }
    }

    /// Analyse locale des photos pour proposer des catégories. Désactivée tant que l'utilisateur ne l'a pas demandée.
    var analysisEnabled: Bool {
        didSet { defaults.set(analysisEnabled, forKey: key(.analysisEnabled)) }
    }

    /// Sens du tri : par défaut, des plus anciennes aux plus récentes.
    var sortOrder: PresentationOrder {
        didSet { defaults.set(sortOrder.rawValue, forKey: key(.sortOrder)) }
    }

    init(defaults: UserDefaults, keyPrefix: String = "") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
        hasCompletedOnboarding = defaults.object(forKey: keyPrefix + Key.hasCompletedOnboarding.rawValue) as? Bool ?? false
        allowsNetworkForDisplay = defaults.object(forKey: keyPrefix + Key.allowsNetworkForDisplay.rawValue) as? Bool ?? true
        analysisEnabled = defaults.object(forKey: keyPrefix + Key.analysisEnabled.rawValue) as? Bool ?? false
        includesVideos = defaults.object(forKey: keyPrefix + Key.includesVideos.rawValue) as? Bool ?? true
        largeFileThresholdMB = defaults.object(forKey: keyPrefix + Key.largeFileThresholdMB.rawValue) as? Int ?? 50
        allowsNetworkForDuplicates = defaults.object(forKey: keyPrefix + Key.allowsNetworkForDuplicates.rawValue) as? Bool ?? false
        sortOrder = defaults.string(forKey: keyPrefix + Key.sortOrder.rawValue).flatMap(PresentationOrder.init(rawValue:)) ?? .oldestFirst
    }

    func reset() {
        hasCompletedOnboarding = false
        allowsNetworkForDisplay = true
        sortOrder = .oldestFirst
        analysisEnabled = false
        includesVideos = true
        largeFileThresholdMB = 50
        allowsNetworkForDuplicates = false
        for key in Key.allCases {
            defaults.removeObject(forKey: self.key(key))
        }
    }

    private func key(_ key: Key) -> String {
        keyPrefix + key.rawValue
    }
}
