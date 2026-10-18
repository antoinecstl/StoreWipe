import Foundation

/// Cadence d'un travail de fond selon l'état de l'appareil (chaleur, économie d'énergie).
/// Ralentir vaut mieux qu'arrêter : en espaçant les éléments, l'appareil refroidit sans interrompre le travail.
public enum WorkPacing: Sendable, Equatable {
    case full
    /// Attente entre deux éléments.
    case throttled(Duration)
    /// Suspendu (appareil dans un état critique) : reprend de lui-même.
    case paused
}

/// Version de la méthode de détection des doublons exacts. Tout changement de méthode invalide
/// les empreintes déjà calculées.
public enum DigestMethod {
    public static let current = "exact-sha256-v1"
    /// Nombre d'octets lus pour l'empreinte partielle, qui sert uniquement à réduire les candidats.
    public static let partialByteCount = 65_536
}

/// Résultat du calcul d'une empreinte.
public enum DigestOutcome: Sendable, Equatable {
    /// Empreinte SHA-256 en hexadécimal.
    case digest(String)
    /// Élément non comparable en V1 (photo modifiée, Live Photo, RAW+JPEG, plusieurs ressources…).
    case ineligible
    /// Lecture impossible maintenant (uniquement dans iCloud sans autorisation, erreur de lecture, taille incohérente).
    case unavailable
}

/// Calcul d'empreintes sur les octets du fichier d'origine, sur l'appareil.
public protocol ResourceHashing: Sendable {
    /// Empreinte SHA-256 des `DigestMethod.partialByteCount` premiers octets (ou du fichier entier s'il est plus court).
    func partialDigest(for id: AssetID, allowsNetwork: Bool) async -> DigestOutcome

    /// Empreinte SHA-256 de la totalité du fichier. `expectedBytes` doit correspondre exactement au nombre
    /// d'octets lus, sinon le résultat est `.unavailable`.
    func fullDigest(for id: AssetID, expectedBytes: Int64, allowsNetwork: Bool) async -> DigestOutcome
}

/// Étape du calcul des doublons exacts.
public enum DigestStage: Sendable, Hashable {
    case partial
    case full
}
