import Foundation
import PhotoSwipeCore

/// Tailles de fichiers, gros fichiers et doublons probables.
extension PhotoSwipeStore {
    // MARK: - Mesure des tailles

    /// Éléments accessibles dont la taille n'est pas encore connue (tous types, vidéos comprises
    /// même si elles sont masquées du tri). `excluding` écarte ceux déjà tentés pendant cette passe.
    public func assetsWithoutSize(limit: Int, excluding: [AssetID] = []) throws -> [AssetID] {
        var clauses = ["a.visibility = 0", "a.byte_size IS NULL"]
        var arguments: [SQLValue] = []
        if !excluding.isEmpty {
            let placeholders = Array(repeating: "?", count: excluding.count).joined(separator: ", ")
            clauses.append("a.local_id NOT IN (\(placeholders))")
            arguments += excluding.map { .text($0.rawValue) }
        }
        arguments.append(.int(limit))
        return try connection.query(
            """
            SELECT a.local_id FROM assets a
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY a.sort_date DESC, a.local_id DESC
            LIMIT ?;
            """,
            arguments
        ) { AssetID($0.text(0)) }
    }

    public func saveSizes(_ sizes: [AssetID: Int64]) throws {
        guard !sizes.isEmpty else { return }
        try connection.transaction {
            for (id, size) in sizes {
                try connection.run(
                    "UPDATE assets SET byte_size = ? WHERE local_id = ?;",
                    [.integer(size), .text(id.rawValue)]
                )
            }
        }
    }

    public func sizeCoverage() throws -> SizeCoverage {
        try connection.query(
            """
            SELECT COUNT(*), COALESCE(SUM(CASE WHEN a.byte_size IS NOT NULL THEN 1 ELSE 0 END), 0)
            FROM assets a WHERE a.visibility = 0;
            """
        ) { SizeCoverage(measured: $0.int(1), total: $0.int(0)) }.first ?? SizeCoverage()
    }

    // MARK: - Gros fichiers

    /// Éléments d'au moins `minBytes` octets, les plus lourds d'abord. Les éléments déjà dans la
    /// sélection à supprimer sont écartés (ils sont déjà traités).
    public func largestAssets(kind: MediaKind?, minBytes: Int64, limit: Int) throws -> [LargeAsset] {
        var clauses = [visible, "a.byte_size >= ?", "(d.decision IS NULL OR d.decision != 2)"]
        var arguments: [SQLValue] = [.integer(minBytes)]
        if let kind {
            clauses.append("a.media_type = ?")
            arguments.append(.int(kind.rawValue))
        }
        arguments.append(.int(limit))
        return try connection.query(
            """
            SELECT \(Self.assetColumns), d.decision
            FROM assets a LEFT JOIN decisions d ON d.local_id = a.local_id
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY a.byte_size DESC, a.local_id DESC
            LIMIT ?;
            """,
            arguments
        ) { row in
            LargeAsset(
                asset: try Self.decodeAsset(row),
                decision: row.optionalInt(Self.assetColumnCount).flatMap(Decision.init(rawValue:)) ?? .unreviewed
            )
        }
    }

    /// Nombre et volume des éléments d'au moins `minBytes` octets (hors sélection à supprimer).
    public func largeSummary(kind: MediaKind?, minBytes: Int64) throws -> SizeSummary {
        var clauses = [visible, "a.byte_size >= ?", "(d.decision IS NULL OR d.decision != 2)"]
        var arguments: [SQLValue] = [.integer(minBytes)]
        if let kind {
            clauses.append("a.media_type = ?")
            arguments.append(.int(kind.rawValue))
        }
        return try connection.query(
            """
            SELECT COUNT(*), COALESCE(SUM(a.byte_size), 0)
            FROM assets a LEFT JOIN decisions d ON d.local_id = a.local_id
            WHERE \(clauses.joined(separator: " AND "));
            """,
            arguments
        ) { SizeSummary(count: $0.int(0), bytes: $0.int64(1)) }.first ?? SizeSummary()
    }

    /// Marque comme « à supprimer » des éléments précis (par exemple une sélection dans la liste des gros fichiers).
    @discardableResult
    public func markAssets(_ ids: [AssetID], as decision: Decision, at date: Date) throws -> Int {
        guard decision != .unreviewed, !ids.isEmpty else { return 0 }
        return try connection.transaction {
            var changed = 0
            for id in ids {
                let exists = try connection.scalarInt(
                    "SELECT 1 FROM assets WHERE local_id = ? AND visibility = 0;",
                    [.text(id.rawValue)]
                )
                guard exists != nil else { continue }
                let previous = try currentDecisionRow(for: id)
                guard previous.decision != decision else { continue }
                try connection.run(
                    """
                    INSERT INTO decision_events(session_id, local_id, previous_decision, previous_decided_at, new_decision, created_at)
                    VALUES (NULL, ?, ?, ?, ?, ?);
                    """,
                    [
                        .text(id.rawValue),
                        .int(previous.decision.rawValue),
                        .date(previous.decidedAt),
                        .int(decision.rawValue),
                        .date(date),
                    ]
                )
                try writeDecision(decision, decidedAt: date, sessionID: nil, for: id)
                changed += 1
            }
            return changed
        }
    }

    // MARK: - Doublons probables

    /// Groupes d'éléments de mêmes dimensions, même date de création (à la seconde), même taille et même
    /// nature. Les rafales et les éléments déjà dans la sélection à supprimer sont écartés. Les groupes
    /// qui libéreraient le plus de place viennent en premier.
    public func duplicateGroups(limit: Int = 300) throws -> [DuplicateGroup] {
        let burst = AssetSubtypes.burst.rawValue
        let keys = try connection.query(
            """
            SELECT a.pixel_width, a.pixel_height, CAST(a.creation_date AS INTEGER), a.byte_size, a.media_type
            FROM assets a LEFT JOIN decisions d ON d.local_id = a.local_id
            WHERE a.visibility = 0 AND a.byte_size > 0 AND a.creation_date IS NOT NULL
              AND (a.subtypes & \(burst)) = 0 AND (d.decision IS NULL OR d.decision != 2)
            GROUP BY a.pixel_width, a.pixel_height, CAST(a.creation_date AS INTEGER), a.byte_size, a.media_type
            HAVING COUNT(*) > 1
            ORDER BY a.byte_size * (COUNT(*) - 1) DESC
            LIMIT ?;
            """,
            [.int(limit)]
        ) { row in (row.int(0), row.int(1), row.int64(2), row.int64(3), row.int(4)) }

        var groups: [DuplicateGroup] = []
        for key in keys {
            let members = try connection.query(
                """
                SELECT \(Self.assetColumns), d.decision
                FROM assets a LEFT JOIN decisions d ON d.local_id = a.local_id
                WHERE a.visibility = 0 AND a.pixel_width = ? AND a.pixel_height = ?
                  AND CAST(a.creation_date AS INTEGER) = ? AND a.byte_size = ? AND a.media_type = ?
                  AND (a.subtypes & \(burst)) = 0 AND (d.decision IS NULL OR d.decision != 2)
                ORDER BY a.sort_date ASC, a.local_id ASC;
                """,
                [.int(key.0), .int(key.1), .integer(key.2), .integer(key.3), .int(key.4)]
            ) { row in
                DuplicateMember(
                    asset: try Self.decodeAsset(row),
                    decision: row.optionalInt(Self.assetColumnCount).flatMap(Decision.init(rawValue:)) ?? .unreviewed
                )
            }
            if members.count > 1 {
                groups.append(DuplicateGroup(members: members))
            }
        }
        return groups
    }
}
