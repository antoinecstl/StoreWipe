import Foundation

/// Identifiant local d'un asset PhotoKit (`PHAsset.localIdentifier`).
///
/// Cet identifiant est propre à l'appareil : il ne doit jamais être transmis hors de
/// l'application ni écrit dans les journaux en clair.
public struct AssetID: RawRepresentable, Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }
}

/// Identifiant d'une session de tri persistée.
public struct SessionID: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    public var description: String { String(rawValue) }
}
