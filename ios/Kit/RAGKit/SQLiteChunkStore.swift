#if canImport(SQLite3)
import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

/// SQLite-backed `ChunkStore` (system SQLite, no third-party dependency).
///
/// Vectors are stored as raw little-endian Float32 blobs next to the chunk text.
public actor SQLiteChunkStore: ChunkStore {
    private nonisolated(unsafe) var database: OpaquePointer?

    /// Opens (creating if needed) a database at `url`. Pass `nil` for an in-memory database.
    public init(url: URL?) throws {
        var handle: OpaquePointer?
        let path = url?.path ?? ":memory:"
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle
        else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw RAGError.storage("cannot open database: \(message)")
        }
        database = handle
        try Self.execute(handle, "PRAGMA journal_mode = WAL;")
        try Self.execute(handle, "PRAGMA foreign_keys = ON;")
        try Self.execute(handle, """
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS documents (
                id TEXT PRIMARY KEY, title TEXT NOT NULL, source TEXT NOT NULL,
                hash TEXT NOT NULL UNIQUE, added REAL NOT NULL, chunk_count INTEGER NOT NULL,
                pack TEXT, profile_id TEXT
            );
            CREATE TABLE IF NOT EXISTS chunks (
                id TEXT PRIMARY KEY,
                doc_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL, page INTEGER, heading TEXT,
                text TEXT NOT NULL, vector BLOB NOT NULL
            );
            CREATE INDEX IF NOT EXISTS chunks_doc ON chunks(doc_id);
            """)
        // Lightweight migrations for databases created before pack / profile_id existed.
        try? Self.execute(handle, "ALTER TABLE documents ADD COLUMN pack TEXT;")
        try? Self.execute(handle, "ALTER TABLE documents ADD COLUMN profile_id TEXT;")
    }

    deinit {
        sqlite3_close(database)
    }

    // MARK: ChunkStore

    public func embedderIdentifier() async throws -> String? {
        try query("SELECT value FROM meta WHERE key = 'embedder';") {
            String(cString: sqlite3_column_text($0, 0))
        }.first
    }

    public func setEmbedderIdentifier(_ identifier: String) async throws {
        try run("INSERT INTO meta(key, value) VALUES('embedder', ?1) ON CONFLICT(key) DO UPDATE SET value = ?1;") {
            bind($0, 1, identifier)
        }
    }

    public func documents() async throws -> [DocumentRecord] {
        try query(
            "SELECT id, title, source, hash, added, chunk_count, pack, profile_id FROM documents ORDER BY added DESC;"
        ) { row in
            let pack: String? = sqlite3_column_type(row, 6) == SQLITE_NULL
                ? nil : String(cString: sqlite3_column_text(row, 6))
            let profileRaw: String? = sqlite3_column_type(row, 7) == SQLITE_NULL
                ? nil : String(cString: sqlite3_column_text(row, 7))
            return DocumentRecord(
                id: UUID(uuidString: String(cString: sqlite3_column_text(row, 0))) ?? UUID(),
                title: String(cString: sqlite3_column_text(row, 1)),
                sourceName: String(cString: sqlite3_column_text(row, 2)),
                contentHash: String(cString: sqlite3_column_text(row, 3)),
                addedAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 4)),
                chunkCount: Int(sqlite3_column_int(row, 5)),
                pack: (pack?.isEmpty == false) ? pack : nil,
                profileID: profileRaw.flatMap(UUID.init(uuidString:))
            )
        }
    }

    public func document(withHash hash: String) async throws -> DocumentRecord? {
        try await documents().first { $0.contentHash == hash }
    }

    public func updateDocument(_ document: DocumentRecord) async throws {
        try run(
            "UPDATE documents SET title = ?1, source = ?2, pack = ?3, profile_id = ?4 WHERE id = ?5;"
        ) {
            bind($0, 1, document.title)
            bind($0, 2, document.sourceName)
            if let pack = document.pack { bind($0, 3, pack) } else { sqlite3_bind_null($0, 3) }
            if let profileID = document.profileID { bind($0, 4, profileID.uuidString) } else { sqlite3_bind_null($0, 4) }
            bind($0, 5, document.id.uuidString)
        }
    }

    public func insert(document: DocumentRecord, chunks: [StoredChunk]) async throws {
        try Self.execute(database, "BEGIN IMMEDIATE;")
        do {
            try run(
                "INSERT INTO documents(id, title, source, hash, added, chunk_count, pack, profile_id) VALUES(?1,?2,?3,?4,?5,?6,?7,?8);"
            ) {
                bind($0, 1, document.id.uuidString)
                bind($0, 2, document.title)
                bind($0, 3, document.sourceName)
                bind($0, 4, document.contentHash)
                sqlite3_bind_double($0, 5, document.addedAt.timeIntervalSince1970)
                sqlite3_bind_int($0, 6, Int32(document.chunkCount))
                if let pack = document.pack { bind($0, 7, pack) } else { sqlite3_bind_null($0, 7) }
                if let profileID = document.profileID { bind($0, 8, profileID.uuidString) } else { sqlite3_bind_null($0, 8) }
            }
            for stored in chunks {
                try run("INSERT INTO chunks(id, doc_id, ordinal, page, heading, text, vector) VALUES(?1,?2,?3,?4,?5,?6,?7);") {
                    bind($0, 1, stored.chunk.id.uuidString)
                    bind($0, 2, stored.chunk.documentID.uuidString)
                    sqlite3_bind_int($0, 3, Int32(stored.chunk.ordinal))
                    if let page = stored.chunk.page { sqlite3_bind_int($0, 4, Int32(page)) } else { sqlite3_bind_null($0, 4) }
                    if let heading = stored.chunk.heading { bind($0, 5, heading) } else { sqlite3_bind_null($0, 5) }
                    bind($0, 6, stored.chunk.text)
                    bind($0, 7, VectorMath.data(from: stored.vector))
                }
            }
            try Self.execute(database, "COMMIT;")
        } catch {
            try? Self.execute(database, "ROLLBACK;")
            throw error
        }
    }

    public func delete(documentID: UUID) async throws {
        try run("DELETE FROM documents WHERE id = ?1;") { bind($0, 1, documentID.uuidString) }
    }

    public func deleteAll() async throws {
        try Self.execute(database, "DELETE FROM chunks; DELETE FROM documents;")
        try Self.execute(database, "VACUUM;")
    }

    public func loadAll() async throws -> [StoredChunk] {
        try query("SELECT id, doc_id, ordinal, page, heading, text, vector FROM chunks ORDER BY doc_id, ordinal;") { row in
            let blobLength = Int(sqlite3_column_bytes(row, 6))
            let data = sqlite3_column_blob(row, 6).map { Data(bytes: $0, count: blobLength) } ?? Data()
            let chunk = Chunk(
                id: UUID(uuidString: String(cString: sqlite3_column_text(row, 0))) ?? UUID(),
                documentID: UUID(uuidString: String(cString: sqlite3_column_text(row, 1))) ?? UUID(),
                ordinal: Int(sqlite3_column_int(row, 2)),
                text: String(cString: sqlite3_column_text(row, 5)),
                page: sqlite3_column_type(row, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int(row, 3)),
                heading: sqlite3_column_type(row, 4) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(row, 4))
            )
            return StoredChunk(chunk: chunk, vector: VectorMath.vector(from: data))
        }
    }

    public func replaceVectors(_ vectors: [UUID: [Float]]) async throws {
        try Self.execute(database, "BEGIN IMMEDIATE;")
        do {
            for (id, vector) in vectors {
                try run("UPDATE chunks SET vector = ?1 WHERE id = ?2;") {
                    bind($0, 1, VectorMath.data(from: vector))
                    bind($0, 2, id.uuidString)
                }
            }
            try Self.execute(database, "COMMIT;")
        } catch {
            try? Self.execute(database, "ROLLBACK;")
            throw error
        }
    }

    // MARK: SQLite helpers

    private static func execute(_ handle: OpaquePointer?, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorMessage)
            throw RAGError.storage(message)
        }
    }

    private func run(_ sql: String, binder: (OpaquePointer) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RAGError.storage(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        binder(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RAGError.storage(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func query<T>(_ sql: String, row: (OpaquePointer) -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RAGError.storage(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        var results: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW { results.append(row(statement)) }
        return results
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ text: String) {
        sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ data: Data) {
        data.withUnsafeBytes { buffer in
            _ = sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
        }
    }
}
#endif
