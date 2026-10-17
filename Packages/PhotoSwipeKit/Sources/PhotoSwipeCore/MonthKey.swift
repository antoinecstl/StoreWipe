import Foundation

/// Mois civil (année + mois) dans le calendrier de l'utilisateur.
public struct MonthKey: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let year: Int
    public let month: Int

    public init?(year: Int, month: Int) {
        guard (1...12).contains(month), year > 0 else { return nil }
        self.year = year
        self.month = month
    }

    /// Valeur compacte `AAAAMM` utilisée en base (ex. 202403).
    public init?(rawValue: Int) {
        self.init(year: rawValue / 100, month: rawValue % 100)
    }

    public init?(date: Date, calendar: Calendar) {
        let components = calendar.dateComponents([.year, .month], from: date)
        guard let year = components.year, let month = components.month else { return nil }
        self.init(year: year, month: month)
    }

    public var rawValue: Int { year * 100 + month }

    public static func < (lhs: MonthKey, rhs: MonthKey) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Intervalle couvert par ce mois dans le calendrier donné.
    public func dateInterval(in calendar: Calendar) -> DateInterval? {
        guard let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else { return nil }
        return calendar.dateInterval(of: .month, for: start)
    }

    public var description: String {
        String(format: "%04d-%02d", year, month)
    }
}
