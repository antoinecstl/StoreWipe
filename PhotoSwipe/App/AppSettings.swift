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

    /// Sens du tri : par défaut, des plus anciennes aux plus récentes.
    var sortOrder: SortOrder {
        didSet { defaults.set(sortOrder.rawValue, forKey: key(.sortOrder)) }
    }

    init(defaults: UserDefaults, keyPrefix: String = "") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
        hasCompletedOnboarding = defaults.object(forKey: keyPrefix + Key.hasCompletedOnboarding.rawValue) as? Bool ?? false
        allowsNetworkForDisplay = defaults.object(forKey: keyPrefix + Key.allowsNetworkForDisplay.rawValue) as? Bool ?? true
        sortOrder = defaults.string(forKey: keyPrefix + Key.sortOrder.rawValue).flatMap(SortOrder.init(rawValue:)) ?? .oldestFirst
    }

    func reset() {
        hasCompletedOnboarding = false
        allowsNetworkForDisplay = true
        sortOrder = .oldestFirst
        for key in Key.allCases {
            defaults.removeObject(forKey: self.key(key))
        }
    }

    private func key(_ key: Key) -> String {
        keyPrefix + key.rawValue
    }
}
