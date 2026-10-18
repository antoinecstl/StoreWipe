import Foundation
import PhotoSwipeCore

/// Empreintes de fichiers et doublons exacts (`exact-sha256-v1`, voir docs/06).
extension PhotoSwipeStore {
    /// Éléments dont l'empreinte reste à calculer pour l'étape donnée, les plus petits d'abord.
    ///
    /// - `.partial` : éléments qui ont au moins un autre élément de mêmes dimensions, nature et taille.
    /// - `.full` : éléments éligibles dont l'empreinte partielle est partagée avec un autre élément de même taille.
    public func digestCandidates(stage: DigestStage, limit: Int, excluding: [AssetID] = []) throws -> [AssetSummary] {
        var arguments: [SQLValue] = []
        var extra = ""
        if !excluding.isEmpty {
            let placeholders = Array(repeating: "?", count: excluding.count).joined(separator: ", ")
            extra = " AND a.local_id NOT IN (\(placeholders))"
        }
        let sql: String
        switch stage {
        case .partial:
            arguments.append(.text(DigestMethod.current))
            arguments += excluding.map { .text($0.rawValue) }
            sql = """
                SELECT \(Self.assetColumns) FROM assets a
                WHERE a.visibility = 0 AND a.byte_size > 0
                  AND NOT EXISTS (
                      SELECT 1 FROM resource_digests r
                      WHERE r.local_id = a.local_id AND r.method = ? AND r.fingerprint = a.fingerprint)
                  AND EXISTS (
                      SELECT 1 FROM assets b
                      WHERE b.visibility = 0 AND b.local_id != a.local_id AND b.byte_size = a.byte_size
                        AND b.pixel_width = a.pixel_width AND b.pixel_height = a.pixel_height
                        AND b.media_type = a.media_type)\(extra)
                ORDER BY a.byte_size ASC, a.local_id ASC
                LIMIT ?;
                """
        case .full:
            arguments += [.text(DigestMethod.current), .text(DigestMethod.current)]
            arguments += excluding.map { .text($0.rawValue) }
            sql = """
                SELECT \(Self.assetColumns) FROM assets a
                JOIN resource_digests r ON r.local_id = a.local_id AND r.method = ? AND r.fingerprint = a.fingerprint
                WHERE a.visibility = 0 AND r.eligible = 1 AND r.partial IS NOT NULL AND r.full IS NULL
                  AND EXISTS (
                      SELECT 1 FROM resource_digests r2
                      JOIN assets b ON b.local_id = r2.local_id AND b.fingerprint = r2.fingerprint
                      WHERE r2.method = ? AND r2.local_id != r.local_id AND r2.eligible = 1
                        AND r2.partial = r.partial AND b.visibility = 0
                        AND b.byte_size = a.byte_size AND b.media_type = a.media_type)\(extra)
                ORDER BY a.byte_size ASC, a.local_id ASC
                LIMIT ?;
                """
        }
        arguments.append(.int(limit))
        return try connection.query(sql, arguments, map: Self.decodeAsset)
    }

    /// Enregistre le résultat de l'étape partielle (remplace toute empreinte précédente de l'élément).
    public func savePartialDigest(for id: AssetID, eligible: Bool, partial: String?, at date: Date) throws {
        try connection.run(
            """
            INSERT INTO resource_digests(local_id, method, fingerprint, eligible, partial, full, computed_at)
            SELECT a.local_id, ?, a.fingerprint, ?, ?, NULL, ? FROM assets a WHERE a.local_id = ?
            ON CONFLICT(local_id) DO UPDATE SET
                method = excluded.method,
                fingerprint = excluded.fingerprint,
                eligible = excluded.eligible,
                partial = excluded.partial,
                full = NULL,
                computed_at = excluded.computed_at;
            """,
            [
                .text(DigestMethod.current),
                .bool(eligible),
                .optionalText(partial),
                .date(date),
                .text(id.rawValue),
            ]
        )
    }

    /// Enregistre l'empreinte complète. Sans effet si l'élément a changé depuis l'empreinte partielle.
    public func saveFullDigest(for id: AssetID, full: String, at date: Date) throws {
        try connection.run(
            """
            UPDATE resource_digests SET full = ?, computed_at = ?
            WHERE local_id = ? AND method = ?
              AND fingerprint = (SELECT fingerprint FROM assets WHERE local_id = ?);
            """,
            [.text(full), .date(date), .text(id.rawValue), .text(DigestMethod.current), .text(id.rawValue)]
        )
    }

    /// Nombre d'éléments pour lesquels une empreinte valide existe (partielle ou complète).
    public func digestedCount() throws -> Int {
        Int(try connection.scalarInt(
            """
            SELECT COUNT(*) FROM resource_digests r JOIN assets a ON a.local_id = r.local_id
            WHERE r.method = ? AND r.fingerprint = a.fingerprint AND a.visibility = 0;
            """,
            [.text(DigestMethod.current)]
        ) ?? 0)
    }

    /// Groupes d'éléments strictement identiques : même nature, même taille et même empreinte SHA-256 complète,
    /// calculée sur des fichiers inchangés depuis. Les éléments déjà dans la sélection à supprimer sont écartés.
    public func exactDuplicateGroups(limit: Int = 300) throws -> [DuplicateGroup] {
        let keys = try connection.query(
            """
            SELECT a.byte_size, a.media_type, r.full
            FROM assets a
            JOIN resource_digests r ON r.local_id = a.local_id AND r.method = ? AND r.fingerprint = a.fingerprint
            LEFT JOIN decisions d ON d.local_id = a.local_id
            WHERE a.visibility = 0 AND r.eligible = 1 AND r.full IS NOT NULL
              AND (d.decision IS NULL OR d.decision != 2)
            GROUP BY a.byte_size, a.media_type, r.full
            HAVING COUNT(*) > 1
            ORDER BY a.byte_size * (COUNT(*) - 1) DESC
            LIMIT ?;
            """,
            [.text(DigestMethod.current), .int(limit)]
        ) { row in (row.int64(0), row.int(1), row.text(2)) }

        var groups: [DuplicateGroup] = []
        for key in keys {
            let members = try connection.query(
                """
                SELECT \(Self.assetColumns), d.decision
                FROM assets a
                JOIN resource_digests r ON r.local_id = a.local_id AND r.method = ? AND r.fingerprint = a.fingerprint
                LEFT JOIN decisions d ON d.local_id = a.local_id
                WHERE a.visibility = 0 AND r.eligible = 1 AND r.full = ?
                  AND a.byte_size = ? AND a.media_type = ?
                  AND (d.decision IS NULL OR d.decision != 2)
                ORDER BY a.sort_date ASC, a.local_id ASC;
                """,
                [.text(DigestMethod.current), .text(key.2), .integer(key.0), .int(key.1)]
            ) { row in
                DuplicateMember(
                    asset: try Self.decodeAsset(row),
                    decision: row.optionalInt(Self.assetColumnCount).flatMap(Decision.init(rawValue:)) ?? .unreviewed
                )
            }
            if members.count > 1 {
                groups.append(DuplicateGroup(members: members, isExact: true))
            }
        }
        return groups
    }
}
