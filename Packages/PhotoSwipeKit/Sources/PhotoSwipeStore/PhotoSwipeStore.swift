import Foundation
import PhotoSwipeCore

/// Requête de page pour une pile de tri.
public struct QueueRequest: Sendable, Hashable {
    public var filter: SessionScope.Filter
    public var phase: QueuePhase
    /// Session courante : les photos déjà traitées pendant cette session sont exclues
    /// des phases `deferred` et `kept`.
    public var sessionID: SessionID
    /// Position de départ pour les phases ordonnées par date (`main`, `kept`).
    public var cursor: SortKey?
    public var cursorInclusive: Bool
    public var excluding: [AssetID]
    public var limit: Int
    public var order: PresentationOrder

    public init(
        filter: SessionScope.Filter,
        phase: QueuePhase,
        sessionID: SessionID,
        cursor: SortKey? = nil,
        cursorInclusive: Bool = true,
        excluding: [AssetID] = [],
        limit: Int,
        order: PresentationOrder = .newestFirst
    ) {
        self.filter = filter
        self.phase = phase
        self.sessionID = sessionID
        self.cursor = cursor
        self.cursorInclusive = cursorInclusive
        self.excluding = excluding
        self.limit = limit
        self.order = order
    }
}

public struct UpsertResult: Sendable, Equatable {
    public var inserted: Int
    public var updated: Int
    /// Photos dont l'empreinte de contenu a changé (retouche, recadrage…).
    public var contentChanged: [AssetID]

    public init(inserted: Int = 0, updated: Int = 0, contentChanged: [AssetID] = []) {
        self.inserted = inserted
        self.updated = updated
        self.contentChanged = contentChanged
    }
}

public enum AssetVisibility: Int, Sendable {
    case accessible = 0
    case inaccessible = 1
}

/// Persistance locale de PhotoSwipe (SQLite, mode WAL).
///
/// Toutes les écritures de décision sont validées immédiatement dans une transaction :
/// une fermeture forcée de l'app ne perd aucune décision déjà affichée comme prise.
public actor PhotoSwipeStore {
    let connection: SQLiteConnection

    /// - Parameter url: fichier de base ; `nil` pour une base en mémoire (tests, mode dégradé).
    public init(url: URL?) throws {
        let connection = try SQLiteConnection(location: url.map(SQLiteConnection.Location.file) ?? .inMemory)
        try Schema.migrate(connection)
        self.connection = connection
    }

    public static var schemaVersion: Int { Schema.latestVersion }

    // MARK: - Index de la photothèque

    /// Démarre une nouvelle passe d'énumération et renvoie son numéro.
    public func beginSyncGeneration() throws -> Int64 {
        try connection.transaction {
            let current = try connection.scalarInt("SELECT CAST(value AS INTEGER) FROM meta WHERE key = 'sync_generation';") ?? 0
            let next = current + 1
            try connection.run(
                "INSERT INTO meta(key, value) VALUES('sync_generation', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
                [.text(String(next))]
            )
            return next
        }
    }

    /// Insère ou met à jour un lot de photos vues pendant la passe `generation`.
    /// Une photo redevenue visible retrouve ses décisions intactes.
    public func upsertAssets(
        _ assets: [AssetSummary],
        generation: Int64,
        calendar: Calendar,
        at date: Date = Date()
    ) throws -> UpsertResult {
        guard !assets.isEmpty else { return UpsertResult() }
        return try connection.transaction {
            let lookup = try connection.prepare("SELECT fingerprint FROM assets WHERE local_id = ?;")
            let upsert = try connection.prepare(
                """
                INSERT INTO assets (
                    local_id, sort_date, creation_date, modification_date, month_key,
                    pixel_width, pixel_height, subtypes, burst_id, is_favorite, fingerprint,
                    visibility, last_seen_generation, first_seen_at, inaccessible_since
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, NULL)
                ON CONFLICT(local_id) DO UPDATE SET
                    sort_date = excluded.sort_date,
                    creation_date = excluded.creation_date,
                    modification_date = excluded.modification_date,
                    month_key = excluded.month_key,
                    pixel_width = excluded.pixel_width,
                    pixel_height = excluded.pixel_height,
                    subtypes = excluded.subtypes,
                    burst_id = excluded.burst_id,
                    is_favorite = excluded.is_favorite,
                    fingerprint = excluded.fingerprint,
                    visibility = 0,
                    last_seen_generation = excluded.last_seen_generation,
                    inaccessible_since = NULL;
                """
            )
            var result = UpsertResult()
            for asset in assets {
                try lookup.bind([.text(asset.id.rawValue)])
                let previousFingerprint: String? = try lookup.step() ? lookup.row.text(0) : nil
                let fingerprint = asset.contentFingerprint
                let monthKey = asset.creationDate.flatMap { MonthKey(date: $0, calendar: calendar)?.rawValue }
                try upsert.bind([
                    .text(asset.id.rawValue),
                    .real(asset.sortDate.timeIntervalSince1970),
                    .date(asset.creationDate),
                    .date(asset.modificationDate),
                    .optionalInt(monthKey),
                    .int(asset.pixelWidth),
                    .int(asset.pixelHeight),
                    .int(asset.subtypes.rawValue),
                    .optionalText(asset.burstIdentifier),
                    .bool(asset.isFavorite),
                    .text(fingerprint),
                    .integer(generation),
                    .date(date),
                ])
                while try upsert.step() {}
                if let previousFingerprint {
                    result.updated += 1
                    if previousFingerprint != fingerprint {
                        result.contentChanged.append(asset.id)
                    }
                } else {
                    result.inserted += 1
                }
            }
            return result
        }
    }

    /// Photos indexées qui n'ont pas été vues pendant la passe `generation`.
    public func assetsNotSeen(since generation: Int64) throws -> [AssetID] {
        try connection.query(
            "SELECT local_id FROM assets WHERE last_seen_generation < ? ORDER BY local_id;",
            [.integer(generation)]
        ) { AssetID($0.text(0)) }
    }

    /// Applique un plan de réconciliation dans une seule transaction.
    public func apply(_ plan: ReconciliationPlan, at date: Date = Date()) throws {
        guard !plan.isEmpty else { return }
        try connection.transaction {
            for id in plan.markInaccessible {
                try connection.run(
                    "UPDATE assets SET visibility = 1, inaccessible_since = COALESCE(inaccessible_since, ?) WHERE local_id = ?;",
                    [.date(date), .text(id.rawValue)]
                )
            }
            for id in plan.purge {
                try purgeRows(for: id)
            }
        }
    }

    func purgeRows(for id: AssetID) throws {
        let argument: [SQLValue] = [.text(id.rawValue)]
        try connection.run("DELETE FROM analysis_labels WHERE local_id = ?;", argument)
        try connection.run("DELETE FROM analyses WHERE local_id = ?;", argument)
        try connection.run("DELETE FROM decision_events WHERE local_id = ?;", argument)
        try connection.run("DELETE FROM decisions WHERE local_id = ?;", argument)
        try connection.run("DELETE FROM assets WHERE local_id = ?;", argument)
    }

    /// Retire de l'index local des photos réellement supprimées de la photothèque,
    /// avec leurs décisions et leur journal. Ne touche à aucune photo.
    public func purge(_ ids: [AssetID]) throws {
        guard !ids.isEmpty else { return }
        try connection.transaction {
            for id in ids {
                try purgeRows(for: id)
            }
        }
    }

    public func assetCount(visibility: AssetVisibility? = nil) throws -> Int {
        if let visibility {
            return Int(try connection.scalarInt("SELECT COUNT(*) FROM assets WHERE visibility = ?;", [.int(visibility.rawValue)]) ?? 0)
        }
        return Int(try connection.scalarInt("SELECT COUNT(*) FROM assets;") ?? 0)
    }

    public func visibility(of id: AssetID) throws -> AssetVisibility? {
        try connection.scalarInt("SELECT visibility FROM assets WHERE local_id = ?;", [.text(id.rawValue)])
            .flatMap { AssetVisibility(rawValue: Int($0)) }
    }

    public func asset(_ id: AssetID) throws -> AssetSummary? {
        try connection.query(
            "SELECT \(Self.assetColumns) FROM assets a WHERE a.local_id = ?;",
            [.text(id.rawValue)],
            map: Self.decodeAsset
        ).first
    }

    // MARK: - Décisions

    public func decision(for id: AssetID) throws -> DecisionRecord? {
        try connection.query(
            "SELECT decision, decided_at, session_id FROM decisions WHERE local_id = ?;",
            [.text(id.rawValue)]
        ) { row in
            DecisionRecord(
                assetID: id,
                decision: Decision(rawValue: row.int(0)) ?? .unreviewed,
                decidedAt: row.date(1),
                sessionID: row.isNull(2) ? nil : SessionID(rawValue: row.int64(2))
            )
        }.first
    }

    /// Enregistre une décision et sa trace d'annulation dans une même transaction.
    @discardableResult
    public func applyDecision(
        _ decision: Decision,
        to id: AssetID,
        sessionID: SessionID?,
        at date: Date
    ) throws -> DecisionEvent {
        try connection.transaction {
            let previous = try currentDecisionRow(for: id)
            try connection.run(
                """
                INSERT INTO decision_events(session_id, local_id, previous_decision, previous_decided_at, new_decision, created_at)
                VALUES (?, ?, ?, ?, ?, ?);
                """,
                [
                    sessionID.map { .integer($0.rawValue) } ?? .null,
                    .text(id.rawValue),
                    .int(previous.decision.rawValue),
                    .date(previous.decidedAt),
                    .int(decision.rawValue),
                    .date(date),
                ]
            )
            let eventID = connection.lastInsertRowID
            try writeDecision(decision, decidedAt: date, sessionID: sessionID, for: id)
            return DecisionEvent(
                id: eventID,
                sessionID: sessionID,
                assetID: id,
                previousDecision: previous.decision,
                previousDecidedAt: previous.decidedAt,
                newDecision: decision,
                createdAt: date
            )
        }
    }

    /// Annule un changement de décision s'il est toujours le plus récent pour cette photo.
    public func undo(eventID: Int64) throws -> UndoOutcome {
        try connection.transaction {
            let rows = try connection.query(
                "SELECT local_id, previous_decision, previous_decided_at, new_decision, undone, session_id FROM decision_events WHERE id = ?;",
                [.integer(eventID)]
            ) { row in
                (
                    id: AssetID(row.text(0)),
                    previous: Decision(rawValue: row.int(1)) ?? .unreviewed,
                    previousDecidedAt: row.optionalDate(2),
                    new: Decision(rawValue: row.int(3)) ?? .unreviewed,
                    undone: row.int(4) != 0,
                    sessionID: row.isNull(5) ? nil : SessionID(rawValue: row.int64(5))
                )
            }
            guard let event = rows.first, !event.undone else { return .stale }
            let latest = try connection.scalarInt(
                "SELECT MAX(id) FROM decision_events WHERE local_id = ? AND undone = 0;",
                [.text(event.id.rawValue)]
            )
            guard latest == eventID else { return .stale }
            let current = try currentDecisionRow(for: event.id)
            guard current.decision == event.new else { return .stale }

            if event.previous == .unreviewed {
                try connection.run("DELETE FROM decisions WHERE local_id = ?;", [.text(event.id.rawValue)])
            } else {
                // La date d'origine est rétablie : une photo passée retrouve sa place dans la file des reportées.
                try writeDecision(
                    event.previous,
                    decidedAt: event.previousDecidedAt ?? Date(timeIntervalSince1970: 0),
                    sessionID: event.sessionID,
                    for: event.id
                )
            }
            try connection.run("UPDATE decision_events SET undone = 1 WHERE id = ?;", [.integer(eventID)])
            return .restored(event.previous)
        }
    }

    func currentDecisionRow(for id: AssetID) throws -> (decision: Decision, decidedAt: Date?) {
        try connection.query(
            "SELECT decision, decided_at FROM decisions WHERE local_id = ?;",
            [.text(id.rawValue)]
        ) { row in
            (Decision(rawValue: row.int(0)) ?? .unreviewed, row.optionalDate(1))
        }.first ?? (.unreviewed, nil)
    }

    func writeDecision(_ decision: Decision, decidedAt: Date, sessionID: SessionID?, for id: AssetID) throws {
        if decision == .unreviewed {
            try connection.run("DELETE FROM decisions WHERE local_id = ?;", [.text(id.rawValue)])
            return
        }
        try connection.run(
            """
            INSERT INTO decisions(local_id, decision, decided_at, session_id) VALUES (?, ?, ?, ?)
            ON CONFLICT(local_id) DO UPDATE SET
                decision = excluded.decision,
                decided_at = excluded.decided_at,
                session_id = excluded.session_id;
            """,
            [
                .text(id.rawValue),
                .int(decision.rawValue),
                .date(decidedAt),
                sessionID.map { .integer($0.rawValue) } ?? .null,
            ]
        )
    }

    /// Photos accessibles sélectionnées pour suppression, de la plus récente à la plus ancienne.
    public func markedForDeletion() throws -> [AssetSummary] {
        try connection.query(
            """
            SELECT \(Self.assetColumns) FROM assets a
            JOIN decisions d ON d.local_id = a.local_id
            WHERE d.decision = 2 AND a.visibility = 0
            ORDER BY a.sort_date DESC, a.local_id DESC;
            """,
            map: Self.decodeAsset
        )
    }

    public func decisionCounts() throws -> DecisionCounts {
        try connection.query(
            """
            SELECT
                COUNT(*),
                COALESCE(SUM(CASE WHEN d.decision IS NULL THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN d.decision = 1 THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN d.decision = 2 THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN d.decision = 3 THEN 1 ELSE 0 END), 0)
            FROM assets a LEFT JOIN decisions d ON d.local_id = a.local_id
            WHERE a.visibility = 0;
            """
        ) { row in
            DecisionCounts(
                totalAccessible: row.int(0),
                unreviewed: row.int(1),
                kept: row.int(2),
                markedForDeletion: row.int(3),
                deferred: row.int(4)
            )
        }.first ?? .zero
    }

    /// Photos restant à trier (non examinées ou passées) pour un filtre donné.
    public func toSortCount(filter: SessionScope.Filter) throws -> Int {
        var clauses = ["a.visibility = 0", "(d.decision IS NULL OR d.decision = 3)"]
        var arguments: [SQLValue] = []
        try appendFilter(filter, to: &clauses, arguments: &arguments)
        return Int(try connection.scalarInt(
            """
            SELECT COUNT(*) FROM assets a LEFT JOIN decisions d ON d.local_id = a.local_id
            WHERE \(clauses.joined(separator: " AND "));
            """,
            arguments
        ) ?? 0)
    }

    public func monthSummaries() throws -> [MonthSummary] {
        try connection.query(
            """
            SELECT
                a.month_key,
                COUNT(*),
                SUM(CASE WHEN d.decision IS NULL THEN 1 ELSE 0 END),
                SUM(CASE WHEN d.decision = 1 THEN 1 ELSE 0 END),
                SUM(CASE WHEN d.decision = 2 THEN 1 ELSE 0 END),
                SUM(CASE WHEN d.decision = 3 THEN 1 ELSE 0 END)
            FROM assets a LEFT JOIN decisions d ON d.local_id = a.local_id
            WHERE a.visibility = 0
            GROUP BY a.month_key
            ORDER BY a.month_key IS NULL, a.month_key DESC;
            """
        ) { row in
            MonthSummary(
                month: row.optionalInt(0).flatMap(MonthKey.init(rawValue:)),
                total: row.int(1),
                unreviewed: row.int(2),
                kept: row.int(3),
                markedForDeletion: row.int(4),
                deferred: row.int(5)
            )
        }
    }

    // MARK: - Sessions

    public func activeSession() throws -> SortingSessionRecord? {
        try connection.query(
            "SELECT \(Self.sessionColumns) FROM sessions WHERE ended_at IS NULL ORDER BY id DESC LIMIT 1;",
            map: Self.decodeSession
        ).first ?? nil
    }

    public func session(_ id: SessionID) throws -> SortingSessionRecord? {
        try connection.query(
            "SELECT \(Self.sessionColumns) FROM sessions WHERE id = ?;",
            [.integer(id.rawValue)],
            map: Self.decodeSession
        ).first ?? nil
    }

    /// Démarre une session et clôt la session active précédente : une seule session est active à la fois.
    public func startSession(scope: SessionScope, at date: Date) throws -> SortingSessionRecord {
        try connection.transaction {
            try connection.run("UPDATE sessions SET ended_at = ? WHERE ended_at IS NULL;", [.date(date)])
            try connection.run(
                "INSERT INTO sessions(scope, started_at) VALUES (?, ?);",
                [.text(scope.storageValue), .date(date)]
            )
            return SortingSessionRecord(
                id: SessionID(rawValue: connection.lastInsertRowID),
                scope: scope,
                startedAt: date
            )
        }
    }

    public func updateCursor(sessionID: SessionID, cursor: SortKey?) throws {
        try connection.run(
            "UPDATE sessions SET cursor_sort_date = ?, cursor_local_id = ? WHERE id = ?;",
            [
                cursor.map { .real($0.date) } ?? .null,
                cursor.map { .text($0.id.rawValue) } ?? .null,
                .integer(sessionID.rawValue),
            ]
        )
    }

    public func endSession(_ id: SessionID, at date: Date) throws {
        try connection.run(
            "UPDATE sessions SET ended_at = COALESCE(ended_at, ?) WHERE id = ?;",
            [.date(date), .integer(id.rawValue)]
        )
    }

    public func sessionStats(_ id: SessionID) throws -> SessionStats {
        var stats = SessionStats()
        let rows = try connection.query(
            "SELECT new_decision, COUNT(*) FROM decision_events WHERE session_id = ? AND undone = 0 GROUP BY new_decision;",
            [.integer(id.rawValue)]
        ) { row in (Decision(rawValue: row.int(0)), row.int(1)) }
        for (decision, count) in rows {
            if let decision { stats.record(decision, delta: count) }
        }
        return stats
    }

    /// Changements encore annulables d'une session, du plus récent au plus ancien.
    /// Seul le dernier changement de chaque photo est annulable.
    public func undoableEvents(sessionID: SessionID, limit: Int) throws -> [(event: DecisionEvent, asset: AssetSummary)] {
        try connection.query(
            """
            SELECT e.id, e.previous_decision, e.previous_decided_at, e.new_decision, e.created_at, \(Self.assetColumns)
            FROM decision_events e
            JOIN assets a ON a.local_id = e.local_id
            WHERE e.session_id = ? AND e.undone = 0 AND a.visibility = 0
              AND e.id = (SELECT MAX(e2.id) FROM decision_events e2 WHERE e2.local_id = e.local_id AND e2.undone = 0)
            ORDER BY e.id DESC
            LIMIT ?;
            """,
            [.integer(sessionID.rawValue), .int(limit)]
        ) { row in
            let asset = try Self.decodeAsset(row, offset: 5)
            let event = DecisionEvent(
                id: row.int64(0),
                sessionID: sessionID,
                assetID: asset.id,
                previousDecision: Decision(rawValue: row.int(1)) ?? .unreviewed,
                previousDecidedAt: row.optionalDate(2),
                newDecision: Decision(rawValue: row.int(3)) ?? .unreviewed,
                createdAt: row.date(4)
            )
            return (event, asset)
        }
    }

    // MARK: - Piles de tri

    public func queuePage(_ request: QueueRequest) throws -> [QueueItem] {
        var clauses = ["a.visibility = 0"]
        var arguments: [SQLValue] = []
        try appendFilter(request.filter, to: &clauses, arguments: &arguments)
        appendPhase(request.phase, sessionID: request.sessionID, to: &clauses, arguments: &arguments)
        let ascending = request.order == .oldestFirst
        if request.phase != .deferred, let cursor = request.cursor {
            let comparison = Self.afterCursorOperators(ascending: ascending, inclusive: request.cursorInclusive)
            clauses.append("(a.sort_date \(comparison.date) ? OR (a.sort_date = ? AND a.local_id \(comparison.id) ?))")
            arguments += [.real(cursor.date), .real(cursor.date), .text(cursor.id.rawValue)]
        }
        if !request.excluding.isEmpty {
            let placeholders = Array(repeating: "?", count: request.excluding.count).joined(separator: ", ")
            clauses.append("a.local_id NOT IN (\(placeholders))")
            arguments += request.excluding.map { .text($0.rawValue) }
        }
        let order = request.phase == .deferred
            ? "d.decided_at ASC, a.local_id ASC"
            : (ascending ? "a.sort_date ASC, a.local_id ASC" : "a.sort_date DESC, a.local_id DESC")
        arguments.append(.int(request.limit))
        let sql = """
            SELECT \(Self.assetColumns), d.decision, d.decided_at
            FROM assets a LEFT JOIN decisions d ON d.local_id = a.local_id
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY \(order)
            LIMIT ?;
            """
        return try connection.query(sql, arguments) { row in
            QueueItem(
                asset: try Self.decodeAsset(row),
                decision: row.optionalInt(8).flatMap(Decision.init(rawValue:)) ?? .unreviewed,
                decidedAt: row.optionalDate(9),
                phase: request.phase
            )
        }
    }

    /// Nombre de photos restant dans la pile d'une session.
    public func remainingCount(for session: SortingSessionRecord) throws -> Int {
        var total = 0
        for phase in session.scope.phases {
            var clauses = ["a.visibility = 0"]
            var arguments: [SQLValue] = []
            try appendFilter(session.scope.filter, to: &clauses, arguments: &arguments)
            appendPhase(phase, sessionID: session.id, to: &clauses, arguments: &arguments)
            if phase == .kept, let cursor = session.cursor {
                let comparison = Self.afterCursorOperators(ascending: session.scope.order == .oldestFirst, inclusive: true)
                clauses.append("(a.sort_date \(comparison.date) ? OR (a.sort_date = ? AND a.local_id \(comparison.id) ?))")
                arguments += [.real(cursor.date), .real(cursor.date), .text(cursor.id.rawValue)]
            }
            let sql = """
                SELECT COUNT(*) FROM assets a LEFT JOIN decisions d ON d.local_id = a.local_id
                WHERE \(clauses.joined(separator: " AND "));
                """
            total += Int(try connection.scalarInt(sql, arguments) ?? 0)
        }
        return total
    }

    /// Opérateurs « après le curseur » selon le sens de présentation.
    private static func afterCursorOperators(ascending: Bool, inclusive: Bool) -> (date: String, id: String) {
        let strict = ascending ? ">" : "<"
        return (strict, inclusive ? strict + "=" : strict)
    }

    func appendFilter(_ filter: SessionScope.Filter, to clauses: inout [String], arguments: inout [SQLValue]) throws {
        switch filter {
        case .all:
            break
        case .month(let month):
            clauses.append("a.month_key = ?")
            arguments.append(.int(month.rawValue))
        case .undated:
            clauses.append("a.month_key IS NULL")
        case .screenshots:
            clauses.append("(a.subtypes & \(AssetSubtypes.screenshot.rawValue)) != 0")
        case .category(let key):
            let rule = try category(forKey: key)?.rule
            let condition: (sql: String, arguments: [SQLValue]) = rule.map { Self.condition(for: $0) } ?? ("0", [])
            clauses.append(condition.sql)
            arguments += condition.arguments
        }
    }

    private func appendPhase(
        _ phase: QueuePhase,
        sessionID: SessionID,
        to clauses: inout [String],
        arguments: inout [SQLValue]
    ) {
        let notHandledInSession = """
            NOT EXISTS (SELECT 1 FROM decision_events e WHERE e.local_id = a.local_id AND e.session_id = ? AND e.undone = 0)
            """
        switch phase {
        case .main:
            clauses.append("d.decision IS NULL")
        case .deferred:
            clauses.append("d.decision = 3")
            clauses.append(notHandledInSession)
            arguments.append(.integer(sessionID.rawValue))
        case .kept:
            clauses.append("d.decision = 1")
            clauses.append(notHandledInSession)
            arguments.append(.integer(sessionID.rawValue))
        }
    }

    // MARK: - Réinitialisation

    /// Efface décisions, journal et sessions. L'index de la photothèque est conservé.
    public func resetDecisions() throws {
        try connection.transaction {
            try connection.execute("DELETE FROM decision_events;")
            try connection.execute("DELETE FROM decisions;")
            try connection.execute("DELETE FROM sessions;")
        }
    }

    /// Efface toutes les données de l'application, puis compacte le fichier pour que les
    /// données supprimées ne subsistent pas sur le disque. Les photos ne sont pas touchées.
    public func eraseAll() throws {
        try connection.transaction {
            try connection.execute("DELETE FROM decision_events;")
            try connection.execute("DELETE FROM decisions;")
            try connection.execute("DELETE FROM sessions;")
            try connection.execute("DELETE FROM analysis_labels;")
            try connection.execute("DELETE FROM analyses;")
            try connection.execute("DELETE FROM categories;")
            try connection.execute("DELETE FROM assets;")
            try connection.execute("DELETE FROM meta;")
            try connection.execute("DELETE FROM sqlite_sequence;")
        }
        try connection.execute("VACUUM;")
        try connection.execute("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    // MARK: - Décodage

    static let assetColumns =
        "a.local_id, a.creation_date, a.modification_date, a.pixel_width, a.pixel_height, a.subtypes, a.burst_id, a.is_favorite"

    private static let sessionColumns = "id, scope, started_at, ended_at, cursor_sort_date, cursor_local_id"

    static func decodeAsset(_ row: SQLiteRow) throws -> AssetSummary {
        try decodeAsset(row, offset: 0)
    }

    static func decodeAsset(_ row: SQLiteRow, offset: Int32) throws -> AssetSummary {
        AssetSummary(
            id: AssetID(row.text(offset)),
            creationDate: row.optionalDate(offset + 1),
            modificationDate: row.optionalDate(offset + 2),
            pixelWidth: row.int(offset + 3),
            pixelHeight: row.int(offset + 4),
            subtypes: AssetSubtypes(rawValue: row.int(offset + 5)),
            burstIdentifier: row.optionalText(offset + 6),
            isFavorite: row.int(offset + 7) != 0
        )
    }

    /// Une session dont le périmètre n'est plus reconnu (version future) est ignorée.
    private static func decodeSession(_ row: SQLiteRow) -> SortingSessionRecord? {
        guard let scope = SessionScope(storageValue: row.text(1)) else { return nil }
        let cursor: SortKey? = row.isNull(4) || row.isNull(5)
            ? nil
            : SortKey(date: row.double(4), id: AssetID(row.text(5)))
        return SortingSessionRecord(
            id: SessionID(rawValue: row.int64(0)),
            scope: scope,
            startedAt: row.date(2),
            endedAt: row.optionalDate(3),
            cursor: cursor
        )
    }
}
