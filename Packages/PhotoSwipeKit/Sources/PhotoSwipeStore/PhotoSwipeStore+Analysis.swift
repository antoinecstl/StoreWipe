import Foundation
import PhotoSwipeCore

/// Analyse locale, catégories et marquage en lot.
extension PhotoSwipeStore {
    // MARK: - Analyses

    /// Photos accessibles à analyser : jamais analysées, ou modifiées depuis leur analyse.
    /// `excluding` écarte les photos déjà tentées pendant cette passe (image indisponible).
    public func assetsToAnalyze(limit: Int, excluding: [AssetID] = []) throws -> [AssetSummary] {
        var clauses = [
            visible,
            "(x.local_id IS NULL OR x.fingerprint != a.fingerprint)",
        ]
        var arguments: [SQLValue] = []
        if !excluding.isEmpty {
            let placeholders = Array(repeating: "?", count: excluding.count).joined(separator: ", ")
            clauses.append("a.local_id NOT IN (\(placeholders))")
            arguments += excluding.map { .text($0.rawValue) }
        }
        arguments.append(.int(limit))
        return try connection.query(
            """
            SELECT \(Self.assetColumns) FROM assets a LEFT JOIN analyses x ON x.local_id = a.local_id
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY a.sort_date DESC, a.local_id DESC
            LIMIT ?;
            """,
            arguments,
            map: Self.decodeAsset
        )
    }

    /// Enregistre le résultat d'analyse d'une photo (remplace l'éventuel résultat précédent).
    public func saveAnalysis(_ analysis: ImageAnalysis, for asset: AssetSummary, at date: Date) throws {
        try connection.transaction {
            try connection.run(
                """
                INSERT INTO analyses(local_id, fingerprint, analyzed_at, text_coverage, text_chars, is_utility, aesthetics)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(local_id) DO UPDATE SET
                    fingerprint = excluded.fingerprint,
                    analyzed_at = excluded.analyzed_at,
                    text_coverage = excluded.text_coverage,
                    text_chars = excluded.text_chars,
                    is_utility = excluded.is_utility,
                    aesthetics = excluded.aesthetics;
                """,
                [
                    .text(asset.id.rawValue),
                    .text(asset.contentFingerprint),
                    .date(date),
                    .real(analysis.textCoverage),
                    .int(analysis.textCharacterCount),
                    .bool(analysis.isUtility),
                    .real(analysis.aestheticsScore),
                ]
            )
            try connection.run("DELETE FROM analysis_labels WHERE local_id = ?;", [.text(asset.id.rawValue)])
            for label in analysis.labels {
                try connection.run(
                    "INSERT OR REPLACE INTO analysis_labels(local_id, label, confidence) VALUES (?, ?, ?);",
                    [.text(asset.id.rawValue), .text(label.name), .real(label.confidence)]
                )
            }
        }
    }

    public func analysisProgress() throws -> AnalysisProgress {
        try connection.query(
            """
            SELECT COUNT(*),
                   COALESCE(SUM(CASE WHEN x.local_id IS NOT NULL AND x.fingerprint = a.fingerprint THEN 1 ELSE 0 END), 0)
            FROM assets a LEFT JOIN analyses x ON x.local_id = a.local_id
            WHERE \(visible);
            """
        ) { AnalysisProgress(total: $0.int(0), analyzed: $0.int(1)) }.first ?? AnalysisProgress()
    }

    /// Étiquettes les plus fréquentes parmi les photos analysées (pour créer une catégorie).
    public func labelStatistics(minimumConfidence: Double = 0.5, limit: Int = 400) throws -> [LabelStatistic] {
        try connection.query(
            """
            SELECT l.label, COUNT(*) FROM analysis_labels l
            JOIN assets a ON a.local_id = l.local_id
            WHERE \(visible) AND l.confidence >= ?
            GROUP BY l.label
            ORDER BY COUNT(*) DESC, l.label ASC
            LIMIT ?;
            """,
            [.real(minimumConfidence), .int(limit)]
        ) { LabelStatistic(label: $0.text(0), count: $0.int(1)) }
    }

    /// Nombre de photos accessibles qui correspondent à une règle, quel que soit leur état de tri.
    public func matchCount(rule: CategoryRule) throws -> Int {
        let condition = Self.condition(for: rule)
        return Int(try connection.scalarInt(
            "SELECT COUNT(*) FROM assets a WHERE \(visible) AND \(condition.sql);",
            condition.arguments
        ) ?? 0)
    }

    // MARK: - Catégories

    public func customCategories() throws -> [PhotoCategory] {
        try connection.query("SELECT id, name, labels FROM categories ORDER BY id ASC;") { row in
            Self.decodeCategory(id: row.int64(0), name: row.text(1), labels: row.text(2))
        }
    }

    /// Catégories intégrées puis catégories de l'utilisateur.
    public func allCategories() throws -> [PhotoCategory] {
        BuiltInCategories.all + (try customCategories())
    }

    public func category(forKey key: String) throws -> PhotoCategory? {
        if let builtIn = BuiltInCategories.category(forKey: key) { return builtIn }
        guard key.hasPrefix(PhotoCategory.customPrefix),
              let id = Int64(key.dropFirst(PhotoCategory.customPrefix.count))
        else { return nil }
        return try connection.query(
            "SELECT id, name, labels FROM categories WHERE id = ?;",
            [.integer(id)]
        ) { row in
            Self.decodeCategory(id: row.int64(0), name: row.text(1), labels: row.text(2))
        }.first
    }

    @discardableResult
    public func addCategory(name: String, labels: Set<String>, at date: Date) throws -> PhotoCategory {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sorted = labels.sorted()
        try connection.run(
            "INSERT INTO categories(name, labels, created_at) VALUES (?, ?, ?);",
            [.text(cleanName), .text(sorted.joined(separator: "\n")), .date(date)]
        )
        return Self.decodeCategory(id: connection.lastInsertRowID, name: cleanName, labels: sorted.joined(separator: "\n"))
    }

    public func deleteCategory(id: Int64) throws {
        try connection.run("DELETE FROM categories WHERE id = ?;", [.integer(id)])
    }

    private static func decodeCategory(id: Int64, name: String, labels: String) -> PhotoCategory {
        PhotoCategory(
            key: PhotoCategory.customKey(id),
            name: name,
            symbol: "tag",
            rule: .custom(labels: Set(labels.split(separator: "\n").map(String.init)))
        )
    }

    /// Condition SQL d'appartenance à une règle (alias `a` pour `assets`).
    static func condition(for rule: CategoryRule) -> (sql: String, arguments: [SQLValue]) {
        var positives: [String] = []
        var arguments: [SQLValue] = []
        if !rule.labels.isEmpty {
            let labels = rule.labels.sorted()
            let placeholders = Array(repeating: "?", count: labels.count).joined(separator: ", ")
            positives.append(
                "EXISTS (SELECT 1 FROM analysis_labels l WHERE l.local_id = a.local_id AND l.confidence >= ? AND l.label IN (\(placeholders)))"
            )
            arguments.append(.real(rule.minLabelConfidence))
            arguments += labels.map { .text($0) }
        }
        if rule.includesUtility {
            positives.append("EXISTS (SELECT 1 FROM analyses x WHERE x.local_id = a.local_id AND x.is_utility = 1)")
        }
        if let coverage = rule.minTextCoverage {
            positives.append("EXISTS (SELECT 1 FROM analyses x WHERE x.local_id = a.local_id AND x.text_coverage >= ?)")
            arguments.append(.real(coverage))
        }
        if let aesthetics = rule.maxAesthetics {
            positives.append("EXISTS (SELECT 1 FROM analyses x WHERE x.local_id = a.local_id AND x.aesthetics <= ?)")
            arguments.append(.real(aesthetics))
        }
        guard !positives.isEmpty else { return ("0", []) }
        var sql = "(" + positives.joined(separator: " OR ") + ")"
        if rule.excludesScreenshots {
            sql += " AND (a.subtypes & \(AssetSubtypes.screenshot.rawValue)) = 0"
        }
        if rule.excludesUtility {
            sql += " AND NOT EXISTS (SELECT 1 FROM analyses x WHERE x.local_id = a.local_id AND x.is_utility = 1)"
        }
        return ("(" + sql + ")", arguments)
    }

    // MARK: - Marquage en lot

    /// Applique une décision à toutes les photos encore à trier d'un filtre (non examinées ou passées).
    /// Chaque changement est journalisé. Aucune photo n'est supprimée : « à supprimer » reste une
    /// décision en attente de confirmation.
    @discardableResult
    public func markAllToSort(filter: SessionScope.Filter, as decision: Decision, at date: Date) throws -> Int {
        guard decision != .unreviewed else { return 0 }
        var clauses = [visible, "(d.decision IS NULL OR d.decision = 3)"]
        var arguments: [SQLValue] = []
        try appendFilter(filter, to: &clauses, arguments: &arguments)
        let ids = try connection.query(
            """
            SELECT a.local_id FROM assets a LEFT JOIN decisions d ON d.local_id = a.local_id
            WHERE \(clauses.joined(separator: " AND "));
            """,
            arguments
        ) { AssetID($0.text(0)) }
        guard !ids.isEmpty else { return 0 }
        try connection.transaction {
            for id in ids {
                let previous = try currentDecisionRow(for: id)
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
            }
        }
        return ids.count
    }
}
