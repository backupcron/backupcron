import Foundation
import AVFAudio
import UserNotifications
import ServiceManagement
import Security
import Testing
@testable import BackupFlow

struct DatabaseSelectionTests {
    private func sqlite(_ path: URL, _ sql: String) throws -> String {
        let process = Process()
        let pipe = Pipe()
        let input = path.deletingLastPathComponent().appendingPathComponent("fixture-\(UUID().uuidString).sql")
        try Data(sql.utf8).write(to: input)
        defer { try? FileManager.default.removeItem(at: input) }
        let handle = try FileHandle(forReadingFrom: input)
        defer { try? handle.close() }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-init", "/dev/null", "-batch", "-bail", path.path]
        process.standardInput = handle
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw BackupEngineError.commandFailed(output) }
        return output
    }

    private func fixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("backupcron-table-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func exclusionsRoundTripWithoutAmbiguousDottedNamesAndOldJobsRemainFull() throws {
        let legacy = try JSONDecoder().decode(BackupJob.self, from: Data("{}".utf8))
        #expect(legacy.excludedDatabaseTables.isEmpty)
        var job = BackupJob()
        job.excludedDatabaseTables = [
            .init(schema: "a.b", name: "c"), .init(schema: "a", name: "b.c"),
            .init(schema: "Odd \"Schema", name: "logs.* '\n雪")
        ]
        #expect(Set(job.excludedDatabaseTables).count == 3)
        let decoded = try JSONDecoder().decode(BackupJob.self, from: JSONEncoder().encode(job))
        #expect(decoded.excludedDatabaseTables == job.excludedDatabaseTables)
        var renamed = job
        renamed.name = "Another label"
        #expect(renamed.databaseConnectionIdentity == job.databaseConnectionIdentity)
        renamed.databaseName = "another_database"
        #expect(renamed.databaseTargetIdentity != job.databaseTargetIdentity)
    }

    @Test func catalogExpandsPartitionsButNeverSilentlyExcludesForeignKeyChildren() throws {
        let parent = DatabaseTableInfo(schema: "public", name: "events", objectType: "table", sizeBytes: 0)
        let child = DatabaseTableInfo(schema: "public", name: "events_2026", objectType: "table", sizeBytes: 100,
                                     parentTables: [parent.id])
        let grandchild = DatabaseTableInfo(schema: "public", name: "events_sep", objectType: "table", sizeBytes: 200,
                                          parentTables: [child.id])
        let records = DatabaseTableInfo(schema: "public", name: "records", objectType: "table", sizeBytes: 50)
        let referencing = DatabaseTableInfo(schema: "public", name: "references", objectType: "table", sizeBytes: 10,
                                           requiredTables: [records.id])
        let catalog = DatabaseCatalog(sizeBytes: 500, tables: [grandchild, child, parent, records, referencing])
        #expect(catalog.effectiveExclusions([parent.id]) == Set([parent.id, child.id, grandchild.id]))
        #expect(catalog.selectedSize(excluding: [parent.id]) == 60)
        #expect(catalog.selectionError(excluding: [parent.id]) == nil)
        #expect(catalog.selectionError(excluding: [records.id]) != nil)
        #expect(!catalog.effectiveExclusions([records.id]).contains(referencing.id))
        #expect(catalog.selectionError(excluding: catalog.tables.map(\.id)) != nil)
        let unknown = DatabaseCatalog(sizeBytes: nil, tables: [
            .init(schema: "main", name: "unknown", objectType: "table", sizeBytes: nil), records])
        #expect(unknown.selectedSize(excluding: []) == nil)
        #expect(unknown.selectedSize(excluding: [unknown.tables[0].id]) == 50)
        let overflow = DatabaseCatalog(sizeBytes: nil, tables: [
            .init(schema: "main", name: "huge", objectType: "table", sizeBytes: .max), records])
        #expect(overflow.selectedSize(excluding: []) == nil)
    }

    @Test func malformedAndNegativeCatalogResultsAreNotTreatedAsEmptyDatabases() throws {
        let engine = BackupEngine()
        for json in ["", "permission denied", "{}", #"{"sizeBytes":-1,"tables":[]}"#,
                     #"{"sizeBytes":0,"tables":[{"schema":"main","name":"t","objectType":"table","sizeBytes":-1,"requiredTables":[],"parentTables":[]}]}"#] {
            #expect(throws: BackupEngineError.self) { try engine.decodeDatabaseCatalog(Data(json.utf8)) }
        }
        let empty = try engine.decodeDatabaseCatalog(Data(#"{"sizeBytes":0,"tables":[]}"#.utf8))
        #expect(empty.tables.isEmpty)
        #expect(empty.selectedSize(excluding: []) == 0)
    }

    @Test func editingRetainsSelectionsForEachSourceAndUnchangedJobsCanBeSavedOffline() {
        var original = BackupJob()
        original.kind = .postgres
        original.databaseName = "production"
        original.excludedDatabaseTables = [.init(schema: "public", name: "logs")]
        var draft = original
        draft.name = "Renamed"
        draft.destinationPath = "/another/folder"
        draft.schedule = .daily
        #expect(!DatabaseSelectionDraft.requiresInspection(original: original, draft: draft, passwordChanged: false))
        #expect(DatabaseSelectionDraft.requiresInspection(original: nil, draft: draft, passwordChanged: false))
        #expect(DatabaseSelectionDraft.requiresInspection(original: original, draft: draft, passwordChanged: true))
        var selections = DatabaseSelectionDraft()
        var intermediate = draft
        intermediate.databaseName = "productio"
        intermediate.excludedDatabaseTables = selections.move(from: draft, to: intermediate)
        #expect(intermediate.excludedDatabaseTables.isEmpty)
        #expect(DatabaseSelectionDraft.requiresInspection(original: original, draft: intermediate, passwordChanged: false))
        var returned = original
        returned.excludedDatabaseTables = selections.move(from: intermediate, to: returned)
        #expect(returned.excludedDatabaseTables == original.excludedDatabaseTables)
        var another = returned
        another.databaseName = "development"
        another.excludedDatabaseTables = selections.move(from: returned, to: another)
        #expect(another.excludedDatabaseTables.isEmpty)
        another.excludedDatabaseTables = [.init(schema: "public", name: "sessions")]
        returned.excludedDatabaseTables = selections.move(from: another, to: returned)
        #expect(returned.excludedDatabaseTables == original.excludedDatabaseTables)
        another.excludedDatabaseTables = selections.move(from: returned, to: another)
        #expect(another.excludedDatabaseTables == [.init(schema: "public", name: "sessions")])
        draft.excludedDatabaseTables = []
        #expect(DatabaseSelectionDraft.requiresInspection(original: original, draft: draft, passwordChanged: false))
        draft = original
        draft.username = "another_user"
        #expect(DatabaseSelectionDraft.requiresInspection(original: original, draft: draft, passwordChanged: false))
    }

    @Test func spaceBudgetIncludesFullSQLiteSnapshotAndCombinesVolumesByPeakUsage() {
        let retained = DatabaseTableInfo(schema: "main", name: "records", objectType: "table", sizeBytes: 10)
        let logs = DatabaseTableInfo(schema: "main", name: "logs", objectType: "table", sizeBytes: 990)
        let catalog = DatabaseCatalog(sizeBytes: 1_000, tables: [retained, logs])
        var job = BackupJob()
        job.kind = .sqlite
        job.excludedDatabaseTables = [logs.id]
        let estimate = DatabaseSpaceEstimate(job: job, catalog: catalog)
        #expect(estimate.rawBytes == 1_000)
        #expect(estimate.workingBytes == 3_000)
        let destination = DiskSpaceAvailability(volumeID: "disk1", availableBytes: 100_000, path: "/backup")
        let temporary = DiskSpaceAvailability(volumeID: "disk2", availableBytes: 2_000, path: "/tmp")
        let separate = DatabaseSpaceRequirement.plan(estimate: estimate, destination: destination, temporary: temporary, archive: true)
        #expect(separate.count == 2)
        #expect(separate[1].isInsufficient)
        #expect(separate[0].requiredBytes == estimate.archiveBytes)
        var shared = temporary
        shared.volumeID = destination.volumeID
        let together = DatabaseSpaceRequirement.plan(estimate: estimate, destination: destination, temporary: shared, archive: true)
        #expect(together.count == 1)
        #expect(together[0].requiredBytes == max(3_000, 1_000 + estimate.archiveBytes!))
        #expect(together[0].disk.availableBytes == 2_000)
        #expect(together[0].isInsufficient)
        let raw = DatabaseSpaceRequirement.plan(estimate: estimate, destination: destination, temporary: temporary, archive: false)
        #expect(raw.count == 1)
        #expect(raw[0].requiredBytes == 3_000)
        let unknown = DatabaseSpaceEstimate(job: job, catalog: nil)
        #expect(unknown.workingBytes == nil)
        #expect(!DatabaseSpaceRequirement.plan(estimate: unknown, destination: destination, temporary: temporary, archive: true)[0].isInsufficient)
        let huge = DatabaseSpaceEstimate(job: job, catalog: .init(sizeBytes: .max, tables: []))
        #expect(huge.workingBytes == nil)
        #expect(huge.archiveBytes == nil)
    }

    @Test func returningFromConfiguredDockerAndSSHRestoresDirectSelection() {
        var original = BackupJob()
        original.kind = .postgres
        original.databaseName = "fixture"
        original.excludedDatabaseTables = [.init(schema: "public", name: "logs")]
        var cache = DatabaseSelectionDraft()
        var current = original
        for mode in [DatabaseConnectionMode.docker, .ssh] {
            var changed = current
            changed.connectionMode = mode
            changed.excludedDatabaseTables = cache.move(from: current, to: changed)
            current = changed
            changed.dockerContainer = "fixture-container"
            changed.sshHost = "fixture-host"
            changed.sshUsername = "fixture-user"
            changed.sshIdentityPath = "/fixture/identity"
            changed.excludedDatabaseTables = cache.move(from: current, to: changed)
            current = changed
            changed.connectionMode = .direct
            changed.excludedDatabaseTables = cache.move(from: current, to: changed)
            #expect(changed.excludedDatabaseTables == original.excludedDatabaseTables)
            #expect(changed.databaseConnectionIdentity == original.databaseConnectionIdentity)
            #expect(!DatabaseSelectionDraft.requiresInspection(original: original, draft: changed, passwordChanged: false))
            current = changed
        }
    }

    @Test func sqliteFindsTriggerAndNestedViewDependenciesWithoutExecutingThem() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.sqlite3")
        _ = try sqlite(source, """
            CREATE TABLE orders(id INTEGER PRIMARY KEY, value TEXT);
            CREATE TABLE audit_insert(id INTEGER);
            CREATE TABLE audit_update(id INTEGER);
            CREATE TABLE audit_delete(id INTEGER);
            CREATE TABLE keep(id INTEGER); INSERT INTO keep VALUES(7);
            CREATE TRIGGER insert_log AFTER INSERT ON orders BEGIN INSERT INTO audit_insert VALUES(NEW.id); END;
            CREATE TRIGGER update_log AFTER UPDATE OF value ON orders BEGIN INSERT INTO audit_update VALUES(NEW.id); END;
            CREATE TRIGGER delete_log AFTER DELETE ON orders BEGIN INSERT INTO audit_delete VALUES(OLD.id); END;
            CREATE VIEW audit_view AS WITH entries AS (SELECT * FROM audit_insert) SELECT * FROM entries;
            CREATE VIEW nested_view AS SELECT * FROM audit_view;
            CREATE VIEW input_view AS SELECT * FROM keep;
            CREATE TRIGGER view_log INSTEAD OF INSERT ON input_view BEGIN INSERT INTO audit_update VALUES(NEW.id); END;
            """)
        let before = try Data(contentsOf: source)
        var job = BackupJob()
        job.kind = .sqlite
        job.sourcePath = source.path
        job.destinationPath = root.appendingPathComponent("backups").path
        job.archiveOutput = false
        let catalog = try await BackupEngine().inspectDatabase(job: job, password: "")
        let orders = try #require(catalog.tables.first { $0.name == "orders" })
        #expect(orders.dependencyInspectionError == nil)
        for name in ["audit_insert", "audit_update", "audit_delete"] {
            #expect(orders.requiredTables.contains(.init(schema: "main", name: name)))
            #expect(catalog.selectionError(excluding: [.init(schema: "main", name: name)]) != nil)
        }
        let nested = try #require(catalog.tables.first { $0.name == "nested_view" })
        #expect(nested.requiredTables.contains(.init(schema: "main", name: "audit_insert")))
        #expect(nested.requiredTables.contains(.init(schema: "main", name: "audit_view")))
        let input = try #require(catalog.tables.first { $0.name == "input_view" })
        #expect(input.requiredTables.contains(.init(schema: "main", name: "audit_update")))
        #expect(input.dependencyInspectionError == nil)
        #expect(try sqlite(source, "SELECT COUNT(*) FROM audit_insert; SELECT COUNT(*) FROM audit_update; SELECT COUNT(*) FROM audit_delete;") == "0\n0\n0\n")
        job.excludedDatabaseTables = [.init(schema: "main", name: "audit_insert")]
        var rejected = false
        do { _ = try await BackupEngine().run(job: job, password: "") } catch { rejected = true }
        #expect(rejected)
        #expect(!FileManager.default.fileExists(atPath: job.destinationPath))
        job.excludedDatabaseTables = catalog.tables.filter { $0.name != "keep" }.map(\.id)
        let result = try await BackupEngine().run(job: job, password: "")
        #expect(try sqlite(result.outputURL, "SELECT * FROM keep; INSERT INTO keep VALUES(8); SELECT COUNT(*) FROM sqlite_schema WHERE type='trigger'; PRAGMA integrity_check;") == "7\n0\nok\n")
        #expect(try Data(contentsOf: source) == before)
    }

    @Test func sqliteUnresolvedApplicationFunctionsBlockOnlyPartialCopies() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.sqlite3")
        _ = try sqlite(source, """
            CREATE TABLE keep(id); CREATE TABLE logs(id);
            CREATE VIEW custom_view AS SELECT application_function(id) AS id FROM keep;
            CREATE TRIGGER custom_insert INSTEAD OF INSERT ON custom_view BEGIN INSERT INTO keep VALUES(NEW.id); END;
            """)
        var job = BackupJob()
        job.kind = .sqlite
        job.sourcePath = source.path
        job.destinationPath = root.appendingPathComponent("backups").path
        job.archiveOutput = false
        let catalog = try await BackupEngine().inspectDatabase(job: job, password: "")
        #expect(catalog.tables.first { $0.name == "custom_view" }?.dependencyInspectionError != nil)
        #expect(catalog.selectionError(excluding: []) == nil)
        #expect(catalog.selectionError(excluding: [.init(schema: "main", name: "logs")]) != nil)
        #expect(catalog.selectionError(excluding: [.init(schema: "main", name: "logs"), .init(schema: "main", name: "custom_view")]) == nil)
        let result = try await BackupEngine().run(job: job, password: "")
        #expect(try sqlite(result.outputURL, "SELECT COUNT(*) FROM sqlite_schema WHERE name='custom_view';") == "1\n")
    }

    @Test(arguments: [false, true])
    func sqliteCompactionPreservesRowIDsTypesSequencesGeneratedColumnsAndVirtualIndexes(archive: Bool) async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.sqlite3")
        _ = try sqlite(source, """
            PRAGMA user_version=37; PRAGMA application_id=1195524435;
            CREATE TABLE documents(body TEXT);
            INSERT INTO documents(rowid,body) VALUES(42,'needle'),(500001,'second needle');
            CREATE VIRTUAL TABLE search USING fts5(body,content='documents',content_rowid='rowid');
            INSERT INTO search(search) VALUES('rebuild');
            CREATE VIRTUAL TABLE vocabulary USING fts5vocab(search,'row');
            CREATE TRIGGER document_insert AFTER INSERT ON documents BEGIN INSERT INTO search(rowid,body) VALUES(NEW.rowid,NEW.body); END;
            CREATE TABLE aliases(rowid TEXT, _rowid_ INTEGER, oid BLOB);
            INSERT INTO aliases VALUES('delete',1,x'11'),('keep',2,x'2200'); DELETE FROM aliases WHERE rowid='delete';
            CREATE TABLE typed(value REAL, text_value TEXT, binary_value BLOB);
            INSERT INTO typed(rowid,value,text_value,binary_value) VALUES(-9223372036854775807,1.2345678901234567,CAST(x'410042' AS TEXT),x'000102FF');
            CREATE INDEX typed_text ON typed(text_value);
            CREATE TABLE settings(scope TEXT COLLATE NOCASE, key TEXT, value TEXT, PRIMARY KEY(scope DESC,key ASC)) WITHOUT ROWID;
            INSERT INTO settings VALUES('Z','b','first'),('a','c','second');
            CREATE TABLE calculated(value INTEGER, doubled INTEGER GENERATED ALWAYS AS(value*2) STORED, text_value TEXT GENERATED ALWAYS AS('value:'||value) VIRTUAL);
            INSERT INTO calculated(rowid,value) VALUES(123,7);
            CREATE TABLE serials(id INTEGER PRIMARY KEY AUTOINCREMENT, value TEXT);
            INSERT INTO serials VALUES(900,'deleted'); DELETE FROM serials; INSERT INTO serials VALUES(37,'kept');
            CREATE VIRTUAL TABLE spatial USING rtree(id,minX,maxX,minY,maxY);
            INSERT INTO spatial VALUES(71,1,2,3,4);
            CREATE TABLE logs(data BLOB); INSERT INTO logs VALUES(zeroblob(1048576));
            ANALYZE;
            """)
        let before = try Data(contentsOf: source)
        let typed = try sqlite(source, "SELECT rowid,typeof(value),quote(value),typeof(text_value),hex(text_value),hex(binary_value) FROM typed;")
        var job = BackupJob()
        job.kind = .sqlite
        job.sourcePath = source.path
        job.destinationPath = root.appendingPathComponent("backups").path
        job.archiveOutput = archive
        job.nameMask = "preserved"
        job.excludedDatabaseTables = [.init(schema: "main", name: "logs")]
        let result = try await BackupEngine().run(job: job, password: "")
        let restored: URL
        if archive {
            let directory = root.appendingPathComponent("restored")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", result.outputURL.path, directory.path]
            try process.run(); process.waitUntilExit()
            try #require(process.terminationStatus == 0)
            restored = directory.appendingPathComponent("preserved.sqlite3")
        } else { restored = result.outputURL }
        #expect(try Data(contentsOf: source) == before)
        #expect(try Data(contentsOf: restored).count < before.count)
        #expect(try sqlite(restored, "SELECT rowid,body FROM search WHERE search MATCH 'needle' ORDER BY rowid;") == "42|needle\n500001|second needle\n")
        #expect(try sqlite(restored, "SELECT term,doc FROM vocabulary WHERE term='needle';") == "needle|2\n")
        #expect(try sqlite(restored, "SELECT rowid,typeof(value),quote(value),typeof(text_value),hex(text_value),hex(binary_value) FROM typed;") == typed)
        #expect(try sqlite(restored, "SELECT rowid,value,doubled,text_value FROM calculated;") == "123|7|14|value:7\n")
        #expect(try sqlite(restored, "SELECT scope,key,value FROM settings ORDER BY scope COLLATE BINARY;") == "Z|b|first\na|c|second\n")
        #expect(try sqlite(restored, "SELECT rowid,_rowid_,hex(oid) FROM aliases;") == "keep|2|2200\n")
        #expect(try sqlite(restored, "PRAGMA user_version; PRAGMA application_id; PRAGMA integrity_check; SELECT COUNT(*) FROM sqlite_schema WHERE name='logs';") == "37\n1195524435\nok\n0\n")
        #expect(try sqlite(restored, "INSERT INTO serials(value) VALUES('new'); SELECT id FROM serials WHERE value='new';") == "901\n")
        // This disposable schema intentionally uses an FTS5 table in a trigger.
        // Older macOS SQLite builds require explicit trust to execute it.
        #expect(try sqlite(restored, "PRAGMA trusted_schema=ON; INSERT INTO documents(rowid,body) VALUES(700001,'new needle'); SELECT rowid,body FROM search WHERE search MATCH 'new';") == "700001|new needle\n")
        #expect(try sqlite(restored, "SELECT id FROM spatial WHERE minX<3; INSERT INTO spatial VALUES(72,4,5,6,7); SELECT COUNT(*) FROM spatial;") == "71\n2\n")
        #expect(try sqlite(restored, "ALTER TABLE aliases RENAME COLUMN rowid TO explicit_name; SELECT rowid FROM aliases;") == "2\n")
        #expect(try Data(contentsOf: source) == before)
    }

    @Test func sqliteTracksExternalContentAndVocabularyDependenciesIncludingQuotedUnicodeNames() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.sqlite3")
        _ = try sqlite(source, """
            CREATE TABLE "Ωudit"(body TEXT); CREATE TABLE "ωudit"(body TEXT);
            INSERT INTO "ωudit"(rowid,body) VALUES(42,'needle');
            CREATE VIRTUAL TABLE search USING fts5(body, /* content, tricky */ content='ωudit', content_rowid='rowid', tokenize='unicode61 remove_diacritics 2');
            INSERT INTO search(search) VALUES('rebuild');
            CREATE VIRTUAL TABLE vocabulary USING fts5vocab('search','row');
            CREATE TABLE keep(value TEXT); INSERT INTO keep VALUES('retained');
            """)
        let before = try Data(contentsOf: source)
        var job = BackupJob()
        job.kind = .sqlite
        job.sourcePath = source.path
        job.destinationPath = root.appendingPathComponent("backups").path
        job.archiveOutput = false
        let catalog = try await BackupEngine().inspectDatabase(job: job, password: "")
        #expect(catalog.selectionError(excluding: [.init(schema: "main", name: "ωudit")]) != nil)
        #expect(catalog.selectionError(excluding: [.init(schema: "main", name: "search")]) != nil)
        #expect(catalog.selectionError(excluding: [.init(schema: "main", name: "Ωudit")]) == nil)
        job.excludedDatabaseTables = [.init(schema: "main", name: "ωudit")]
        var rejected = false
        do { _ = try await BackupEngine().run(job: job, password: "") } catch { rejected = true }
        #expect(rejected)
        #expect(!FileManager.default.fileExists(atPath: job.destinationPath))
        job.excludedDatabaseTables = [.init(schema: "main", name: "Ωudit")]
        let retained = try await BackupEngine().run(job: job, password: "")
        #expect(try sqlite(retained.outputURL, "SELECT rowid,body FROM search WHERE search MATCH 'needle';") == "42|needle\n")
        job.excludedDatabaseTables = ["Ωudit", "ωudit", "search", "vocabulary"].map { .init(schema: "main", name: $0) }
        let independent = try await BackupEngine().run(job: job, password: "")
        #expect(try sqlite(independent.outputURL, "SELECT value FROM keep; SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%';") == "retained\nkeep\n")
        #expect(try Data(contentsOf: source) == before)
    }

    @Test func sqliteKeepsCanonicallyEquivalentIdentifiersDistinct() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.sqlite3")
        let composed = "\u{00E9}vents"
        let decomposed = "e\u{0301}vents"
        _ = try sqlite(source, """
            CREATE TABLE "\(composed)"(value TEXT); INSERT INTO "\(composed)"(rowid,value) VALUES(42,'excluded');
            CREATE TABLE "\(decomposed)"(value TEXT); INSERT INTO "\(decomposed)"(rowid,value) VALUES(77,'kept');
            CREATE VIRTUAL TABLE search USING fts5(value,content='\(decomposed)');
            INSERT INTO search(search) VALUES('rebuild');
            """)
        let before = try Data(contentsOf: source)
        var job = BackupJob()
        job.kind = .sqlite
        job.sourcePath = source.path
        job.destinationPath = root.appendingPathComponent("backups").path
        job.archiveOutput = false
        job.excludedDatabaseTables = [.init(schema: "main", name: composed)]
        let catalog = try await BackupEngine().inspectDatabase(job: job, password: "")
        #expect(catalog.tables.count == 3)
        #expect(Set(catalog.tables.map(\.id)).count == 3)
        #expect(catalog.selectionError(excluding: job.excludedDatabaseTables) == nil)
        #expect(catalog.selectionError(excluding: [.init(schema: "main", name: decomposed)]) != nil)
        let result = try await BackupEngine().run(job: job, password: "")
        #expect(try sqlite(result.outputURL, "SELECT rowid,value FROM \"\(decomposed)\"; SELECT rowid,value FROM search WHERE search MATCH 'kept';") == "77|kept\n77|kept\n")
        #expect(try sqlite(result.outputURL, "SELECT COUNT(*) FROM sqlite_schema WHERE name='\(composed)' COLLATE BINARY;") == "0\n")
        #expect(try Data(contentsOf: source) == before)
    }

    @Test(arguments: [false, true])
    func cancellingSQLiteCompactionRemovesUnpublishedCopies(archive: Bool) async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.sqlite3")
        _ = try sqlite(source, "CREATE TABLE keep(value TEXT); INSERT INTO keep(rowid,value) VALUES(42,'retained'); CREATE TABLE logs(value TEXT);")
        let before = try Data(contentsOf: source)
        var job = BackupJob()
        job.kind = .sqlite
        job.sourcePath = source.path
        job.destinationPath = root.appendingPathComponent("backups").path
        job.archiveOutput = archive
        job.excludedDatabaseTables = [.init(schema: "main", name: "logs")]
        let configuration = job
        let ready = AsyncStream<Void>.makeStream()
        let copying = L10n.text("database.copying_table", "keep", Int64(0))
        let task = Task {
            defer { ready.continuation.finish() }
            return try await BackupEngine().run(job: configuration, password: "", onProgress: { event in
                if event.message == copying {
                    ready.continuation.yield(())
                    // Hold the native worker at a known phase until cancelled.
                    try? await Task.sleep(for: .seconds(20))
                }
            })
        }
        defer { task.cancel() }
        var iterator = ready.stream.makeAsyncIterator()
        try #require(await iterator.next() != nil)
        let start = Date()
        task.cancel()
        var cancelled = false
        do { _ = try await task.value } catch { cancelled = error is CancellationError }
        #expect(cancelled)
        #expect(Date().timeIntervalSince(start) < 3)
        #expect(try FileManager.default.contentsOfDirectory(atPath: job.destinationPath).isEmpty)
        #expect(try Data(contentsOf: source) == before)
    }

    @Test(arguments: [false, true])
    func sqliteRejectsInsufficientSnapshotSpaceBeforeDumping(archive: Bool) async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.sqlite3")
        _ = try sqlite(source, "CREATE TABLE keep(id); CREATE TABLE logs(data); INSERT INTO logs VALUES(zeroblob(262144));")
        let before = try Data(contentsOf: source)
        var job = BackupJob()
        job.kind = .sqlite
        job.sourcePath = source.path
        job.destinationPath = root.appendingPathComponent("backups").path
        job.archiveOutput = archive
        job.excludedDatabaseTables = [.init(schema: "main", name: "logs")]
        let destination = job.destinationPath
        let engine = BackupEngine(diskSpace: { url in
            .init(volumeID: url.path == destination ? "destination" : "temporary",
                  availableBytes: archive && url.path == destination ? 1_000_000 : 1, path: url.path)
        })
        let catalog = try await engine.inspectDatabase(job: job, password: "")
        let plan = try engine.databaseSpacePlan(job: job, catalog: catalog)
        let insufficient = plan.first { $0.isInsufficient }
        let requirement = try #require(insufficient)
        let expected = L10n.text("database.space_insufficient", requirement.disk.path,
            ByteCountFormatter.string(fromByteCount: requirement.requiredBytes!, countStyle: .file),
            ByteCountFormatter.string(fromByteCount: requirement.disk.availableBytes!, countStyle: .file))
        var rejected = false
        do { _ = try await engine.run(job: job, password: "") }
        catch { rejected = error.localizedDescription == expected }
        #expect(rejected)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination).isEmpty)
        #expect(try Data(contentsOf: source) == before)
    }

    @Test func fullServerDumpWorksWithoutCatalogPermissionsOrCapacityInformation() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dump = root.appendingPathComponent("pg_dump")
        let query = root.appendingPathComponent("psql")
        try Data("#!/bin/sh\necho 'permission denied' >&2\nexit 1\n".utf8).write(to: query)
        let script = """
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--file" ]; then
            shift
            printf '%s\\n' 'CREATE TABLE records(id INTEGER);' > "$1"
          fi
          shift
        done
        """
        try Data(script.utf8).write(to: dump)
        for url in [query, dump] { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
        var job = BackupJob()
        job.kind = .postgres
        job.databaseName = "fixture"
        job.username = "fixture"
        job.destinationPath = root.appendingPathComponent("backups").path
        job.clientExecutablePath = dump.path
        job.archiveOutput = false
        let engine = BackupEngine(diskSpace: { _ in throw CocoaError(.fileReadNoPermission) })
        let result = try await engine.run(job: job, password: "")
        #expect(try String(contentsOf: result.outputURL, encoding: .utf8) == "CREATE TABLE records(id INTEGER);\n")
        job.excludedDatabaseTables = [.init(schema: "public", name: "logs")]
        var rejected = false
        do { _ = try await engine.run(job: job, password: "") }
        catch { rejected = error.localizedDescription.contains("permission denied") }
        #expect(rejected)
        #expect(try FileManager.default.contentsOfDirectory(atPath: job.destinationPath).count == 1)
    }

    @Test(arguments: [false, true])
    func sqliteExclusionsRemoveStructureAndDataAndPreserveTheSource(archive: Bool) async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.sqlite3")
        let unusual = "logs.* \"雪'\n"
        let quoted = "\"" + unusual.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        _ = try sqlite(source, """
            CREATE TABLE records(id INTEGER PRIMARY KEY, value TEXT);
            INSERT INTO records VALUES(1, 'keep me');
            CREATE INDEX records_value ON records(value);
            CREATE TABLE \(quoted)(payload BLOB);
            INSERT INTO \(quoted) VALUES(zeroblob(262144));
            CREATE VIEW logs_view AS SELECT payload FROM \(quoted);
            CREATE TABLE logs_match(id INTEGER);
            """)
        let before = try Data(contentsOf: source)
        var job = BackupJob()
        job.kind = .sqlite
        job.sourcePath = source.path
        job.destinationPath = root.appendingPathComponent("backups").path
        job.archiveOutput = archive
        job.nameMask = "snapshot"
        let catalog = try await BackupEngine().inspectDatabase(job: job, password: "")
        let table = try #require(catalog.tables.first { $0.name == unusual })
        #expect((table.sizeBytes ?? 0) >= 262144)
        #expect((catalog.sizeBytes ?? 0) >= (table.sizeBytes ?? 0))
        #expect(catalog.tables.count == 4)
        job.excludedDatabaseTables = [table.id, .init(schema: "main", name: "logs_view")]
        #expect((catalog.selectedSize(excluding: job.excludedDatabaseTables) ?? .max) < table.sizeBytes!)
        let result = try await BackupEngine().run(job: job, password: "")
        let restored: URL
        if archive {
            let directory = root.appendingPathComponent("restored")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", result.outputURL.path, directory.path]
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0)
            restored = directory.appendingPathComponent("snapshot.sqlite3")
        } else { restored = result.outputURL }
        #expect(try sqlite(restored, "SELECT value FROM records; PRAGMA integrity_check;") == "keep me\nok\n")
        #expect(try sqlite(restored, "SELECT name FROM sqlite_schema ORDER BY name;") == "logs_match\nrecords\nrecords_value\n")
        #expect(try Data(contentsOf: source) == before)
        #expect(try sqlite(source, "SELECT COUNT(*) FROM \(quoted);") == "1\n")
        #expect(try Data(contentsOf: restored).count < before.count)
    }

    @Test func sqliteRejectsBrokenDependenciesWithoutPublishingOrChangingTheSource() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.sqlite3")
        _ = try sqlite(source, """
            CREATE TABLE parents(id INTEGER PRIMARY KEY);
            CREATE TABLE children(id INTEGER, parent_id INTEGER REFERENCES PARENTS(id));
            INSERT INTO parents VALUES(1); INSERT INTO children VALUES(1,1);
            """)
        let before = try Data(contentsOf: source)
        var job = BackupJob()
        job.kind = .sqlite
        job.sourcePath = source.path
        job.destinationPath = root.appendingPathComponent("backups").path
        job.archiveOutput = false
        job.excludedDatabaseTables = [.init(schema: "main", name: "parents")]
        let catalog = try await BackupEngine().inspectDatabase(job: job, password: "")
        #expect(catalog.selectionError(excluding: job.excludedDatabaseTables) != nil)
        var rejected = false
        do { _ = try await BackupEngine().run(job: job, password: "") }
        catch { rejected = error.localizedDescription == catalog.selectionError(excluding: job.excludedDatabaseTables) }
        #expect(rejected)
        #expect(try Data(contentsOf: source) == before)
        #expect(!FileManager.default.fileExists(atPath: job.destinationPath))
    }

    @Test func sqliteInspectionDoesNotCreateAMissingSource() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var job = BackupJob()
        job.kind = .sqlite
        job.sourcePath = root.appendingPathComponent("missing.sqlite3").path
        var rejected = false
        do { _ = try await BackupEngine().inspectDatabase(job: job, password: "") } catch { rejected = true }
        #expect(rejected)
        #expect(!FileManager.default.fileExists(atPath: job.sourcePath))
    }

    @Test func cancellingCatalogInspectionStopsItsClient() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = root.appendingPathComponent("psql")
        let ready = root.appendingPathComponent("ready")
        let script = "#!/bin/sh\n: > '\(ready.path)'\nexec /bin/sleep 20\n"
        try Data(script.utf8).write(to: client)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: client.path)
        var job = BackupJob()
        job.kind = .postgres
        job.databaseName = "fixture"
        job.username = "fixture"
        job.clientExecutablePath = root.appendingPathComponent("pg_dump").path
        let configuration = job
        let task = Task { try await BackupEngine().inspectDatabase(job: configuration, password: "") }
        defer { task.cancel() }
        // Allow process launch to compete with a build; measure cancellation
        // only after the fixture confirms that its client has started.
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: ready.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(FileManager.default.fileExists(atPath: ready.path))
        let start = Date()
        task.cancel()
        var cancelled = false
        do { _ = try await task.value } catch { cancelled = error is CancellationError }
        #expect(cancelled)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func databaseInterfaceIsTranslatedInEverySupportedLanguage() throws {
        let keys = ["tables_title", "load", "refresh", "loading", "total_size", "selected_size", "size_note",
                    "search", "sort", "sort_size", "sort_name", "include_all", "empty", "selected_count",
                    "no_matches", "missing_exclusion", "include", "exclusion_note", "load_hint", "unknown_size",
                    "excluded_parent", "view", "excluded_tables", "select_one", "required_table", "invalid_response",
                    "timeout", "invalid_copy", "dependencies_unknown", "offline_edit", "source_changed", "space_title",
                    "space_destination", "space_shared", "space_temporary", "space_summary", "space_sqlite_note", "space_sql_note", "space_insufficient", "compacting", "copying_table"]
        for language in L10n.supportedLanguages {
            for suffix in keys {
                let key = "database." + suffix
                #expect(L10n.text(key, language: language) != key)
            }
        }
    }
}

@MainActor
private final class FakeBackupCuePlayer: BackupCuePlaying {
    var isPlaying = false
    var succeeds = true
    var cues: [BackupSoundCue] = []
    var volume: Float = 0
    var stopCount = 0

    func play(_ cue: BackupSoundCue, volume: Float) -> Bool {
        cues.append(cue)
        self.volume = volume
        isPlaying = succeeds
        return succeeds
    }
    func setVolume(_ value: Float) { volume = value }
    func stop() { stopCount += 1; isPlaying = false }
}

struct BackupFeedbackTests {
    @Test func motionStopsForReducedMotionHiddenViewsAndInactiveScenes() {
        for reduced in [false, true] {
            for active in [false, true] {
                for visible in [false, true] {
                    #expect(BackupMotion.shouldAnimate(reduceMotion: reduced, isActive: active, isVisible: visible)
                            == (!reduced && active && visible))
                }
            }
        }
        #expect(BackupMotion.transition(reduceMotion: true) == nil)
        #expect(BackupMotion.transition(reduceMotion: false) != nil)
    }

    @Test func soundVolumeIsFiniteClampedAndQuantized() {
        #expect(BackupSoundPreferences.normalizedVolume(-1) == 0)
        #expect(BackupSoundPreferences.normalizedVolume(2) == 1)
        #expect(BackupSoundPreferences.normalizedVolume(.nan) == 0.45)
        #expect(BackupSoundPreferences.normalizedVolume(.infinity) == 0.45)
        #expect(BackupSoundPreferences.normalizedVolume(0.471) == 0.45)
        #expect(BackupSoundPreferences.normalizedVolume(0.479) == 0.5)
        #expect(BackupSoundCue(status: .cancelled) == nil)
    }

    @Test func synthesizedCuesAreDistinctBoundedAndClickFree() throws {
        for cue in BackupSoundCue.allCases {
            let samples = BackupSoundSynthesis.samples(for: cue)
            #expect(samples.count == 22_050)
            #expect(samples == BackupSoundSynthesis.samples(for: cue))
            #expect(samples.prefix(441).allSatisfy { $0 == 0 })
            #expect(samples.suffix(1_000).allSatisfy { $0 == 0 })
            #expect(samples.map { abs(Int($0)) }.max()! < 16_000)
            #expect(samples.contains { $0 != 0 })
            #expect(zip(samples, samples.dropFirst()).allSatisfy { abs(Int($0) - Int($1)) < 2_000 })
            #expect(BackupSoundSynthesis.samples(for: cue, volume: 0).allSatisfy { $0 == 0 })
            let quiet = BackupSoundSynthesis.samples(for: cue, volume: 0.5)
            #expect(zip(samples, quiet).allSatisfy { abs(Double($0) * 0.5 - Double($1)) <= 1 })
        }
        #expect(BackupSoundSynthesis.wav(for: .success) != BackupSoundSynthesis.wav(for: .failure))
    }

    @Test func generatedWAVDecodesAsHalfSecondMonoPCMWithoutPlaying() throws {
        for cue in BackupSoundCue.allCases {
            let data = BackupSoundSynthesis.wav(for: cue)
            #expect(data.count == 44 + 22_050 * 2)
            #expect(String(data: data.prefix(4), encoding: .ascii) == "RIFF")
            #expect(String(data: data[8..<12], encoding: .ascii) == "WAVE")
            let decoder = try AVAudioPlayer(data: data)
            #expect(abs(decoder.duration - 0.5) < 0.001)
            #expect(decoder.numberOfChannels == 1)
            #expect(decoder.format.sampleRate == 44_100)
            #expect(!decoder.isPlaying)
        }
    }

    @Test @MainActor func soundStartsOffAndPreferencesPersistWithoutPlaying() throws {
        let name = "BackupCron.sound-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let player = FakeBackupCuePlayer()
        let feedback = BackupAudioFeedback(defaults: defaults, player: player, isActive: { true })
        #expect(!feedback.enabled)
        #expect(feedback.volume == 0.45)
        #expect(feedback.handleResult(.success))
        feedback.preview(.success)
        #expect(player.cues.isEmpty)

        feedback.setEnabled(true)
        feedback.setVolume(0.65)
        #expect(player.cues.isEmpty)
        let restored = BackupAudioFeedback(defaults: defaults, player: player)
        #expect(restored.enabled && restored.volume == 0.65)
        feedback.preview(.success)
        #expect(player.cues == [.success])
        #expect(player.volume == 0.65)
        feedback.setVolume(0.2)
        #expect(player.volume == 0.2)
        feedback.setEnabled(false)
        #expect(!player.isPlaying)
        #expect(player.stopCount == 1)
    }

    @Test @MainActor func backgroundAndCancelledResultsNeverUseInAppAudio() throws {
        let name = "BackupCron.sound-routing-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let player = FakeBackupCuePlayer()
        var active = false
        let feedback = BackupAudioFeedback(defaults: defaults, player: player, isActive: { active })
        feedback.setEnabled(true)
        #expect(!feedback.handleResult(.success))
        #expect(!feedback.handleResult(.failure))
        active = true
        #expect(feedback.handleResult(.cancelled))
        #expect(player.cues.isEmpty)
        feedback.setVolume(0)
        #expect(feedback.handleResult(.success))
        feedback.preview(.failure)
        #expect(player.cues.isEmpty)
    }

    @Test @MainActor func completionBurstsCoalesceButAnErrorCanReplaceSuccess() throws {
        let name = "BackupCron.sound-burst-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let player = FakeBackupCuePlayer()
        var now: TimeInterval = 10
        let feedback = BackupAudioFeedback(defaults: defaults, player: player, isActive: { true }, uptime: { now })
        feedback.setEnabled(true)
        #expect(feedback.handleResult(.success))
        #expect(feedback.handleResult(.success))
        #expect(player.cues == [.success])
        #expect(feedback.handleResult(.failure))
        #expect(feedback.handleResult(.failure))
        #expect(feedback.handleResult(.success))
        #expect(player.cues == [.success, .failure])
        now += 2
        player.isPlaying = false
        #expect(feedback.handleResult(.success))
        #expect(player.cues == [.success, .failure, .success])
    }

    @Test @MainActor func previewFailureIsVisibleAndClearedOnSettingChange() throws {
        let name = "BackupCron.sound-error-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let player = FakeBackupCuePlayer()
        player.succeeds = false
        let feedback = BackupAudioFeedback(defaults: defaults, player: player)
        feedback.setEnabled(true)
        feedback.preview(.failure)
        #expect(feedback.previewFailed)
        feedback.setVolume(0.25)
        #expect(!feedback.previewFailed)
    }

    @Test func notificationSoundsUseOriginalWAVAndNeverDuplicateForegroundAudio() throws {
        let name = "BackupCron.sound-notification-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = BackupRun(jobID: UUID(), jobName: "Fixture", startedAt: Date(), finishedAt: Date(),
                            status: .success, message: "Complete")
        func content(_ suppress: Bool) -> UNMutableNotificationContent {
            BackupNotifications.makeContent(for: run, defaults: defaults, suppressSound: suppress, soundDirectory: directory)
        }
        #expect(content(false).sound == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        defaults.set(true, forKey: BackupSoundPreferences.enabledKey)
        #expect(content(true).sound == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(content(false).sound != nil)
        let file = directory.appendingPathComponent("BackupCron-feedback-v1-success-9.wav")
        #expect(try Data(contentsOf: file) == BackupSoundSynthesis.wav(for: .success, volume: 0.45))
        #expect(content(false).sound != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
        defaults.set(0, forKey: BackupSoundPreferences.volumeKey)
        #expect(content(false).sound == nil)
        #expect(!BackupNotifications.foregroundPresentationOptions.contains(.sound))
        #expect(BackupNotifications.foregroundPresentationOptions.contains(.banner))
    }

    @Test func notificationSoundFailureKeepsVisualContentAndCancellationWritesNothing() throws {
        let name = "BackupCron.sound-file-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: BackupSoundPreferences.enabledKey)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A file where a directory was expected forces a preparation failure.
        try Data("fixture".utf8).write(to: directory)
        let run = BackupRun(jobID: UUID(), jobName: "Fixture", startedAt: Date(), finishedAt: Date(),
                            status: .failure, message: "Failed")
        let content = BackupNotifications.makeContent(for: run, defaults: defaults, suppressSound: false, soundDirectory: directory)
        #expect(content.sound == nil)
        #expect(!content.title.isEmpty && !content.body.isEmpty)
        #expect(try Data(contentsOf: directory) == Data("fixture".utf8))
        #expect(try BackupSoundSynthesis.notificationFile(for: .cancelled,
            preferences: BackupSoundPreferences(defaults: defaults), suppressSound: false, directory: directory) == nil)
    }

    @Test func feedbackControlsAreLocalizedInEverySupportedLanguage() {
        let keys = ["sound.title", "sound.enabled", "sound.volume", "sound.preview_success", "sound.preview_failure",
                    "sound.note", "sound.preview_failed", "activity.follow_log"]
        for language in L10n.supportedLanguages {
            for key in keys {
                #expect(L10n.text(key, language: language) != key)
                #expect(!L10n.text(key, language: language).isEmpty)
            }
        }
    }
}

struct BackupPresentationTests {
    private func run(_ jobID: UUID, at time: TimeInterval, status: BackupStatus) -> BackupRun {
        BackupRun(jobID: jobID, jobName: "Fixture", startedAt: Date(timeIntervalSince1970: time - 2),
                  finishedAt: Date(timeIntervalSince1970: time), status: status,
                  outputPath: status == .success ? "/fixture/backup.zip" : nil, message: "Fixture")
    }

    @Test func latestAttemptAndSuccessfulCopyAreIndependent() {
        let id = UUID()
        let successful = run(id, at: 100, status: .success)
        let failed = run(id, at: 200, status: .failure)
        let cancelled = run(id, at: 300, status: .cancelled)
        let unrelated = run(UUID(), at: 500, status: .success)
        let history = [failed, unrelated, successful, cancelled]
        let snapshot = JobSnapshot(jobID: id, history: history, isRunning: false)
        #expect(snapshot.latestAttempt?.id == cancelled.id)
        #expect(snapshot.latestSuccess?.id == successful.id)
        #expect(snapshot.health == .cancelled)
        #expect(snapshot.health.needsAttention)
        let running = JobSnapshot(jobID: id, history: history, isRunning: true)
        #expect(running.health == .running)
        #expect(running.latestSuccess?.id == successful.id)
        #expect(!running.health.needsAttention)
    }

    @Test func noHistoryNeverClaimsSuccessAndRecoveryClearsAttention() {
        let id = UUID()
        let empty = JobSnapshot(jobID: id, history: [], isRunning: false)
        #expect(empty.health == .neverRun)
        #expect(empty.latestSuccess == nil)
        #expect(empty.health.needsAttention)
        let recovered = JobSnapshot(jobID: id, history: [run(id, at: 300, status: .success),
                                                        run(id, at: 200, status: .failure)], isRunning: false)
        #expect(recovered.health == .success)
        #expect(!recovered.health.needsAttention)
    }

    @Test func schedulePresentationDistinguishesPausedDueAndRunning() {
        let now = Date(timeIntervalSince1970: 100_000)
        var job = BackupJob()
        job.createdAt = now
        #expect(BackupScheduleState(job: job, schedulerEnabled: false, isRunning: false, now: now) == .manual)
        job.schedule = .hourly
        #expect(BackupScheduleState(job: job, schedulerEnabled: false, isRunning: false, now: now) == .paused)
        #expect(BackupScheduleState(job: job, schedulerEnabled: true, isRunning: false, now: now)
                == .scheduled(now.addingTimeInterval(3600)))
        #expect(BackupScheduleState(job: job, schedulerEnabled: true, isRunning: true, now: now) == .afterCurrent)
        job.createdAt = now.addingTimeInterval(-4000)
        #expect(BackupScheduleState(job: job, schedulerEnabled: true, isRunning: false, now: now) == .due)
        job.isEnabled = false
        #expect(BackupScheduleState(job: job, schedulerEnabled: true, isRunning: false, now: now) == .paused)
    }

    @Test func setupOnlyValidatesTheCurrentStep() {
        var job = BackupJob()
        #expect(JobSetupStep.allCases.count == 3)
        #expect(JobSetupStep.source.validationKey(for: job) == "validation.choose_source")
        job.sourcePath = "/fixture/source"
        #expect(JobSetupStep.source.validationKey(for: job) == nil)
        #expect(JobSetupStep.destination.validationKey(for: job) == "validation.choose_destination")
        job.destinationPath = "/fixture/backups"
        job.nameMask = " "
        #expect(JobSetupStep.destination.validationKey(for: job) == "validation.name_mask")
        #expect(JobSetupStep.source.validationKey(for: job) == nil)
        #expect(JobSetupStep.schedule.validationKey(for: job) == nil)
    }

    @Test func setupValidatesOnlyRelevantConnectionFields() {
        var job = BackupJob()
        job.kind = .postgres
        job.databaseName = "fixture"
        job.username = "fixture"
        #expect(JobSetupStep.source.validationKey(for: job) == nil)
        job.connectionMode = .docker
        #expect(JobSetupStep.source.validationKey(for: job) == "validation.docker_container")
        job.dockerContainer = "db"
        #expect(JobSetupStep.source.validationKey(for: job) == nil)
        job.connectionMode = .ssh
        #expect(JobSetupStep.source.validationKey(for: job) == "validation.ssh_connection")
        job.sshHost = "example.invalid"
        job.sshUsername = "fixture"
        job.sshPort = 65536
        #expect(JobSetupStep.source.validationKey(for: job) == "ux.invalid_port")
        job.sshPort = 22
        #expect(JobSetupStep.source.validationKey(for: job) == nil)
        job.port = 0
        #expect(JobSetupStep.source.validationKey(for: job) == "ux.invalid_port")
        job.kind = .project
        job.sourcePath = "/fixture/project"
        #expect(JobSetupStep.source.validationKey(for: job) == nil)
    }

    @Test func allRedesignedStringsAreLocalized() {
        let keys = "not_run backup_created last_failed last_cancelled after_current waiting_scheduler invalid_port expanded collapsed attention backups last_success no_success open_job overview_hint backup_parameters create_backup elapsed first_backup_hint hide_log show_log more_actions schedule_open back next source_title destination_title schedule_title output_options output_options_hint retry".split(separator: " ")
        for language in L10n.supportedLanguages {
            for name in keys {
                let key = "ux.\(name)"
                #expect(L10n.text(key, language: language) != key)
            }
        }
    }

    @Test @MainActor func runningTimestampExistsOnlyDuringAnAttempt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("backupcron-ux-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BackupStore(stateDirectory: directory, passwordWriter: { _, _ in })
        var job = BackupJob()
        job.sourcePath = directory.appendingPathComponent("missing-source").path
        job.destinationPath = directory.appendingPathComponent("backups").path
        try store.addOrUpdate(job)
        store.run(job)
        #expect(store.startedAtByJob[job.id] != nil)
        store.cancel(job)
        let deadline = Date().addingTimeInterval(3)
        while store.runningJobIDs.contains(job.id), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!store.runningJobIDs.contains(job.id))
        #expect(store.startedAtByJob[job.id] == nil)
        #expect(store.history.first?.status == .cancelled)
    }
}

private actor ProgressRecorder {
    private var events: [BackupProgressEvent] = []

    func append(_ event: BackupProgressEvent) {
        events.append(event)
    }

    func snapshot() -> [BackupProgressEvent] {
        events
    }

    func contains(messagePart: String) -> Bool {
        events.contains { $0.message.contains(messagePart) }
    }
}

private actor BackupStartBarrier {
    private var arrivals = 0
    private var firstArrival: CheckedContinuation<Void, Never>?

    func arrive() async {
        arrivals += 1
        if arrivals == 2 {
            firstArrival?.resume()
            firstArrival = nil
        } else {
            await withCheckedContinuation { firstArrival = $0 }
        }
    }
}

private final class FakeLaunchAtLoginService: LaunchAtLoginService {
    var status: SMAppService.Status
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        registerCalls += 1
        status = .enabled
    }

    func unregister() throws {
        unregisterCalls += 1
        status = .notRegistered
    }
}

private final class FakeNotificationPermissionProvider: NotificationPermissionProviding {
    var state: NotificationPermissionState
    var requestResult: Bool
    private(set) var requestCalls = 0

    init(state: NotificationPermissionState, requestResult: Bool = true) {
        self.state = state
        self.requestResult = requestResult
    }

    func authorizationState() async -> NotificationPermissionState { state }

    func requestAuthorization() async throws -> Bool {
        requestCalls += 1
        state = requestResult ? .allowed : .denied
        return requestResult
    }
}

private func eventually(
    timeout: Duration = .seconds(5),
    condition: () async -> Bool
) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    repeat {
        if await condition() { return true }
        try await Task.sleep(for: .milliseconds(50))
    } while clock.now < deadline
    return await condition()
}

@discardableResult
private func dockerFixtureCommand(
    _ arguments: [String],
    environment: [String: String] = [:],
    input: URL? = nil
) throws -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
    process.arguments = ["--context", "desktop-linux"] + arguments
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
    process.standardOutput = pipe
    process.standardError = pipe
    let inputHandle = try input.map { try FileHandle(forReadingFrom: $0) }
    defer { try? inputHandle?.close() }
    process.standardInput = inputHandle ?? FileHandle.nullDevice
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: output, as: UTF8.self)
    try #require(process.terminationStatus == 0, "Docker fixture command failed: \(text)")
    return text
}

struct BackupScheduleTests {
    @discardableResult
    private func projectFixtureGit(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = directory
        process.arguments = [
            "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false",
            "-c", "user.name=BackupCron Fixture", "-c", "user.email=fixture@example.invalid"
        ] + arguments
        // Do not inherit user Git configuration, hooks, credentials, or GIT_DIR.
        process.environment = [
            "PATH": "/usr/bin:/bin", "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_ATTR_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "Git fixture command failed: \(output)")
        return output
    }

    private func unpackProjectFixture(_ output: URL, archive: Bool, into directory: URL) throws -> URL {
        guard archive else { return output }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", output.path, directory.path]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return directory.appendingPathComponent(output.deletingPathExtension().lastPathComponent)
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["BACKUPCRON_TEST_POSTGRES_CONTAINER"] != nil),
        arguments: [false, true], [false, true]
    )
    func realPostgresDumpRestoresAllFixtureRows(archive: Bool, excludesTables: Bool) async throws {
        let container = try #require(ProcessInfo.processInfo.environment["BACKUPCRON_TEST_POSTGRES_CONTAINER"])
        try await verifyDatabaseRoundTrip(kind: .postgres, container: container, archive: archive, excludesTables: excludesTables)
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["BACKUPCRON_TEST_MYSQL_CONTAINER"] != nil),
        arguments: [false, true], [false, true]
    )
    func realMySQLDumpRestoresAllFixtureRows(archive: Bool, excludesTables: Bool) async throws {
        let container = try #require(ProcessInfo.processInfo.environment["BACKUPCRON_TEST_MYSQL_CONTAINER"])
        try await verifyDatabaseRoundTrip(kind: .mysql, container: container, archive: archive, excludesTables: excludesTables)
    }

    private func verifyDatabaseRoundTrip(kind: BackupKind, container: String, archive: Bool, excludesTables: Bool) async throws {
        // Only an explicitly marked disposable container can receive test SQL.
        let label = try dockerFixtureCommand([
            "inspect", "--format", "{{ index .Config.Labels \"com.backupcron.integration\" }}", container
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        try #require(label == "true", "Integration tests require a disposable BackupCron container")

        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("backupcron-real-db-test-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        let identifier = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let sourceDatabase = "source_" + identifier
        let restoredDatabase = "restored_" + identifier
        let password = "backupcron-disposable-fixture"
        let passwordKey = kind == .postgres ? "PGPASSWORD" : "MYSQL_PWD"
        let environment = [passwordKey: password]
        let execArguments = ["exec", "-i", "-e", passwordKey, container]
        let client: [String] = kind == .postgres
            ? ["psql", "--host=127.0.0.1", "--username=backupcron", "--no-password", "--no-psqlrc", "--set=ON_ERROR_STOP=1"]
            : ["mysql", "--host=127.0.0.1", "--user=root", "--default-character-set=utf8mb4"]

        func sql(_ statement: String, database: String) throws -> String {
            let arguments = kind == .postgres
                ? client + ["--dbname=" + database, "--no-align", "--tuples-only", "--field-separator=\t", "--command=" + statement]
                : client + ["--batch", "--raw", "--skip-column-names", "--database=" + database, "--execute=" + statement]
            return try dockerFixtureCommand(execArguments + arguments, environment: environment)
        }

        let adminDatabase = kind == .postgres ? "postgres" : "mysql"
        _ = try sql("CREATE DATABASE " + sourceDatabase, database: adminDatabase)
        _ = try sql("CREATE DATABASE " + restoredDatabase, database: adminDatabase)
        defer {
            _ = try? sql("DROP DATABASE " + restoredDatabase, database: adminDatabase)
            _ = try? sql("DROP DATABASE " + sourceDatabase, database: adminDatabase)
        }
        _ = try sql("""
            CREATE TABLE records (id INTEGER PRIMARY KEY, value VARCHAR(100));
            INSERT INTO records VALUES (1, 'Привет BackupCron'), (2, 'quote''value'), (3, 'third row');
            CREATE TABLE records_child (id INTEGER PRIMARY KEY, record_id INTEGER, FOREIGN KEY(record_id) REFERENCES records(id));
            INSERT INTO records_child VALUES (1, 1);
            CREATE TABLE logs_match (id INTEGER PRIMARY KEY);
            """, database: sourceDatabase)
        let unusualName = kind == .postgres ? "logs.* \"雪'\n" : "logs `雪' data"
        let quote = kind == .postgres ? "\"" : "`"
        let quotedName = quote + unusualName.replacingOccurrences(of: quote, with: quote + quote) + quote
        _ = try sql("CREATE TABLE " + quotedName + " (id INTEGER PRIMARY KEY, payload TEXT); INSERT INTO " +
                    quotedName + " VALUES (1, 'excluded data'); CREATE VIEW logs_view AS SELECT id FROM " + quotedName,
                    database: sourceDatabase)
        if kind == .postgres {
            _ = try sql("CREATE TABLE events (id INTEGER) PARTITION BY RANGE (id); " +
                        "CREATE TABLE events_old PARTITION OF events FOR VALUES FROM (0) TO (10); " +
                        "INSERT INTO events VALUES (1);", database: sourceDatabase)
        }

        var job = BackupJob()
        job.name = "Integration backup"
        job.kind = kind
        job.connectionMode = .docker
        job.dockerContainer = container
        job.host = "127.0.0.1"
        job.port = kind == .postgres ? 5432 : 3306
        job.username = kind == .postgres ? "backupcron" : "root"
        job.databaseName = sourceDatabase
        job.destinationPath = root.appendingPathComponent("backups", isDirectory: true).path
        job.archiveOutput = archive
        job.nameMask = "snapshot"
        // MySQL's official fixture enables TLS with its generated certificate.
        // PostgreSQL's default image does not enable server-side TLS.
        job.useSSL = kind == .mysql
        var authenticationError = ""
        do {
            _ = try await BackupEngine().testConnection(job: job, password: "intentionally-invalid-fixture-password")
        } catch { authenticationError = error.localizedDescription }
        #expect(authenticationError.localizedCaseInsensitiveContains(
            kind == .postgres ? "password authentication failed" : "access denied"
        ))
        let connection = try await BackupEngine().testConnection(job: job, password: password)
        #expect(connection == L10n.text("engine.connection_ok"))
        let catalog = try await BackupEngine().inspectDatabase(job: job, password: password)
        #expect((catalog.sizeBytes ?? 0) > 0)
        let schema = kind == .postgres ? "public" : sourceDatabase
        let excludedTable = DatabaseTableReference(schema: schema, name: unusualName)
        let excludedView = DatabaseTableReference(schema: schema, name: "logs_view")
        #expect(catalog.tables.contains { $0.id == excludedTable && ($0.sizeBytes ?? 0) > 0 })
        #expect(catalog.selectionError(excluding: [excludedTable]) != nil)
        #expect(catalog.selectionError(excluding: [.init(schema: schema, name: "records")]) != nil)
        if excludesTables {
            job.excludedDatabaseTables = [excludedTable, excludedView]
            if kind == .postgres {
                job.excludedDatabaseTables.append(.init(schema: schema, name: "events"))
                // The run must discover this partition even though it was not
                // present when the user first loaded the table list.
                _ = try sql("CREATE TABLE events_new PARTITION OF events FOR VALUES FROM (10) TO (20); " +
                            "INSERT INTO events VALUES (11);", database: sourceDatabase)
            }
            #expect(catalog.selectionError(excluding: job.excludedDatabaseTables) == nil)
        }
        let result = try await BackupEngine().run(job: job, password: password)
        #expect((result.sizeBytes ?? 0) > 0)

        let dump: URL
        if archive {
            let extracted = root.appendingPathComponent("extracted", isDirectory: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", result.outputURL.path, extracted.path]
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0)
            dump = extracted.appendingPathComponent("snapshot.sql")
        } else {
            dump = result.outputURL
        }

        let targetArguments = kind == .postgres ? ["--dbname=" + restoredDatabase] : ["--database=" + restoredDatabase]
        try dockerFixtureCommand(execArguments + client + targetArguments, environment: environment, input: dump)
        let rows = try sql("SELECT id, value FROM records ORDER BY id", database: restoredDatabase)
        #expect(rows == "1\tПривет BackupCron\n2\tquote'value\n3\tthird row\n")
        #expect(try sql("SELECT COUNT(*) FROM " + quotedName, database: sourceDatabase) == "1\n")
        job.databaseName = restoredDatabase
        let restoredCatalog = try await BackupEngine().inspectDatabase(job: job, password: password)
        #expect(restoredCatalog.tables.contains { $0.name == unusualName } == !excludesTables)
        #expect(restoredCatalog.tables.contains { $0.name == "logs_view" } == !excludesTables)
        #expect(restoredCatalog.tables.contains { $0.name == "logs_match" })
        if kind == .postgres && excludesTables {
            #expect(!restoredCatalog.tables.contains { $0.name.hasPrefix("events") })
        }
    }

    @Test("All supported languages provide UI and error translations")
    func supportedLanguagesAreLocalized() {
        for language in L10n.supportedLanguages {
            #expect(L10n.text("common.new_job", language: language) != "common.new_job")
            #expect(L10n.text("engine.source_not_found", language: language) != "engine.source_not_found")
            for key in ["settings.notifications", "settings.notify_success", "settings.notify_failure",
                        "settings.notifications_note", "settings.notifications_requesting",
                        "settings.notifications_denied", "settings.notifications_error",
                        "settings.notifications_unavailable",
                        "notification.success_title", "notification.failure_title", "notification.result_body",
                        "common.close", "store.operation_failed", "store.keychain_failed",
                        "store.state_save_password_changed", "editor.include_git", "editor.include_git_hint",
                        "editor.git_excluded_warning", "editor.git_scope_note"] {
                #expect(L10n.text(key, language: language) != key)
            }
        }
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test @MainActor func launchAtLoginControllerTracksAndChangesServiceState() {
        let service = FakeLaunchAtLoginService(status: .requiresApproval)
        let controller = LaunchAtLoginController(service: service)
        #expect(controller.isEnabled)
        #expect(controller.requiresApproval)

        controller.setEnabled(false)
        #expect(controller.isEnabled == false)
        #expect(controller.requiresApproval == false)
        #expect(service.unregisterCalls == 1)

        controller.setEnabled(true)
        #expect(controller.isEnabled)
        #expect(service.registerCalls == 1)
    }

    @Test func manualJobIsNeverDue() {
        var job = BackupJob()
        job.schedule = .manual
        #expect(job.isDue(at: Date(), calendar: calendar) == false)
        #expect(job.nextRun(after: Date(), calendar: calendar) == nil)
    }

    @Test @MainActor func notificationPermissionIsRequestedOnlyOnExplicitEnable() async throws {
        let suiteName = "BackupCron.notification-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let permission = FakeNotificationPermissionProvider(state: .unknown)
        let controller = BackupNotificationSettingsController(permissionProvider: permission, defaults: defaults)

        await controller.refresh()
        #expect(!controller.notifyOnSuccess && !controller.notifyOnFailure)
        #expect(permission.requestCalls == 0)

        await controller.setNotifyOnSuccess(true)
        #expect(controller.notifyOnSuccess && !controller.notifyOnFailure)
        #expect(defaults.bool(forKey: BackupNotifications.notifyOnSuccessKey))
        #expect(permission.requestCalls == 1)
        #expect(!controller.isRequestingPermission)

        await controller.setNotifyOnFailure(true)
        await controller.setNotifyOnSuccess(false)
        #expect(!controller.notifyOnSuccess && controller.notifyOnFailure)
        #expect(!defaults.bool(forKey: BackupNotifications.notifyOnSuccessKey))
        #expect(defaults.bool(forKey: BackupNotifications.notifyOnFailureKey))
        #expect(permission.requestCalls == 1)

        let restored = BackupNotificationSettingsController(permissionProvider: permission, defaults: defaults)
        #expect(!restored.notifyOnSuccess && restored.notifyOnFailure)

        permission.state = .denied
        await controller.refresh()
        #expect(controller.permissionDenied)
        await controller.setNotifyOnSuccess(false)
        #expect(controller.permissionDenied)
        await controller.setNotifyOnFailure(false)
        #expect(!controller.permissionDenied)
    }

    @Test @MainActor func deniedNotificationPermissionDoesNotSaveEnabledPreference() async throws {
        let suiteName = "BackupCron.notification-denied-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let permission = FakeNotificationPermissionProvider(state: .unknown, requestResult: false)
        let controller = BackupNotificationSettingsController(permissionProvider: permission, defaults: defaults)

        await controller.setNotifyOnFailure(true)
        #expect(controller.permissionDenied)
        #expect(!controller.notifyOnFailure)
        #expect(!defaults.bool(forKey: BackupNotifications.notifyOnFailureKey))
        #expect(!controller.isRequestingPermission)
        #expect(permission.requestCalls == 1)

        await controller.setNotifyOnSuccess(true)
        #expect(!controller.notifyOnSuccess)
        #expect(controller.permissionDenied)
        #expect(permission.requestCalls == 1)
    }

    @Test func notificationPreferencesFilterSuccessFailureAndCancellation() {
        for success in [false, true] {
            for failure in [false, true] {
                #expect(BackupNotifications.shouldNotify(status: .success, successEnabled: success, failureEnabled: failure) == success)
                #expect(BackupNotifications.shouldNotify(status: .failure, successEnabled: success, failureEnabled: failure) == failure)
                #expect(!BackupNotifications.shouldNotify(status: .cancelled, successEnabled: success, failureEnabled: failure))
            }
        }
    }

    @Test func unbundledExecutablesDoNotInitializeSystemNotifications() async throws {
        // SwiftPM runs this test executable outside an .app, just like swift run.
        guard Bundle.main.bundleURL.pathExtension != "app" else { return }
        #expect(BackupNotifications.center == nil)
        BackupNotifications.configure()
        let permission = SystemNotificationPermissionProvider()
        #expect(await permission.authorizationState() == .unavailable)
        #expect(try await permission.requestAuthorization() == false)

        let suiteName = "BackupCron.notification-unbundled-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: BackupNotifications.notifyOnSuccessKey)
        BackupNotifications.post(BackupRun(
            jobID: UUID(), jobName: "Test", startedAt: Date(), finishedAt: Date(),
            status: .success, message: "Complete"
        ), defaults: defaults)
    }

    @Test func hourlyJobBecomesDueAfterOneHour() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var job = BackupJob()
        job.schedule = .hourly
        job.createdAt = start

        #expect(job.isDue(at: start.addingTimeInterval(3_599), calendar: calendar) == false)
        #expect(job.isDue(at: start.addingTimeInterval(3_600), calendar: calendar))
    }

    @Test func customIntervalBecomesDueAndCalculatesTheNextSlotDirectly() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var job = BackupJob()
        job.schedule = .interval
        job.intervalMinutes = 15
        job.createdAt = start

        #expect(job.isDue(at: start.addingTimeInterval(899), calendar: calendar) == false)
        #expect(job.isDue(at: start.addingTimeInterval(900), calendar: calendar))
        #expect(job.nextRun(after: start.addingTimeInterval(900), calendar: calendar) == start.addingTimeInterval(1_800))

        let farFuture = start.addingTimeInterval(900 * 1_000_000 + 17)
        #expect(job.nextRun(after: farFuture, calendar: calendar) == start.addingTimeInterval(900 * 1_000_001))
    }

    @Test func disabledJobHasNoNextRun() {
        var job = BackupJob()
        job.schedule = .daily
        job.isEnabled = false
        #expect(job.nextRun(after: Date(), calendar: calendar) == nil)
    }

    @Test func dailyJobRunsOnceAfterScheduledTime() {
        let dayStart = Date(timeIntervalSince1970: 1_699_920_000)
        var job = BackupJob()
        job.schedule = .daily
        job.scheduledTime = calendar.date(byAdding: .hour, value: 2, to: dayStart)!
        job.createdAt = calendar.date(byAdding: .day, value: -1, to: dayStart)!

        #expect(job.isDue(at: calendar.date(byAdding: .hour, value: 1, to: dayStart)!, calendar: calendar) == false)
        #expect(job.isDue(at: calendar.date(byAdding: .hour, value: 3, to: dayStart)!, calendar: calendar))

        job.lastRunAt = calendar.date(byAdding: .hour, value: 2, to: dayStart)!
        #expect(job.isDue(at: calendar.date(byAdding: .hour, value: 3, to: dayStart)!, calendar: calendar) == false)
    }

    @Test func fileBackupCreatesZipArchive() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("backupflow-test-\(UUID().uuidString)")
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("backups", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("Проверка BackupFlow".utf8).write(to: source.appendingPathComponent("note.txt"))

        var job = BackupJob()
        job.name = "Test files"
        job.kind = .files
        job.sourcePath = source.path
        job.destinationPath = destination.path

        let recorder = ProgressRecorder()
        let result = try await BackupEngine().run(job: job, password: "") { event in
            await recorder.append(event)
        }
        #expect(result.outputURL.pathExtension == "zip")
        #expect(fileManager.fileExists(atPath: result.outputURL.path))
        #expect((result.sizeBytes ?? 0) > 0)

        let events = await recorder.snapshot()
        #expect(events.first?.fraction == 0.02)
        #expect(events.last?.fraction == 1)
        #expect(events.contains { $0.message == L10n.text("log.running_command", "ditto") })
        #expect(events.contains { $0.message == L10n.text("log.verifying") })
        #expect(events.contains { $0.message.hasPrefix(L10n.text("log.verified", "").replacingOccurrences(of: " · ", with: "")) })
    }

    @Test @MainActor func jobsBeyondTheFormerLimitPersistWithoutPurchases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("backupcron-unlimited-jobs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BackupStore(stateDirectory: root, passwordWriter: { _, _ in })
        for index in 1...10 {
            var job = BackupJob()
            job.name = "Open-source job \(index)"
            job.createdAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            job.scheduledTime = Date(timeIntervalSince1970: 1_700_000_000)
            try store.addOrUpdate(job)
        }
        #expect(store.jobs.count == 10)
        let reloaded = BackupStore(stateDirectory: root, passwordWriter: { _, _ in })
        #expect(reloaded.jobs == store.jobs)
    }

    @Test func oldJobsDecodeWithDirectConnectionDefaults() throws {
        let job = try JSONDecoder().decode(BackupJob.self, from: Data("{}".utf8))
        #expect(job.connectionMode == .direct)
        #expect(job.useSSL == false)
        #expect(job.sshPort == 22)
        #expect(job.intervalMinutes == 60)
        #expect(job.archiveOutput)
        #expect(job.nameMask == BackupJob.defaultNameMask)
        #expect(job.retentionCount == 0)
        #expect(job.projectExclusions == ".git, node_modules, vendor, .build, DerivedData")
        #expect(!job.includesGitMetadata)
        #expect(job.sourceBookmark == nil)
        #expect(job.destinationBookmark == nil)
    }

    @Test func newProjectJobsIncludeGitAndPersistTheirDefaults() throws {
        var job = BackupJob()
        job.kind = .project
        #expect(job.projectExclusions == "node_modules, vendor, .build, DerivedData")
        #expect(job.includesGitMetadata)
        let decoded = try JSONDecoder().decode(BackupJob.self, from: JSONEncoder().encode(job))
        #expect(decoded == job)
        #expect(decoded.includesGitMetadata)
    }

    @Test(arguments: ["{\"kind\":\"project\"}", "{\"kind\":\"project\",\"projectExclusions\":null}"])
    func legacyProjectJobsKeepTheirOriginalGitExclusion(json: String) throws {
        let job = try JSONDecoder().decode(BackupJob.self, from: Data(json.utf8))
        #expect(job.projectExclusions == ".git, node_modules, vendor, .build, DerivedData")
        #expect(!job.includesGitMetadata)
        let decoded = try JSONDecoder().decode(BackupJob.self, from: JSONEncoder().encode(job))
        #expect(decoded == job)
    }

    @Test(arguments: ["", ".git, node_modules", "vendor", " .github ; .gitignore\ncustom cache "])
    func existingProjectExclusionsAreNotRewritten(exclusions: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["kind": "project", "projectExclusions": exclusions])
        let job = try JSONDecoder().decode(BackupJob.self, from: data)
        #expect(job.projectExclusions == exclusions)
        let decoded = try JSONDecoder().decode(BackupJob.self, from: JSONEncoder().encode(job))
        #expect(decoded.projectExclusions == exclusions)
    }

    @Test(arguments: [",", ";", "\n"])
    func gitToggleUsesExactNamesAndKeepsOtherExclusions(separator: String) throws {
        var job = BackupJob()
        job.projectExclusions = [" .git ", ".github", ".gitignore", "custom cache", ".git"].joined(separator: separator)
        #expect(!job.includesGitMetadata)
        let unchanged = job.projectExclusions
        job.includesGitMetadata = false
        #expect(job.projectExclusions == unchanged)
        job.includesGitMetadata = true
        #expect(job.includesGitMetadata)
        #expect(job.projectExclusions == ".github, .gitignore, custom cache")
        job.includesGitMetadata = true
        #expect(job.projectExclusions == ".github, .gitignore, custom cache")
        job.includesGitMetadata = false
        #expect(!job.includesGitMetadata)
        #expect(job.projectExclusions == ".github, .gitignore, custom cache, .git")
        let decoded = try JSONDecoder().decode(BackupJob.self, from: JSONEncoder().encode(job))
        #expect(decoded == job)
        #expect(!decoded.includesGitMetadata)
    }

    @Test func gitToggleHandlesEmptyExclusionsAndDirectListEdits() {
        var job = BackupJob()
        job.projectExclusions = ""
        #expect(job.includesGitMetadata)
        job.includesGitMetadata = false
        #expect(job.projectExclusions == ".git")
        job.includesGitMetadata = true
        #expect(job.projectExclusions.isEmpty)
        job.projectExclusions = ".github; .gitignore\n.gitmodules"
        #expect(job.includesGitMetadata)
        job.projectExclusions += " ; .git "
        #expect(!job.includesGitMetadata)
    }

    @Test func outputNameMaskExpandsAndSanitizesTokens() {
        var job = BackupJob()
        job.name = "Client Site"
        job.kind = .project
        job.nameMask = "{job}_{type}_{date}_{time}"

        let name = BackupNaming.render(
            mask: job.nameMask,
            job: job,
            date: Date(timeIntervalSince1970: 0),
            calendar: calendar
        )
        #expect(name == "Client-Site_project_1970-01-01_00-00-00")
    }

    @Test func tokensInsideJobNamesRemainLiteral() {
        var job = BackupJob()
        job.name = "Release {date} {time} {type}"
        job.kind = .project
        let rendered = BackupNaming.render(
            mask: "{job}-{type}-{job}-{date}", job: job,
            date: Date(timeIntervalSince1970: 0), calendar: calendar
        )
        #expect(rendered == "Release-date-time-type-project-Release-date-time-type-1970-01-01")
    }

    @Test(arguments: [false, true])
    func dottedFolderNamesUseTheSameExtensionAsThePreview(archive: Bool) async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("backupcron-dotted-folder-test-\(UUID().uuidString)")
        let source = root.appendingPathComponent("project.v2", isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("content".utf8).write(to: source.appendingPathComponent("readme.txt"))
        var job = BackupJob()
        job.sourcePath = source.path
        job.destinationPath = root.appendingPathComponent("backups").path
        job.nameMask = "snapshot"
        job.archiveOutput = archive
        let fileExtension = BackupNaming.outputExtension(for: job, sourceIsDirectory: true)
        let preview = fileExtension.isEmpty ? "snapshot" : "snapshot." + fileExtension
        #expect(preview == (archive ? "snapshot.zip" : "snapshot"))
        let result = try await BackupEngine().run(job: job, password: "")
        #expect(result.outputURL.lastPathComponent == preview)
        if !archive {
            #expect(try Data(contentsOf: result.outputURL.appendingPathComponent("readme.txt")) == Data("content".utf8))
        }
    }

    @Test func retentionRemovesOnlyOldOutputsForTheSameJobAndDestination() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("backupcron-retention-test-\(UUID().uuidString)")
        let destination = root.appendingPathComponent("backups", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)

        let newest = destination.appendingPathComponent("newest.zip")
        let second = destination.appendingPathComponent("second.zip")
        let oldest = destination.appendingPathComponent("oldest", isDirectory: true)
        let unrelated = destination.appendingPathComponent("unrelated.zip")
        let failed = destination.appendingPathComponent("failed.zip")
        let external = outside.appendingPathComponent("external.zip")
        for url in [newest, second, unrelated, failed, external] {
            try Data(url.lastPathComponent.utf8).write(to: url)
        }
        try fileManager.createDirectory(at: oldest, withIntermediateDirectories: true)
        try Data("project".utf8).write(to: oldest.appendingPathComponent("main.swift"))

        let jobID = UUID()
        let otherJobID = UUID()
        func makeRun(
            name: String,
            jobID: UUID,
            status: BackupStatus,
            output: URL,
            finishedAt: TimeInterval
        ) -> BackupRun {
            BackupRun(
                jobID: jobID,
                jobName: name,
                startedAt: Date(timeIntervalSince1970: finishedAt - 1),
                finishedAt: Date(timeIntervalSince1970: finishedAt),
                status: status,
                outputPath: output.path,
                message: "created"
            )
        }

        var history = [
            makeRun(name: "oldest", jobID: jobID, status: .success, output: oldest, finishedAt: 100),
            makeRun(name: "external", jobID: jobID, status: .success, output: external, finishedAt: 50),
            makeRun(name: "failed", jobID: jobID, status: .failure, output: failed, finishedAt: 400),
            makeRun(name: "newest", jobID: jobID, status: .success, output: newest, finishedAt: 300),
            makeRun(name: "unrelated", jobID: otherJobID, status: .success, output: unrelated, finishedAt: 500),
            makeRun(name: "second", jobID: jobID, status: .success, output: second, finishedAt: 200)
        ]

        var disabledHistory = history
        let disabledRemovalCount = BackupRetention.prune(
            jobID: jobID,
            destinationURL: destination,
            keepCount: 0,
            history: &disabledHistory,
            fileManager: fileManager
        )
        #expect(disabledRemovalCount == 0)
        #expect(fileManager.fileExists(atPath: oldest.path))

        let removedCount = BackupRetention.prune(
            jobID: jobID,
            destinationURL: destination,
            keepCount: 2,
            history: &history,
            fileManager: fileManager
        )

        #expect(removedCount == 1)
        #expect(fileManager.fileExists(atPath: oldest.path) == false)
        #expect(fileManager.fileExists(atPath: newest.path))
        #expect(fileManager.fileExists(atPath: second.path))
        #expect(fileManager.fileExists(atPath: unrelated.path))
        #expect(fileManager.fileExists(atPath: failed.path))
        #expect(fileManager.fileExists(atPath: external.path))
        #expect(history.first(where: { $0.jobName == "oldest" })?.outputPath == nil)
        #expect(history.first(where: { $0.jobName == "oldest" })?.message == L10n.text("history.removed_by_retention"))
    }

    @Test func retentionSettingRoundTripsThroughPersistence() throws {
        var job = BackupJob()
        job.retentionCount = 12
        job.schedule = .interval
        job.intervalMinutes = 25
        let encoded = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(BackupJob.self, from: encoded)
        #expect(decoded.retentionCount == 12)
        #expect(decoded.schedule == .interval)
        #expect(decoded.intervalMinutes == 25)
    }

    @Test func persistedCustomIntervalIsClampedToSafeBounds() throws {
        let tooShort = try JSONDecoder().decode(
            BackupJob.self,
            from: Data("{\"schedule\":\"interval\",\"intervalMinutes\":1}".utf8)
        )
        let tooLong = try JSONDecoder().decode(
            BackupJob.self,
            from: Data("{\"schedule\":\"interval\",\"intervalMinutes\":9999}".utf8)
        )
        #expect(tooShort.intervalMinutes == BackupJob.minimumIntervalMinutes)
        #expect(tooLong.intervalMinutes == BackupJob.maximumIntervalMinutes)
    }

    @Test func securityScopedBookmarkResolvesAndPersists() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("backupcron-bookmark-test-\(UUID().uuidString)")
        let source = root.appendingPathComponent("source.txt")
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("bookmark".utf8).write(to: source)

        let bookmark = try #require(SecurityScopedBookmark.create(for: source))
        let resolved = try #require(bookmark.resolve(matching: source.path))
        #expect(resolved.standardizedFileURL.path == source.standardizedFileURL.path)
        #expect(bookmark.resolve(matching: root.appendingPathComponent("changed.txt").path) == nil)

        var job = BackupJob()
        job.sourcePath = source.path
        job.sourceBookmark = bookmark
        let data = try JSONEncoder().encode(job)
        let restoredJob = try JSONDecoder().decode(BackupJob.self, from: data)
        #expect(restoredJob.sourceBookmark == bookmark)
    }

    @Test func filesCanBeCopiedWithoutArchive() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("backupcron-copy-test-\(UUID().uuidString)")
        let source = root.appendingPathComponent("note.txt")
        let destination = root.appendingPathComponent("backups", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("BackupCron".utf8).write(to: source)

        var job = BackupJob()
        job.name = "My Notes"
        job.kind = .files
        job.sourcePath = source.path
        job.destinationPath = destination.path
        job.archiveOutput = false
        job.nameMask = "manual-{job}"

        let result = try await BackupEngine().run(job: job, password: "")
        #expect(result.outputURL.lastPathComponent == "manual-My-Notes.txt")
        #expect(try Data(contentsOf: result.outputURL) == Data("BackupCron".utf8))
    }

    @Test(arguments: [false, true], [false, true])
    func projectBackupAppliesExclusions(archive: Bool, useGitToggle: Bool) async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("backupcron-project-test-\(UUID().uuidString)")
        let source = root.appendingPathComponent("project", isDirectory: true)
        let destination = root.appendingPathComponent("backups", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: source.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: source.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: source.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("main".utf8).write(to: source.appendingPathComponent("Sources/main.swift"))
        try Data("dependency".utf8).write(to: source.appendingPathComponent("node_modules/pkg/index.js"))
        try Data("git".utf8).write(to: source.appendingPathComponent(".git/config"))

        var job = BackupJob()
        job.name = "Website"
        job.kind = .project
        job.sourcePath = source.path
        job.destinationPath = destination.path
        job.archiveOutput = archive
        job.nameMask = "{job}-copy"
        if useGitToggle {
            job.includesGitMetadata = false
        } else {
            job.projectExclusions = ".git, node_modules"
        }

        let result = try await BackupEngine().run(job: job, password: "")
        let copiedProject: URL
        if archive {
            let extracted = root.appendingPathComponent("extracted", isDirectory: true)
            let extractor = Process()
            extractor.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            extractor.arguments = ["-x", "-k", result.outputURL.path, extracted.path]
            try extractor.run()
            extractor.waitUntilExit()
            #expect(extractor.terminationStatus == 0)
            copiedProject = extracted.appendingPathComponent("Website-copy")
        } else {
            copiedProject = result.outputURL
        }
        #expect(try Data(contentsOf: copiedProject.appendingPathComponent("Sources/main.swift")) == Data("main".utf8))
        #expect(fileManager.fileExists(atPath: copiedProject.appendingPathComponent("node_modules").path) == false)
        #expect(fileManager.fileExists(atPath: copiedProject.appendingPathComponent(".git").path) == false)
    }

    @Test(arguments: [false, true])
    func defaultProjectBackupPreservesUsableGitHistory(archive: Bool) async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("backupcron-git-project-\(UUID().uuidString)")
        let source = root.appendingPathComponent("project")
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: source.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try manager.createDirectory(at: source.appendingPathComponent(".github/workflows"), withIntermediateDirectories: true)
        try Data("first version".utf8).write(to: source.appendingPathComponent("Sources/main.swift"))
        try Data("workflow".utf8).write(to: source.appendingPathComponent(".github/workflows/ci.yml"))
        try Data("node_modules/\n".utf8).write(to: source.appendingPathComponent(".gitignore"))
        try projectFixtureGit(["init", "--template=", "--initial-branch=main"], in: source)
        try projectFixtureGit(["add", "."], in: source)
        try projectFixtureGit(["commit", "-m", "First local commit"], in: source)
        try projectFixtureGit(["branch", "feature/local-only"], in: source)
        try Data("second version".utf8).write(to: source.appendingPathComponent("Sources/main.swift"))
        try projectFixtureGit(["commit", "-am", "Second local commit"], in: source)
        let head = try projectFixtureGit(["rev-parse", "HEAD"], in: source)
        let branch = try projectFixtureGit(["rev-parse", "feature/local-only"], in: source)
        try Data("uncommitted work".utf8).write(to: source.appendingPathComponent("Sources/main.swift"))
        for name in ["node_modules", "vendor", ".build", "DerivedData"] {
            let directory = source.appendingPathComponent(name)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("regenerable".utf8).write(to: directory.appendingPathComponent("cache"))
        }

        var job = BackupJob()
        job.kind = .project
        job.sourcePath = source.path
        job.destinationPath = root.appendingPathComponent("backups").path
        job.nameMask = "project-copy"
        job.archiveOutput = archive
        let result = try await BackupEngine().run(job: job, password: "")
        let copy = try unpackProjectFixture(result.outputURL, archive: archive, into: root.appendingPathComponent("extracted"))

        #expect(try projectFixtureGit(["rev-parse", "HEAD"], in: copy) == head)
        #expect(try projectFixtureGit(["rev-parse", "feature/local-only"], in: copy) == branch)
        #expect(try projectFixtureGit(["show", "HEAD~1:Sources/main.swift"], in: copy) == "first version")
        #expect(try projectFixtureGit(["show", "HEAD:Sources/main.swift"], in: copy) == "second version")
        try projectFixtureGit(["fsck", "--full"], in: copy)
        #expect(try Data(contentsOf: copy.appendingPathComponent("Sources/main.swift")) == Data("uncommitted work".utf8))
        #expect(try Data(contentsOf: copy.appendingPathComponent(".github/workflows/ci.yml")) == Data("workflow".utf8))
        #expect(try Data(contentsOf: copy.appendingPathComponent(".gitignore")) == Data("node_modules/\n".utf8))
        for name in ["node_modules", "vendor", ".build", "DerivedData"] {
            #expect(!manager.fileExists(atPath: copy.appendingPathComponent(name).path))
        }
    }

    @Test(arguments: [false, true])
    func projectGitPointerDoesNotCopyDataOutsideSelectedFolder(archive: Bool) async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("backupcron-git-pointer-\(UUID().uuidString)")
        let source = root.appendingPathComponent("project")
        let external = root.appendingPathComponent("external.git/objects")
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: source, withIntermediateDirectories: true)
        try manager.createDirectory(at: external, withIntermediateDirectories: true)
        let pointer = Data("gitdir: ../external.git\n".utf8)
        try pointer.write(to: source.appendingPathComponent(".git"))
        try Data("outside selected scope".utf8).write(to: external.appendingPathComponent("private-object"))
        var job = BackupJob()
        job.kind = .project
        job.sourcePath = source.path
        job.destinationPath = root.appendingPathComponent("backups").path
        job.nameMask = "pointer-copy"
        job.archiveOutput = archive
        let result = try await BackupEngine().run(job: job, password: "")
        let copy = try unpackProjectFixture(result.outputURL, archive: archive, into: root.appendingPathComponent("extracted"))
        #expect(try manager.contentsOfDirectory(atPath: copy.path) == [".git"])
        #expect(try Data(contentsOf: copy.appendingPathComponent(".git")) == pointer)
        #expect(try Data(contentsOf: external.appendingPathComponent("private-object")) == Data("outside selected scope".utf8))
    }

    @Test(arguments: [false, true])
    func concurrentBackupsWithTheSameMaskPreserveBothOutputs(archive: Bool) async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("backupcron-collision-test-\(UUID().uuidString)")
        let destination = root.appendingPathComponent("backups", isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let firstSource = root.appendingPathComponent("first.txt")
        let secondSource = root.appendingPathComponent("second.txt")
        try Data("first backup".utf8).write(to: firstSource)
        try Data("second backup".utf8).write(to: secondSource)

        var firstJob = BackupJob()
        firstJob.sourcePath = firstSource.path
        firstJob.destinationPath = destination.path
        firstJob.nameMask = "same-name"
        firstJob.archiveOutput = archive
        var secondJob = firstJob
        secondJob.id = UUID()
        secondJob.sourcePath = secondSource.path

        let barrier = BackupStartBarrier()
        let progress: BackupEngine.ProgressHandler = { event in
            if event.fraction > 0.15 && event.fraction < 0.4 {
                await barrier.arrive()
            }
        }
        let firstConfiguration = firstJob
        let secondConfiguration = secondJob
        async let first = BackupEngine().run(job: firstConfiguration, password: "", onProgress: progress)
        async let second = BackupEngine().run(job: secondConfiguration, password: "", onProgress: progress)
        let outputs = try await (first, second)
        #expect(outputs.0.outputURL != outputs.1.outputURL)

        for (result, source, expected) in [
            (outputs.0, firstSource, "first backup"),
            (outputs.1, secondSource, "second backup")
        ] {
            if archive {
                let reader = Process()
                let pipe = Pipe()
                reader.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                reader.arguments = ["-p", result.outputURL.path, source.lastPathComponent]
                reader.standardOutput = pipe
                try reader.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                reader.waitUntilExit()
                #expect(reader.terminationStatus == 0)
                #expect(data == Data(expected.utf8))
            } else {
                #expect(try Data(contentsOf: result.outputURL) == Data(expected.utf8))
            }
        }
        #expect(try manager.contentsOfDirectory(atPath: destination.path).count == 2)
    }

    @Test(arguments: [BackupKind.files, .project], [false, true])
    func destinationInsideSourceIsRejectedThroughASymlink(kind: BackupKind, archive: Bool) async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("backupcron-nesting-test-\(UUID().uuidString)")
        let source = root.appendingPathComponent("project", isDirectory: true)
        let alias = root.appendingPathComponent("shortcut")
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: source.appendingPathComponent("source.txt"))
        try manager.createSymbolicLink(at: alias, withDestinationURL: source)

        var job = BackupJob()
        job.kind = kind
        job.archiveOutput = archive
        job.sourcePath = source.path
        job.destinationPath = alias.appendingPathComponent("backups").path
        var rejection: String?
        do {
            _ = try await BackupEngine().run(job: job, password: "")
        } catch { rejection = error.localizedDescription }
        #expect(rejection == L10n.text("engine.destination_inside_source"))
        #expect(!manager.fileExists(atPath: source.appendingPathComponent("backups").path))
    }

    @Test(arguments: [false, true])
    func unreadableProjectDirectoryFailsInsteadOfPublishingAPartialBackup(archive: Bool) async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("backupcron-unreadable-test-\(UUID().uuidString)")
        let source = root.appendingPathComponent("project", isDirectory: true)
        let locked = source.appendingPathComponent("locked", isDirectory: true)
        let destination = root.appendingPathComponent("backups", isDirectory: true)
        defer {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
            try? manager.removeItem(at: root)
        }
        try manager.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("must be backed up".utf8).write(to: locked.appendingPathComponent("important.txt"))
        try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        #expect(!manager.isReadableFile(atPath: locked.path))

        var job = BackupJob()
        job.kind = .project
        job.sourcePath = source.path
        job.destinationPath = destination.path
        job.archiveOutput = archive
        var failed = false
        do {
            _ = try await BackupEngine().run(job: job, password: "")
        } catch { failed = true }
        #expect(failed)
        #expect(try manager.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    @Test func publishingPreservesAnExistingFileAndDanglingSymlink() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("backupcron-existing-test-\(UUID().uuidString)")
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("backups", isDirectory: true)
        let existing = destination.appendingPathComponent("snapshot.txt")
        let symlink = destination.appendingPathComponent("snapshot-2.txt")
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("new backup".utf8).write(to: source)
        try Data("previous backup".utf8).write(to: existing)
        try manager.createSymbolicLink(atPath: symlink.path, withDestinationPath: "missing-target")

        var job = BackupJob()
        job.sourcePath = source.path
        job.destinationPath = destination.path
        job.nameMask = "snapshot"
        job.archiveOutput = false
        let result = try await BackupEngine().run(job: job, password: "")
        #expect(result.outputURL.lastPathComponent == "snapshot-3.txt")
        #expect(try Data(contentsOf: result.outputURL) == Data("new backup".utf8))
        #expect(try Data(contentsOf: existing) == Data("previous backup".utf8))
        #expect(try manager.destinationOfSymbolicLink(atPath: symlink.path) == "missing-target")
    }

    @Test(arguments: [false, true])
    func sqliteBackupCanBeOpenedAfterCopyOrArchiveExtraction(archive: Bool) async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("backupcron-sqlite-test-\(UUID().uuidString)")
        let source = root.appendingPathComponent("source.sqlite3")
        let destination = root.appendingPathComponent("backups", isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let writer = Process()
        writer.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        writer.arguments = [source.path, "CREATE TABLE records (value TEXT); INSERT INTO records VALUES ('restore me');"]
        try writer.run()
        writer.waitUntilExit()
        #expect(writer.terminationStatus == 0)

        var job = BackupJob()
        job.kind = .sqlite
        job.sourcePath = source.path
        job.destinationPath = destination.path
        job.nameMask = "snapshot"
        job.archiveOutput = archive
        let result = try await BackupEngine().run(job: job, password: "")
        let restored: URL
        if archive {
            let extracted = root.appendingPathComponent("restored", isDirectory: true)
            let extractor = Process()
            extractor.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            extractor.arguments = ["-x", "-k", result.outputURL.path, extracted.path]
            try extractor.run()
            extractor.waitUntilExit()
            #expect(extractor.terminationStatus == 0)
            restored = extracted.appendingPathComponent("snapshot.sqlite3")
        } else {
            restored = result.outputURL
        }
        #expect(manager.fileExists(atPath: restored.path))
        let reader = Process()
        let pipe = Pipe()
        reader.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        reader.arguments = ["-readonly", restored.path, "SELECT value FROM records; PRAGMA integrity_check;"]
        reader.standardOutput = pipe
        try reader.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        reader.waitUntilExit()
        #expect(reader.terminationStatus == 0)
        #expect(String(decoding: data, as: UTF8.self) == "restore me\nok\n")
    }

    @Test func cancellationBeforePublicationRemovesOnlyThisRunsWorkFiles() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("backupcron-publish-cancel-test-\(UUID().uuidString)")
        let destination = root.appendingPathComponent("backups", isDirectory: true)
        let source = root.appendingPathComponent("source.txt")
        let existing = destination.appendingPathComponent("snapshot.txt")
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: source)
        try Data("previous backup".utf8).write(to: existing)
        var job = BackupJob()
        job.sourcePath = source.path
        job.destinationPath = destination.path
        job.nameMask = "snapshot"
        job.archiveOutput = false
        let configuration = job
        let run = Task {
            try await BackupEngine().run(job: configuration, password: "") { event in
                if event.fraction == 0.98 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        var cancelled = false
        do { _ = try await run.value } catch { cancelled = error is CancellationError }
        #expect(cancelled)
        #expect(try manager.contentsOfDirectory(atPath: destination.path) == ["snapshot.txt"])
        #expect(try Data(contentsOf: existing) == Data("previous backup".utf8))
    }

    @Test func postgresConnectionTestUsesSchemaOnlyAndNeedsNoDestination() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("backupcron-postgres-connection-test-\(UUID().uuidString)")
        let fakeDump = root.appendingPathComponent("pg_dump")
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        output=""
        schema_only=0
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--file" ]; then
            shift
            output="$1"
          elif [ "$1" = "--schema-only" ]; then
            schema_only=1
          fi
          shift
        done
        [ "$schema_only" -eq 1 ] || exit 7
        [ -n "$output" ] || exit 8
        [ "$PGPASSWORD" = "secret" ] || exit 9
        [ "$PGSSLMODE" = "require" ] || exit 10
        printf 'schema' > "$output"
        """
        try Data(script.utf8).write(to: fakeDump)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeDump.path)

        var job = BackupJob()
        job.kind = .postgres
        job.host = "database.example"
        job.username = "backup"
        job.databaseName = "app"
        job.destinationPath = ""
        job.clientExecutablePath = fakeDump.path
        job.useSSL = true

        let message = try await BackupEngine().testConnection(job: job, password: "secret")
        #expect(message == L10n.text("engine.connection_ok"))
    }

    @Test @MainActor func savingOtherJobSettingsPreservesAnUneditedPassword() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("backupcron-password-save-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var storedPasswords: [UUID: String] = [:]
        var writes = 0
        let store = BackupStore(stateDirectory: root) { value, id in
            storedPasswords[id] = value
            writes += 1
        }
        var job = BackupJob()
        job.kind = .postgres
        try store.addOrUpdate(job, password: "saved credential")
        job.name = "Renamed without editing the password"
        try store.addOrUpdate(job)
        #expect(storedPasswords[job.id] == "saved credential")
        #expect(writes == 1)
        #expect(store.jobs.count == 1)
        #expect(store.jobs.first?.name == job.name)

        try store.addOrUpdate(job, password: "")
        #expect(storedPasswords[job.id] == "")
        #expect(writes == 2)
        try store.addOrUpdate(job, password: "new credential")
        #expect(storedPasswords[job.id] == "new credential")
        #expect(writes == 3)
    }

    @Test @MainActor func failedPasswordSavePreservesThePersistedJob() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("backupcron-save-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var rejectPassword = false
        let store = BackupStore(stateDirectory: root) { _, _ in
            if rejectPassword { throw KeychainStore.AccessError(status: errSecInteractionNotAllowed) }
        }
        var job = BackupJob()
        job.kind = .postgres
        try store.addOrUpdate(job, password: "fixture")
        let original = try Data(contentsOf: root.appendingPathComponent("state.json"))
        rejectPassword = true
        job.name = "Unsaved draft"
        #expect(throws: KeychainStore.AccessError.self) {
            try store.addOrUpdate(job, password: "changed fixture")
        }
        #expect(store.jobs.first?.name != job.name)
        #expect(try Data(contentsOf: root.appendingPathComponent("state.json")) == original)
        rejectPassword = false
        try store.addOrUpdate(job, password: "changed fixture")
        #expect(store.jobs.first?.name == job.name)
        let reloaded = BackupStore(stateDirectory: root, passwordWriter: { _, _ in })
        #expect(reloaded.jobs.first?.name == job.name)
    }

    @Test(arguments: [false, true]) @MainActor
    func failedStateSaveReportsPartialPasswordUpdateAndAllowsRetry(changePassword: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("backupcron-state-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        // A regular file cannot be used as the application's state directory.
        try Data("fixture".utf8).write(to: root)
        var writes = 0
        let store = BackupStore(stateDirectory: root) { _, _ in writes += 1 }
        var job = BackupJob()
        job.kind = .postgres
        let password = changePassword ? "fixture" : nil
        do {
            try store.addOrUpdate(job, password: password)
            Issue.record("A failed state write was reported as successful")
        } catch let error as BackupStore.SaveError {
            #expect(error.passwordChanged == changePassword)
            #expect(!error.localizedDescription.isEmpty)
        }
        #expect(store.jobs.isEmpty)
        #expect(writes == (changePassword ? 1 : 0))
        try FileManager.default.removeItem(at: root)
        try store.addOrUpdate(job, password: password)
        #expect(store.jobs.count == 1)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("state.json").path))
    }

    @Test @MainActor func failedDeleteAndToggleKeepTheJobInMemory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("backupcron-delete-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var passwordWrites = 0
        let store = BackupStore(stateDirectory: root) { _, _ in passwordWrites += 1 }
        let job = BackupJob()
        try store.addOrUpdate(job)
        let state = root.appendingPathComponent("state.json")
        try FileManager.default.moveItem(at: state, to: root.appendingPathComponent("original-state.json"))
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
        store.setEnabled(!job.isEnabled, for: job.id)
        #expect(store.jobs.first?.isEnabled == job.isEnabled)
        #expect(store.errorMessage != nil)
        store.errorMessage = nil
        #expect(!store.delete(job))
        #expect(store.jobs.count == 1)
        #expect(store.errorMessage != nil)
        #expect(passwordWrites == 0)
    }

    @Test func keychainWriteFailuresPropagateWithoutTouchingRealCredentials() throws {
        var addCalls = 0
        var operations = KeychainStore.Operations(
            update: { _, _ in errSecInteractionNotAllowed },
            add: { _ in addCalls += 1; return errSecAuthFailed },
            delete: { _ in errSecSuccess }
        )
        let id = UUID()
        #expect(throws: KeychainStore.AccessError.self) {
            try KeychainStore.setPassword("fixture", for: id, operations: operations)
        }
        #expect(addCalls == 0)
        operations.update = { _, _ in errSecItemNotFound }
        #expect(throws: KeychainStore.AccessError.self) {
            try KeychainStore.setPassword("fixture", for: id, operations: operations)
        }
        #expect(addCalls == 1)
        operations.add = { _ in errSecSuccess }
        try KeychainStore.setPassword("fixture", for: id, operations: operations)
    }

    @Test func keychainClearingChecksBothServicesAndPreservesModernFallbackOnFailure() throws {
        var services: [String] = []
        var failLegacy = true
        let operations = KeychainStore.Operations(
            update: { _, _ in Issue.record("Unexpected update"); return errSecParam },
            add: { _ in Issue.record("Unexpected add"); return errSecParam },
            delete: { query in
                let service = (query as NSDictionary)[kSecAttrService] as? String ?? ""
                services.append(service)
                return failLegacy ? errSecAuthFailed : errSecItemNotFound
            }
        )
        #expect(throws: KeychainStore.AccessError.self) {
            try KeychainStore.setPassword("", for: UUID(), operations: operations)
        }
        #expect(services == ["ru.backupflow.database-passwords"])
        failLegacy = false
        services = []
        try KeychainStore.deletePassword(for: UUID(), operations: operations)
        #expect(services == ["ru.backupflow.database-passwords", "com.backupcron.database-passwords"])
    }

    @Test(arguments: [false, true])
    func postgresSSHCommandPreservesConnectionSettingsThroughShellParsing(requireSSL: Bool) throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("backupcron-ssh-command-test-\(UUID().uuidString)")
        let fakeDump = root.appendingPathComponent("pg_dump")
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        [ "$#" -eq 10 ] || exit 6
        [ "$1" = "--host" ] && [ "$2" = "$EXPECTED_HOST" ] || exit 7
        [ "$3" = "--port" ] && [ "$4" = "6543" ] || exit 8
        [ "$5" = "--username" ] && [ "$6" = "$EXPECTED_USER" ] || exit 9
        [ "$7" = "--dbname" ] && [ "$8" = "$EXPECTED_CONNECTION" ] || exit 10
        [ "$9" = "--no-password" ] && [ "${10}" = "--schema-only" ] || exit 11
        printf 'schema verified'
        """
        try Data(script.utf8).write(to: fakeDump)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeDump.path)

        var job = BackupJob()
        job.kind = .postgres
        job.connectionMode = .ssh
        job.host = "db host; literal"
        job.port = 6543
        job.username = "backup'user"
        job.databaseName = "report=2026 O'Brien\\draft"
        job.useSSL = requireSSL
        let sslmode = requireSSL ? "require" : "prefer"
        let expectedConnection = "dbname='report=2026 O\\'Brien\\\\draft' sslmode='\(sslmode)' connect_timeout='15'"

        let runner = Process()
        let pipe = Pipe()
        runner.executableURL = URL(fileURLWithPath: "/bin/sh")
        runner.arguments = ["-c", BackupEngine().postgresRemoteCommand(job: job, schemaOnly: true)]
        runner.environment = [
            "PATH": root.path + ":/usr/bin:/bin",
            "EXPECTED_HOST": job.host,
            "EXPECTED_USER": job.username,
            "EXPECTED_CONNECTION": expectedConnection
        ]
        runner.standardOutput = pipe
        try runner.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        runner.waitUntilExit()
        #expect(runner.terminationStatus == 0)
        #expect(String(decoding: data, as: UTF8.self) == "schema verified")
    }

    @Test func mysqlConnectionTestUsesNoDataAndReportsCommandFailure() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("backupcron-mysql-connection-test-\(UUID().uuidString)")
        let fakeDump = root.appendingPathComponent("mysqldump")
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        for argument in "$@"; do
          if [ "$argument" = "--no-data" ]; then
            echo 'access denied for test user' >&2
            exit 9
          fi
        done
        exit 7
        """
        try Data(script.utf8).write(to: fakeDump)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeDump.path)

        var job = BackupJob()
        job.kind = .mysql
        job.host = "database.example"
        job.port = 3306
        job.username = "backup"
        job.databaseName = "app"
        job.clientExecutablePath = fakeDump.path

        var failureMessage = ""
        do {
            _ = try await BackupEngine().testConnection(job: job, password: "wrong")
        } catch {
            failureMessage = error.localizedDescription
        }
        #expect(failureMessage.contains("access denied for test user"))
    }

    @Test func failedDatabaseDumpRemovesPartialOutput() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("backupcron-failure-test-\(UUID().uuidString)")
        let destination = root.appendingPathComponent("backups", isDirectory: true)
        let fakeDump = root.appendingPathComponent("pg_dump")
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        output=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--file" ]; then
            shift
            output="$1"
          fi
          shift
        done
        printf 'partial' > "$output"
        echo 'simulated dump failure' >&2
        sleep 1
        exit 9
        """
        try Data(script.utf8).write(to: fakeDump)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeDump.path)

        var job = BackupJob()
        job.name = "Failure"
        job.kind = .postgres
        job.destinationPath = destination.path
        job.databaseName = "database"
        job.username = "user"
        job.clientExecutablePath = fakeDump.path
        job.archiveOutput = false
        job.nameMask = "failed-output"

        let recorder = ProgressRecorder()
        let runTask = Task {
            try await BackupEngine().run(job: job, password: "secret") { event in
                await recorder.append(event)
            }
        }

        let receivedLiveLog = try await eventually {
            await recorder.contains(messagePart: "simulated dump failure")
        }
        #expect(receivedLiveLog)

        var didFail = false
        do {
            _ = try await runTask.value
        } catch {
            didFail = true
            #expect(error.localizedDescription.contains("simulated dump failure"))
        }

        #expect(didFail)
        let remainingFiles = (try? fileManager.contentsOfDirectory(atPath: destination.path)) ?? []
        #expect(remainingFiles.isEmpty)
    }

    @Test func cancellationStopsDumpAndRemovesPartialOutput() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("backupcron-cancel-test-\(UUID().uuidString)")
        let destination = root.appendingPathComponent("backups", isDirectory: true)
        let fakeDump = root.appendingPathComponent("pg_dump")
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        output=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--file" ]; then
            shift
            output="$1"
          fi
          shift
        done
        printf 'partial' > "$output"
        echo 'dump is running' >&2
        exec sleep 10
        """
        try Data(script.utf8).write(to: fakeDump)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeDump.path)

        var job = BackupJob()
        job.name = "Cancellation"
        job.kind = .postgres
        job.destinationPath = destination.path
        job.databaseName = "database"
        job.username = "user"
        job.clientExecutablePath = fakeDump.path
        job.archiveOutput = false
        job.nameMask = "cancelled-output"

        let recorder = ProgressRecorder()
        let runTask = Task {
            try await BackupEngine().run(job: job, password: "secret") { event in
                await recorder.append(event)
            }
        }

        let processStarted = try await eventually {
            await recorder.contains(messagePart: "dump is running")
        }
        #expect(processStarted)

        let cancellationStartedAt = Date()
        runTask.cancel()
        var receivedCancellation = false
        do {
            _ = try await runTask.value
        } catch {
            receivedCancellation = error is CancellationError
        }

        #expect(receivedCancellation)
        #expect(Date().timeIntervalSince(cancellationStartedAt) < 3)
        let remainingFiles = (try? fileManager.contentsOfDirectory(atPath: destination.path)) ?? []
        #expect(remainingFiles.isEmpty)
    }

    @Test func emptyDatabaseDumpIsRejectedAndRemoved() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("backupcron-empty-dump-test-\(UUID().uuidString)")
        let destination = root.appendingPathComponent("backups", isDirectory: true)
        let fakeDump = root.appendingPathComponent("pg_dump")
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        output=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--file" ]; then
            shift
            output="$1"
          fi
          shift
        done
        : > "$output"
        exit 0
        """
        try Data(script.utf8).write(to: fakeDump)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeDump.path)

        var job = BackupJob()
        job.name = "Empty dump"
        job.kind = .postgres
        job.destinationPath = destination.path
        job.databaseName = "database"
        job.username = "user"
        job.clientExecutablePath = fakeDump.path
        job.archiveOutput = false
        job.nameMask = "empty-output"

        var rejected = false
        do {
            _ = try await BackupEngine().run(job: job, password: "secret")
        } catch {
            rejected = error.localizedDescription.contains(L10n.text("engine.empty_dump"))
        }

        #expect(rejected)
        let remainingFiles = (try? fileManager.contentsOfDirectory(atPath: destination.path)) ?? []
        #expect(remainingFiles.isEmpty)
    }
}
