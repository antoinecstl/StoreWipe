import Foundation

/// Schéma versionné par `PRAGMA user_version`. Chaque migration est appliquée une seule
/// fois, dans une transaction. Ne jamais modifier une migration publiée : en ajouter une.
enum Schema {
    struct Migration {
        let version: Int
        let statements: [String]
    }

    static let migrations: [Migration] = [
        Migration(version: 1, statements: [
            // Miroir minimal de la photothèque : métadonnées uniquement, aucun pixel.
            """
            CREATE TABLE assets (
                local_id TEXT PRIMARY KEY NOT NULL,
                sort_date REAL NOT NULL,
                creation_date REAL,
                modification_date REAL,
                month_key INTEGER,
                pixel_width INTEGER NOT NULL,
                pixel_height INTEGER NOT NULL,
                subtypes INTEGER NOT NULL,
                burst_id TEXT,
                is_favorite INTEGER NOT NULL DEFAULT 0,
                fingerprint TEXT NOT NULL,
                visibility INTEGER NOT NULL DEFAULT 0,
                last_seen_generation INTEGER NOT NULL,
                first_seen_at REAL NOT NULL,
                inaccessible_since REAL
            ) WITHOUT ROWID;
            """,
            "CREATE INDEX assets_queue ON assets(visibility, sort_date DESC, local_id DESC);",
            "CREATE INDEX assets_month ON assets(month_key, sort_date DESC, local_id DESC);",
            "CREATE INDEX assets_generation ON assets(last_seen_generation);",
            // Décision courante. L'absence de ligne signifie « non examinée ».
            """
            CREATE TABLE decisions (
                local_id TEXT PRIMARY KEY NOT NULL,
                decision INTEGER NOT NULL CHECK (decision IN (1, 2, 3)),
                decided_at REAL NOT NULL,
                session_id INTEGER
            ) WITHOUT ROWID;
            """,
            "CREATE INDEX decisions_by_kind ON decisions(decision, decided_at);",
            // Journal des changements de décision : annulation et statistiques.
            """
            CREATE TABLE decision_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id INTEGER,
                local_id TEXT NOT NULL,
                previous_decision INTEGER NOT NULL,
                previous_decided_at REAL,
                new_decision INTEGER NOT NULL,
                created_at REAL NOT NULL,
                undone INTEGER NOT NULL DEFAULT 0
            );
            """,
            "CREATE INDEX events_by_session ON decision_events(session_id, undone, id);",
            "CREATE INDEX events_by_asset ON decision_events(local_id, session_id, undone);",
            """
            CREATE TABLE sessions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                scope TEXT NOT NULL,
                started_at REAL NOT NULL,
                ended_at REAL,
                cursor_sort_date REAL,
                cursor_local_id TEXT
            );
            """,
            "CREATE TABLE meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL) WITHOUT ROWID;",
        ]),
        Migration(version: 2, statements: [
            // Analyse locale : mesures et étiquettes uniquement, jamais de pixel ni de texte reconnu.
            """
            CREATE TABLE analyses (
                local_id TEXT PRIMARY KEY NOT NULL,
                fingerprint TEXT NOT NULL,
                analyzed_at REAL NOT NULL,
                text_coverage REAL NOT NULL,
                text_chars INTEGER NOT NULL,
                is_utility INTEGER NOT NULL,
                aesthetics REAL NOT NULL
            ) WITHOUT ROWID;
            """,
            """
            CREATE TABLE analysis_labels (
                local_id TEXT NOT NULL,
                label TEXT NOT NULL,
                confidence REAL NOT NULL,
                PRIMARY KEY (local_id, label)
            ) WITHOUT ROWID;
            """,
            "CREATE INDEX analysis_labels_by_label ON analysis_labels(label, confidence);",
            // Catégories créées par l'utilisateur : nom et étiquettes (une par ligne).
            """
            CREATE TABLE categories (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                labels TEXT NOT NULL,
                created_at REAL NOT NULL
            );
            """,
        ]),
        Migration(version: 3, statements: [
            // Vidéos et taille des fichiers. Les lignes existantes sont des images, taille inconnue.
            "ALTER TABLE assets ADD COLUMN media_type INTEGER NOT NULL DEFAULT 0;",
            "ALTER TABLE assets ADD COLUMN duration REAL;",
            "ALTER TABLE assets ADD COLUMN byte_size INTEGER;",
            "CREATE INDEX assets_by_size ON assets(byte_size DESC);",
        ]),
        Migration(version: 4, statements: [
            // Empreintes des fichiers d'origine pour les doublons exacts (voir docs/06). Aucune image conservée.
            """
            CREATE TABLE resource_digests (
                local_id TEXT PRIMARY KEY NOT NULL,
                method TEXT NOT NULL,
                fingerprint TEXT NOT NULL,
                eligible INTEGER NOT NULL,
                partial TEXT,
                full TEXT,
                computed_at REAL NOT NULL
            ) WITHOUT ROWID;
            """,
            "CREATE INDEX resource_digests_by_hash ON resource_digests(full, partial);",
            "CREATE INDEX assets_duplicate_key ON assets(byte_size, pixel_width, pixel_height, media_type);",
        ]),
    ]

    static var latestVersion: Int { migrations.map(\.version).max() ?? 0 }

    static func migrate(_ connection: SQLiteConnection) throws {
        let current = Int(try connection.scalarInt("PRAGMA user_version;") ?? 0)
        guard current <= latestVersion else {
            throw DatabaseError(
                code: -1,
                message: "schema version \(current) is newer than supported \(latestVersion)",
                context: "migrate"
            )
        }
        for migration in migrations where migration.version > current {
            try connection.transaction {
                for statement in migration.statements {
                    try connection.execute(statement)
                }
                try connection.execute("PRAGMA user_version = \(migration.version);")
            }
        }
    }
}
