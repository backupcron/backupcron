import Darwin
import CryptoKit
import Foundation
import SQLite3

enum BackupEngineError: LocalizedError {
    case invalidConfiguration(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message), .commandFailed(let message):
            return message
        }
    }
}

struct BackupResult {
    var outputURL: URL
    var message: String
    var sizeBytes: Int64? = nil
}

struct BackupProgressEvent: Sendable {
    var fraction: Double
    var message: String
}

private final class ProcessLogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var completeData = Data()
    private var pendingData = Data()

    func consume(_ data: Data, flush: Bool = false) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        completeData.append(data)
        pendingData.append(data)
        var lines: [String] = []

        while let newline = pendingData.firstIndex(of: 0x0A) {
            let lineData = pendingData.prefix(upTo: newline)
            pendingData.removeSubrange(pendingData.startIndex...newline)
            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if !line.isEmpty { lines.append(line) }
        }

        if flush, !pendingData.isEmpty {
            let line = String(decoding: pendingData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            pendingData.removeAll(keepingCapacity: false)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }

    var errorMessage: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: completeData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class ScopedJobAccess: @unchecked Sendable {
    private(set) var job: BackupJob
    private var accessedURLs: [URL] = []

    init(job: BackupJob) {
        self.job = job

        let sourceBookmark = job.sourceBookmark
        let destinationBookmark = job.destinationBookmark
        let clientBookmark = job.clientExecutableBookmark
        let identityBookmark = job.sshIdentityBookmark
        resolve(path: &self.job.sourcePath, bookmark: sourceBookmark)
        resolve(path: &self.job.destinationPath, bookmark: destinationBookmark)
        resolve(path: &self.job.clientExecutablePath, bookmark: clientBookmark)
        resolve(path: &self.job.sshIdentityPath, bookmark: identityBookmark)
    }

    func stop() {
        accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        accessedURLs.removeAll()
    }

    private func resolve(path: inout String, bookmark: SecurityScopedBookmark?) {
        guard !path.isEmpty, let resolvedURL = bookmark?.resolve(matching: path) else { return }
        path = resolvedURL.path
        if resolvedURL.startAccessingSecurityScopedResource() {
            accessedURLs.append(resolvedURL)
        }
    }
}

private final class ProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancellationRequested = false

    func attach(_ process: Process) -> Bool {
        lock.lock()
        self.process = process
        let shouldCancel = cancellationRequested
        lock.unlock()
        return shouldCancel
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let process = self.process
        lock.unlock()
        if process?.isRunning == true {
            process?.terminate()
        }
    }

    var isCancellationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRequested
    }
}

private final class SQLiteDependencyCapture {
    var references = Set<DatabaseTableReference>()
}

private final class SQLiteDatabase {
    private(set) var handle: OpaquePointer!

    init(path: String, writable: Bool, create: Bool = false) throws {
        let flags = writable ? SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0) : SQLITE_OPEN_READONLY
        var connection: OpaquePointer?
        let code = sqlite3_open_v2(path, &connection, flags, nil)
        guard code == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? L10n.text("database.invalid_copy")
            if let connection { sqlite3_close(connection) }
            throw BackupEngineError.commandFailed(message)
        }
        handle = connection
        sqlite3_busy_timeout(connection, 5_000)
        sqlite3_progress_handler(connection, 1_000, { _ in Task.isCancelled ? 1 : 0 }, nil)
    }

    deinit { close() }

    func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    func check(_ code: Int32, expected: Int32 = SQLITE_OK) throws {
        try Task.checkCancellation()
        guard code == expected else { throw BackupEngineError.commandFailed(String(cString: sqlite3_errmsg(handle))) }
    }

    func execute(_ sql: String) throws {
        try Task.checkCancellation()
        try check(sqlite3_exec(handle, sql, nil, nil, nil))
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        try Task.checkCancellation()
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(handle, sql, -1, &statement, nil))
        guard let statement else { throw BackupEngineError.commandFailed(L10n.text("database.invalid_copy")) }
        return statement
    }

    func rows(_ sql: String) throws -> [[String]] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var rows: [[String]] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            try Task.checkCancellation()
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            })
            code = sqlite3_step(statement)
        }
        try check(code, expected: SQLITE_DONE)
        return rows
    }
}

private struct SQLiteRowDigest {
    private var hash = SHA256()
    private(set) var count: Int64 = 0

    private mutating func integer(_ number: UInt64) {
        var value = number.bigEndian
        withUnsafeBytes(of: &value) { hash.update(data: Data($0)) }
    }

    mutating func append(_ statement: OpaquePointer) {
        count += 1
        integer(UInt64(sqlite3_column_count(statement)))
        for index in 0..<sqlite3_column_count(statement) {
            let type = sqlite3_column_type(statement, index)
            integer(UInt64(type))
            switch type {
            case SQLITE_INTEGER: integer(UInt64(bitPattern: sqlite3_column_int64(statement, index)))
            case SQLITE_FLOAT: integer(sqlite3_column_double(statement, index).bitPattern)
            case SQLITE_TEXT, SQLITE_BLOB:
                let pointer = type == SQLITE_TEXT
                    ? sqlite3_column_text(statement, index).map { UnsafeRawPointer($0) }
                    : sqlite3_column_blob(statement, index)
                let length = Int(sqlite3_column_bytes(statement, index))
                integer(UInt64(length))
                if let pointer, length > 0 { hash.update(data: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: pointer), count: length, deallocator: .none)) }
            default: break
            }
        }
    }

    var value: SHA256.Digest { hash.finalize() }
}

private struct SQLiteVirtualTable {
    var module: String
    var dependency: DatabaseTableReference?
    var dependenciesKnown: Bool
}

private struct SQLiteRebuildPlan: Sendable {
    var virtualSchema: String
    var objects: String
}

private struct SQLiteSQLToken {
    var value: String
    var punctuation = false
}

struct BackupEngine {
    typealias ProgressHandler = @Sendable (BackupProgressEvent) async -> Void
    var diskSpace: @Sendable (URL) throws -> DiskSpaceAvailability = { try BackupEngine.diskSpaceAvailability($0) }

    func inspectDatabase(job: BackupJob, password: String) async throws -> DatabaseCatalog {
        try Task.checkCancellation()
        let access = ScopedJobAccess(job: job)
        let job = access.job
        defer { access.stop() }
        guard job.hasDatabaseSource else {
            throw BackupEngineError.invalidConfiguration(L10n.text("engine.connection_test_database_only"))
        }
        if job.kind != .sqlite { try validateDatabaseConfiguration(job) }
        else if !FileManager.default.fileExists(atPath: job.sourcePath) {
            throw BackupEngineError.invalidConfiguration(L10n.text("engine.source_not_found"))
        }

        let data: Data
        if job.kind == .sqlite {
            // Some macOS SQLite builds omit dbstat. Keep unknown table sizes
            // distinct from zero while still allowing table selection.
            let modules = try await databaseQuery(job: job, password: password,
                sql: "SELECT name FROM pragma_module_list WHERE name = 'dbstat';")
            let hasDBStat = String(decoding: modules, as: UTF8.self).contains("dbstat")
            data = try await databaseQuery(job: job, password: password, sql: sqliteCatalogQuery(hasDBStat: hasDBStat))
        } else {
            data = try await databaseQuery(job: job, password: password,
                sql: job.kind == .postgres ? Self.postgresCatalogQuery : Self.mysqlCatalogQuery)
        }
        let catalog = try decodeDatabaseCatalog(data)
        guard job.kind == .sqlite else { return catalog }
        let worker = Task.detached(priority: .utility) {
            try inspectSQLiteDependencies(path: job.sourcePath, catalog: catalog)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func inspectSQLiteDependencies(path: String, catalog: DatabaseCatalog) throws -> DatabaseCatalog {
        let database = try SQLiteDatabase(path: path, writable: false)
        let connection = database.handle!
        defer { database.close() }
        sqlite3_busy_timeout(connection, 5_000)
        let deadline = Date().addingTimeInterval(25)
        func checkCancellation() throws {
            try Task.checkCancellation()
            if Date() > deadline { throw BackupEngineError.commandFailed(L10n.text("database.timeout")) }
        }
        func strings(_ sql: String) throws -> [String] {
            try checkCancellation()
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else {
                throw BackupEngineError.commandFailed(String(cString: sqlite3_errmsg(connection)))
            }
            defer { sqlite3_finalize(statement) }
            var values: [String] = []
            var code = sqlite3_step(statement)
            while code == SQLITE_ROW {
                try checkCancellation()
                if let text = sqlite3_column_text(statement, 0) { values.append(String(cString: text)) }
                code = sqlite3_step(statement)
            }
            guard code == SQLITE_DONE else {
                throw BackupEngineError.commandFailed(String(cString: sqlite3_errmsg(connection)))
            }
            return values
        }
        let triggerOwners = Set(try strings("SELECT tbl_name FROM sqlite_schema WHERE type='trigger';").map { Data($0.utf8) })
        let virtual = Dictionary(uniqueKeysWithValues: try database.rows(
            "SELECT name,sql FROM sqlite_schema WHERE type='table' AND rootpage=0;").map { (Data($0[0].utf8), sqliteVirtualTable($0[1])) })
        var result = catalog
        for index in result.tables.indices {
            try checkCancellation()
            let table = result.tables[index]
            let identifier = Data(table.name.utf8)
            if virtual.keys.contains(identifier), (virtual[identifier] ?? nil) == nil {
                result.tables[index].dependencyInspectionError = L10n.text("database.dependencies_unknown", table.id.displayName)
            }
            if let specification = virtual[identifier] ?? nil {
                if !specification.dependenciesKnown {
                    result.tables[index].dependencyInspectionError = L10n.text("database.dependencies_unknown", table.id.displayName)
                }
                if let reference = specification.dependency {
                    let dependency = catalog.tables.first {
                        sqliteCaseFold($0.schema).utf8.elementsEqual(sqliteCaseFold(reference.schema).utf8) &&
                            sqliteCaseFold($0.name).utf8.elementsEqual(sqliteCaseFold(reference.name).utf8)
                    }?.id ?? reference
                    result.tables[index].requiredTables.append(dependency)
                }
            }
            var statements: [String] = []
            let name = quotedIdentifier(table.schema) + "." + quotedIdentifier(table.name)
            if table.objectType == "view" { statements.append("SELECT * FROM \(name) LIMIT 0;") }
            if triggerOwners.contains(identifier) {
                let literal = table.name.replacingOccurrences(of: "'", with: "''")
                let columns: [String]
                do {
                    columns = try strings("SELECT name FROM pragma_table_xinfo('\(literal)') WHERE hidden=0;")
                } catch {
                    try checkCancellation()
                    // An application-defined function in a view may prevent
                    // column discovery. Preserve full-copy compatibility while
                    // requiring a verified dependency set for partial copies.
                    result.tables[index].dependencyInspectionError = error.localizedDescription
                    columns = []
                }
                let assignments = columns.map { "\(quotedIdentifier($0))=\(quotedIdentifier($0))" }.joined(separator: ",")
                statements += ["EXPLAIN INSERT INTO \(name) DEFAULT VALUES;", "EXPLAIN DELETE FROM \(name) WHERE 0;"]
                if !assignments.isEmpty { statements.append("EXPLAIN UPDATE \(name) SET \(assignments) WHERE 0;") }
            }
            guard !statements.isEmpty else { continue }
            let capture = SQLiteDependencyCapture()
            let context = Unmanaged.passUnretained(capture).toOpaque()
            sqlite3_set_authorizer(connection, { context, action, first, _, database, source in
                guard let context, let first, let source,
                      action == SQLITE_READ || action == SQLITE_INSERT || action == SQLITE_UPDATE || action == SQLITE_DELETE else {
                    return SQLITE_OK
                }
                _ = source
                let capture = Unmanaged<SQLiteDependencyCapture>.fromOpaque(context).takeUnretainedValue()
                capture.references.insert(.init(schema: database.map { String(cString: $0) } ?? "main",
                                                name: String(cString: first)))
                return SQLITE_OK
            }, context)
            for sql in statements {
                do { try checkCancellation() } catch {
                    sqlite3_set_authorizer(connection, nil, nil)
                    throw error
                }
                var statement: OpaquePointer?
                // Compilation discovers dependencies in views and trigger
                // bodies. Never step these statements or write to the source.
                let code = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
                sqlite3_finalize(statement)
                if code != SQLITE_OK {
                    let error = String(cString: sqlite3_errmsg(connection))
                    // Views may support only one INSTEAD OF trigger event.
                    if !(table.objectType == "view" && error.contains("because it is a view")) {
                        result.tables[index].dependencyInspectionError = error
                    }
                }
            }
            sqlite3_set_authorizer(connection, nil, nil)
            result.tables[index].requiredTables = Array(Set(result.tables[index].requiredTables).union(capture.references).subtracting([table.id]))
                .sorted { $0.displayName < $1.displayName }
        }
        return result
    }

    private func sqliteCaseFold(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.map { scalar in
            scalar.value >= 65 && scalar.value <= 90 ? UnicodeScalar(scalar.value + 32)! : scalar
        }))
    }

    private func sqliteVirtualTable(_ sql: String) -> SQLiteVirtualTable? {
        // Tokenise only the virtual-table declaration. Quoted content names,
        // comments and commas inside tokenizer options remain single tokens.
        let characters = Array(sql)
        var tokens: [SQLiteSQLToken] = []
        var position = 0
        while position < characters.count {
            let character = characters[position]
            if character.isWhitespace { position += 1; continue }
            if character == "-", position + 1 < characters.count, characters[position + 1] == "-" {
                while position < characters.count && characters[position] != "\n" { position += 1 }
                continue
            }
            if character == "/", position + 1 < characters.count, characters[position + 1] == "*" {
                position += 2
                while position + 1 < characters.count && !(characters[position] == "*" && characters[position + 1] == "/") { position += 1 }
                position = min(position + 2, characters.count)
                continue
            }
            if "\"'`[".contains(character) {
                let closing: Character = character == "[" ? "]" : character
                position += 1
                var value = ""
                while position < characters.count {
                    let current = characters[position]
                    position += 1
                    if current == closing {
                        if closing != "]", position < characters.count, characters[position] == closing {
                            value.append(closing); position += 1
                        } else { break }
                    } else { value.append(current) }
                }
                tokens.append(.init(value: value))
            } else if "(),=.".contains(character) {
                tokens.append(.init(value: String(character), punctuation: true)); position += 1
            } else {
                let start = position
                while position < characters.count && !characters[position].isWhitespace && !"(),=.\"'`[".contains(characters[position]) {
                    if position + 1 < characters.count &&
                        ((characters[position] == "-" && characters[position + 1] == "-") || (characters[position] == "/" && characters[position + 1] == "*")) { break }
                    position += 1
                }
                if position == start { position += 1 }
                tokens.append(.init(value: String(characters[start..<position])))
            }
        }
        guard let using = tokens.indices.first(where: { index in
            index + 2 < tokens.count && tokens[index].value.uppercased() == "USING" && tokens[index + 2].punctuation && tokens[index + 2].value == "("
        }) else { return nil }
        let module = tokens[using + 1].value.lowercased()
        var arguments: [[SQLiteSQLToken]] = []
        var current: [SQLiteSQLToken] = []
        var depth = 0
        for token in tokens.dropFirst(using + 3) {
            if token.punctuation && token.value == "(" { depth += 1 }
            if token.punctuation && token.value == ")" {
                if depth == 0 { arguments.append(current); break }
                depth -= 1
            }
            if token.punctuation && token.value == "," && depth == 0 {
                arguments.append(current); current = []
            } else { current.append(token) }
        }
        if ["fts3", "fts4", "fts5"].contains(module) {
            let content = arguments.first { $0.count >= 3 && $0[0].value.lowercased() == "content" && $0[1].punctuation && $0[1].value == "=" }
            guard let content else { return .init(module: module, dependency: nil, dependenciesKnown: true) }
            guard content.count == 3 else { return .init(module: module, dependency: nil, dependenciesKnown: false) }
            return .init(module: module, dependency: content[2].value.isEmpty ? nil : .init(schema: "main", name: content[2].value), dependenciesKnown: true)
        }
        if module == "fts5vocab" || module == "fts4aux" {
            let usesDatabase = module == "fts5vocab" ? arguments.count == 3 : arguments.count == 2
            let tableIndex = usesDatabase ? 1 : 0
            guard arguments.count > tableIndex, arguments[tableIndex].count == 1,
                  !usesDatabase || arguments[0].count == 1 else { return .init(module: module, dependency: nil, dependenciesKnown: false) }
            return .init(module: module, dependency: .init(schema: usesDatabase ? arguments[0][0].value : "main", name: arguments[tableIndex][0].value), dependenciesKnown: true)
        }
        return .init(module: module, dependency: nil, dependenciesKnown: ["rtree", "rtree_i32", "fts3tokenize"].contains(module))
    }

    static func diskSpaceAvailability(_ url: URL) throws -> DiskSpaceAvailability {
        var existing = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: existing.path) && existing.path != "/" {
            existing.deleteLastPathComponent()
        }
        let values = try? existing.resourceValues(forKeys: [.volumeIdentifierKey, .volumeAvailableCapacityKey])
        return .init(volumeID: values?.volumeIdentifier.map { String(describing: $0) } ?? "",
                     availableBytes: values?.volumeAvailableCapacity.flatMap { $0 >= 0 ? Int64($0) : nil }, path: url.path)
    }

    func databaseSpacePlan(job: BackupJob, catalog: DatabaseCatalog?) throws -> [DatabaseSpaceRequirement] {
        let access = ScopedJobAccess(job: job)
        defer { access.stop() }
        func availability(_ url: URL) -> DiskSpaceAvailability {
            (try? diskSpace(url)) ?? .init(volumeID: "", availableBytes: nil, path: url.path)
        }
        let destination = availability(URL(fileURLWithPath: access.job.destinationPath, isDirectory: true))
        let temporary = job.archiveOutput ? availability(FileManager.default.temporaryDirectory) : destination
        return DatabaseSpaceRequirement.plan(estimate: .init(job: job, catalog: catalog),
                                             destination: destination, temporary: temporary, archive: job.archiveOutput)
    }

    private func checkDatabaseSpace(job: BackupJob, catalog: DatabaseCatalog?, onProgress: ProgressHandler) async throws {
        let requirements = try databaseSpacePlan(job: job, catalog: catalog)
        func size(_ bytes: Int64?) -> String {
            bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? L10n.text("database.unknown_size")
        }
        for requirement in requirements {
            await onProgress(.init(fraction: 0.08, message: L10n.text("database.space_summary",
                L10n.text(requirement.locationKey), size(requirement.requiredBytes), size(requirement.disk.availableBytes))))
            // SQLite's estimate budgets the complete snapshot and compaction.
            // SQL text size is uncertain, so its estimate remains advisory.
            if job.kind == .sqlite && requirement.isInsufficient {
                throw BackupEngineError.invalidConfiguration(L10n.text("database.space_insufficient",
                    requirement.disk.path, size(requirement.requiredBytes), size(requirement.disk.availableBytes)))
            }
        }
    }

    func decodeDatabaseCatalog(_ data: Data) throws -> DatabaseCatalog {
        do {
            let catalog = try JSONDecoder().decode(DatabaseCatalog.self, from: data)
            guard catalog.sizeBytes.map({ $0 >= 0 }) ?? true,
                  Set(catalog.tables.map(\.id)).count == catalog.tables.count,
                  catalog.tables.allSatisfy({ !$0.schema.isEmpty && !$0.name.isEmpty &&
                      !$0.schema.contains("\0") && !$0.name.contains("\0") &&
                      ($0.sizeBytes.map { $0 >= 0 } ?? true) }) else {
                throw BackupEngineError.commandFailed(L10n.text("database.invalid_response"))
            }
            return catalog
        } catch {
            throw BackupEngineError.commandFailed(L10n.text("database.invalid_response"))
        }
    }

    private func databaseQuery(job: BackupJob, password: String, sql: String) async throws -> Data {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupCron-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("result.json")
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                var environment = commandEnvironment()
                let tool: String
                let arguments: [String]
                if job.kind == .sqlite {
                    tool = "sqlite3"
                    environment["SQLITE_TMPDIR"] = directory.path
                    arguments = ["-init", "/dev/null", "-readonly", "-batch", "-bail", "-cmd", ".timeout 5000", job.sourcePath, sql]
                } else if job.kind == .postgres {
                    tool = "psql"
                    environment["PGPASSWORD"] = password
                    arguments = postgresConnectionArguments(job: job) + [
                        "--no-psqlrc", "--quiet", "--no-align", "--tuples-only", "--set=ON_ERROR_STOP=1",
                        "--command", "BEGIN READ ONLY; SET LOCAL statement_timeout = '25000'; \(sql); COMMIT;"
                    ]
                } else {
                    tool = "mysql"
                    environment["MYSQL_PWD"] = password
                    arguments = ["--host=\(job.host)", "--port=\(job.port)", "--user=\(job.username)",
                        "--database=\(job.databaseName)", "--batch", "--raw", "--skip-column-names",
                        "--default-character-set=utf8mb4", "--connect-timeout=15"] +
                        (job.useSSL ? ["--ssl-mode=REQUIRED"] : []) + ["--execute",
                        "SET SESSION MAX_EXECUTION_TIME=25000; START TRANSACTION READ ONLY; \(sql); COMMIT;"]
                }
                if job.kind == .sqlite || job.connectionMode == .direct {
                    let executable = job.kind == .sqlite ? "/usr/bin/sqlite3" : try resolveQueryTool(named: tool, job: job)
                    try await execute(executable: executable, arguments: arguments, environment: environment,
                                      standardOutputURL: output, onLog: { _ in })
                } else if job.connectionMode == .docker {
                    let passwordKey = job.kind == .postgres ? "PGPASSWORD" : "MYSQL_PWD"
                    try await execute(executable: "/usr/bin/env",
                        arguments: ["docker", "exec", "-e", passwordKey, job.dockerContainer, tool] + arguments,
                        environment: environment, standardOutputURL: output, onLog: { _ in })
                } else {
                    let remoteCommand = ([tool] + arguments).map(shellQuoted).joined(separator: " ")
                    try await execute(executable: "/usr/bin/ssh", arguments: sshArguments(job: job, remoteCommand: remoteCommand),
                                      environment: commandEnvironment(), standardOutputURL: output, onLog: { _ in })
                }
                try Task.checkCancellation()
                let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 32 * 1024 * 1024 else {
                    throw BackupEngineError.commandFailed(L10n.text("database.invalid_response"))
                }
                return try Data(contentsOf: output)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw BackupEngineError.commandFailed(L10n.text("database.timeout"))
            }
            defer { group.cancelAll() }
            return try await group.next() ?? Data()
        }
    }

    private func resolveQueryTool(named name: String, job: BackupJob) throws -> String {
        if !job.clientExecutablePath.isEmpty {
            let sibling = URL(fileURLWithPath: job.clientExecutablePath).deletingLastPathComponent().appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: sibling) { return sibling }
        }
        return try resolveLocalTool(named: name, customPath: "")
    }

    private static let postgresCatalogQuery = """
    SELECT json_build_object('sizeBytes', pg_database_size(current_database()), 'tables', COALESCE(json_agg(
      json_build_object('schema', n.nspname, 'name', c.relname,
        'objectType', CASE WHEN c.relkind = 'v' THEN 'view' ELSE 'table' END,
        'sizeBytes', CASE WHEN c.relkind IN ('v', 'p') THEN 0 ELSE pg_total_relation_size(c.oid) END,
        'parentTables', COALESCE((SELECT json_agg(json_build_object('schema', pn.nspname, 'name', pc.relname))
          FROM pg_inherits i JOIN pg_class pc ON pc.oid = i.inhparent JOIN pg_namespace pn ON pn.oid = pc.relnamespace
          WHERE i.inhrelid = c.oid), '[]'::json),
        'requiredTables', COALESCE((SELECT json_agg(json_build_object('schema', dn.nspname, 'name', dc.relname))
          FROM (SELECT confrelid AS oid FROM pg_constraint WHERE conrelid = c.oid AND contype = 'f'
            UNION SELECT d.refobjid FROM pg_rewrite rw JOIN pg_depend d ON d.objid = rw.oid
            WHERE rw.ev_class = c.oid AND d.classid = 'pg_rewrite'::regclass
              AND d.refclassid = 'pg_class'::regclass AND d.refobjid <> c.oid) refs
          JOIN pg_class dc ON dc.oid = refs.oid JOIN pg_namespace dn ON dn.oid = dc.relnamespace), '[]'::json))
      ORDER BY n.nspname, c.relname), '[]'::json))
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind IN ('r', 'p', 'v', 'm') AND n.nspname <> 'information_schema' AND n.nspname !~ '^pg_'
    """

    private static let mysqlCatalogQuery = """
    SELECT JSON_OBJECT('sizeBytes', (SELECT SUM(DATA_LENGTH + INDEX_LENGTH) FROM information_schema.TABLES
      WHERE TABLE_SCHEMA = DATABASE()), 'tables', COALESCE(JSON_ARRAYAGG(JSON_OBJECT(
      'schema', t.TABLE_SCHEMA, 'name', t.TABLE_NAME, 'objectType', IF(t.TABLE_TYPE = 'VIEW', 'view', 'table'),
      'sizeBytes', IF(t.TABLE_TYPE = 'VIEW', 0, t.DATA_LENGTH + t.INDEX_LENGTH), 'parentTables', JSON_ARRAY(),
      'requiredTables', JSON_MERGE_PRESERVE(
        COALESCE((SELECT JSON_ARRAYAGG(JSON_OBJECT('schema', k.REFERENCED_TABLE_SCHEMA, 'name', k.REFERENCED_TABLE_NAME))
          FROM information_schema.KEY_COLUMN_USAGE k WHERE k.TABLE_SCHEMA = t.TABLE_SCHEMA
          AND k.TABLE_NAME = t.TABLE_NAME AND k.REFERENCED_TABLE_NAME IS NOT NULL), JSON_ARRAY()),
        COALESCE((SELECT JSON_ARRAYAGG(JSON_OBJECT('schema', v.TABLE_SCHEMA, 'name', v.TABLE_NAME))
          FROM information_schema.VIEW_TABLE_USAGE v WHERE v.VIEW_SCHEMA = t.TABLE_SCHEMA
          AND v.VIEW_NAME = t.TABLE_NAME), JSON_ARRAY())))), JSON_ARRAY()))
    FROM information_schema.TABLES t WHERE t.TABLE_SCHEMA = DATABASE()
    """

    private func sqliteCatalogQuery(hasDBStat: Bool) -> String {
        let size = hasDBStat ? """
            CASE WHEN p.type = 'virtual' THEN NULL WHEN s.type = 'view' THEN 0 ELSE COALESCE((
              SELECT SUM(b.pgsize) FROM dbstat b JOIN sqlite_schema owned ON owned.name = b.name
              WHERE owned.tbl_name = s.name), 0) END
            """ : "CASE WHEN s.type = 'view' THEN 0 ELSE NULL END"
        return """
        SELECT json_object('sizeBytes', (SELECT page_count FROM pragma_page_count) *
          (SELECT page_size FROM pragma_page_size), 'tables', json_group_array(json_object(
          'schema', 'main', 'name', s.name, 'objectType', s.type, 'sizeBytes', \(size),
          'parentTables', json('[]'), 'requiredTables', (SELECT json_group_array(json_object(
            'schema', 'main', 'name', COALESCE((SELECT actual.name FROM sqlite_schema actual
              WHERE actual.type = 'table' AND actual.name = f."table" COLLATE NOCASE), f."table")))
            FROM pragma_foreign_key_list(s.name) f))))
        FROM sqlite_schema s JOIN pragma_table_list p ON p.name = s.name AND p.schema = 'main'
        WHERE s.type IN ('table', 'view') AND p.type <> 'shadow' AND substr(s.name, 1, 7) <> 'sqlite_';
        """
    }

    func testConnection(job: BackupJob, password: String) async throws -> String {
        try Task.checkCancellation()
        let scopedAccess = ScopedJobAccess(job: job)
        let job = scopedAccess.job
        defer { scopedAccess.stop() }

        try validateDatabaseConfiguration(job)

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupCron-connection-test-\(UUID().uuidString)", isDirectory: true)
        let output = temporaryDirectory.appendingPathComponent("schema.sql")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        switch job.kind {
        case .postgres:
            try await runPostgres(
                job: job,
                password: password,
                output: output,
                schemaOnly: true,
                onLog: { _ in }
            )
        case .mysql:
            try await runMySQL(
                job: job,
                password: password,
                output: output,
                schemaOnly: true,
                onLog: { _ in }
            )
        case .files, .project, .sqlite:
            throw BackupEngineError.invalidConfiguration(L10n.text("engine.connection_test_database_only"))
        }

        try Task.checkCancellation()
        return L10n.text("engine.connection_ok")
    }

    func run(
        job: BackupJob,
        password: String,
        onProgress: @escaping ProgressHandler = { _ in }
    ) async throws -> BackupResult {
        try Task.checkCancellation()
        let scopedAccess = ScopedJobAccess(job: job)
        var job = scopedAccess.job
        defer { scopedAccess.stop() }

        await onProgress(.init(fraction: 0.02, message: L10n.text("log.preparing")))
        try validate(job)

        var catalog: DatabaseCatalog?
        if job.hasDatabaseSource {
            do { catalog = try await inspectDatabase(job: job, password: password) }
            catch is CancellationError { throw CancellationError() }
            catch {
                // Full server dumps must still work with a dump-only client or
                // account. Partial copies require dependency inspection.
                if job.kind == .sqlite || !job.excludedDatabaseTables.isEmpty { throw error }
            }
        }
        if let catalog, !job.excludedDatabaseTables.isEmpty {
            if let error = catalog.selectionError(excluding: job.excludedDatabaseTables) {
                throw BackupEngineError.invalidConfiguration(error)
            }
            job.excludedDatabaseTables = catalog.effectiveExclusions(job.excludedDatabaseTables)
                .sorted { $0.displayName < $1.displayName }
        }
        let preparedJob = job

        let fileManager = FileManager.default
        let destinationDirectory = URL(fileURLWithPath: job.destinationPath, isDirectory: true)
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        if job.hasDatabaseSource { try await checkDatabaseSpace(job: job, catalog: catalog, onProgress: onProgress) }
        // Each run owns its work directory. Only a verified result is published
        // under the requested name; cleanup never touches another run's output.
        let workDirectory = destinationDirectory.appendingPathComponent(
            ".BackupCron-in-progress-\(UUID().uuidString)", isDirectory: true
        )
        try fileManager.createDirectory(
            at: workDirectory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: workDirectory) }
        let baseName = BackupNaming.render(mask: job.nameMask, job: job)

        var result: BackupResult
        switch job.kind {
        case .files:
            result = try await backupFiles(
                job: job,
                destinationDirectory: workDirectory,
                baseName: baseName,
                onProgress: onProgress
            )

        case .project:
            result = try await backupProject(
                job: job,
                destinationDirectory: workDirectory,
                baseName: baseName,
                onProgress: onProgress
            )

        case .sqlite:
            result = try await backupDatabase(
                job: job,
                destinationDirectory: workDirectory,
                baseName: baseName,
                rawExtension: "sqlite3",
                dumpMessageKey: "log.dumping_sqlite",
                successMessageKey: "engine.sqlite_created",
                onProgress: onProgress
            ) { output, log in
                let escapedPath = output.path.replacingOccurrences(of: "'", with: "''")
                try await execute(
                    executable: "/usr/bin/sqlite3",
                    arguments: ["-init", "/dev/null", "-readonly", "-batch", "-bail", "-cmd", ".timeout 5000", preparedJob.sourcePath, ".backup '\(escapedPath)'"],
                    onLog: log
                )
                if !preparedJob.excludedDatabaseTables.isEmpty {
                    try await excludeSQLiteTables(job: preparedJob, output: output, onLog: log)
                }
            }

        case .postgres:
            result = try await backupDatabase(
                job: job,
                destinationDirectory: workDirectory,
                baseName: baseName,
                rawExtension: "sql",
                dumpMessageKey: "log.dumping_postgres",
                successMessageKey: "engine.postgres_created",
                onProgress: onProgress
            ) { output, log in
                try await runPostgres(job: preparedJob, password: password, output: output, onLog: log)
            }

        case .mysql:
            result = try await backupDatabase(
                job: job,
                destinationDirectory: workDirectory,
                baseName: baseName,
                rawExtension: "sql",
                dumpMessageKey: "log.dumping_mysql",
                successMessageKey: "engine.mysql_created",
                onProgress: onProgress
            ) { output, log in
                try await runMySQL(job: preparedJob, password: password, output: output, onLog: log)
            }
        }

        await onProgress(.init(fraction: 0.94, message: L10n.text("log.verifying")))
        do {
            result.sizeBytes = try await verifyOutput(
                result.outputURL,
                isArchive: job.archiveOutput,
                onProgress: onProgress
            )
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: result.outputURL)
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: result.outputURL)
            throw BackupEngineError.commandFailed(L10n.text("engine.verification_failed", error.localizedDescription))
        }
        let formattedSize = ByteCountFormatter.string(
            fromByteCount: result.sizeBytes ?? 0,
            countStyle: .file
        )
        await onProgress(.init(fraction: 0.98, message: L10n.text("log.verified", formattedSize)))
        result.outputURL = try publishOutput(result.outputURL, in: destinationDirectory)
        await onProgress(.init(fraction: 1, message: L10n.text("log.completed", result.outputURL.lastPathComponent)))
        return result
    }

    private func excludeSQLiteTables(job: BackupJob, output: URL,
                                    onLog: @escaping @Sendable (String) async -> Void) async throws {
        // Inspect and modify only the consistent private snapshot, never the source.
        var copy = job
        copy.sourcePath = output.path
        copy.sourceBookmark = nil
        let catalog = try await inspectDatabase(job: copy, password: "")
        if let error = catalog.selectionError(excluding: job.excludedDatabaseTables) {
            throw BackupEngineError.invalidConfiguration(error)
        }
        let excluded = catalog.effectiveExclusions(job.excludedDatabaseTables)
        let statements = catalog.tables.filter { excluded.contains($0.id) }.map { table in
            "DROP \(table.objectType == "view" ? "VIEW" : "TABLE") IF EXISTS \(quotedIdentifier(table.schema)).\(quotedIdentifier(table.name));"
        }
        guard !statements.isEmpty else { return }
        var environment = commandEnvironment()
        environment["SQLITE_TMPDIR"] = output.deletingLastPathComponent().path
        let script = output.deletingLastPathComponent().appendingPathComponent(".sqlite-exclusions-\(UUID().uuidString).sql")
        defer { try? FileManager.default.removeItem(at: script) }
        try Data(("PRAGMA foreign_keys=OFF; PRAGMA secure_delete=ON; BEGIN; " + statements.joined(separator: " ") + " COMMIT;").utf8).write(to: script)
        try await execute(executable: "/usr/bin/sqlite3",
            arguments: ["-init", "/dev/null", "-batch", "-bail", output.path],
            environment: environment, standardInputURL: script, onLog: onLog)
        try await compactSQLiteSnapshot(output, onLog: onLog)
        let check = try await databaseQuery(job: copy, password: "", sql: "PRAGMA integrity_check;")
        guard String(decoding: check, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "ok" else {
            throw BackupEngineError.commandFailed(L10n.text("database.invalid_copy"))
        }
    }

    private func compactSQLiteSnapshot(_ output: URL, onLog: @escaping @Sendable (String) async -> Void) async throws {
        // All data, index sorting and verification files belong to the same
        // private directory and volume budgeted before the snapshot is taken.
        let directory = output.deletingLastPathComponent().appendingPathComponent(".sqlite-compact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let compacted = directory.appendingPathComponent("snapshot.sqlite3")
        await onLog(L10n.text("database.compacting"))
        let worker = Task.detached(priority: .utility) { try await copySQLiteRows(from: output, to: compacted, onLog: onLog) }
        let plan = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
        var environment = commandEnvironment()
        environment["SQLITE_TMPDIR"] = directory.path
        // Reopen between virtual schema restoration and object creation, so
        // SQLite reloads virtual definitions only after shadows contain data.
        for (name, sql) in [("virtual.sql", plan.virtualSchema), ("objects.sql", plan.objects)] {
            let script = directory.appendingPathComponent(name)
            try Data(sql.utf8).write(to: script)
            try await execute(executable: "/usr/bin/sqlite3",
                arguments: ["-init", "/dev/null", "-batch", "-bail", compacted.path], environment: environment,
                standardInputURL: script, onLog: onLog)
        }
        try Task.checkCancellation()
        // Never expose either the full snapshot or an unfinished compact copy.
        try FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: compacted, to: output)
    }

    private func copySQLiteRows(from source: URL, to destination: URL, onLog: @escaping @Sendable (String) async -> Void) async throws -> SQLiteRebuildPlan {
        let original = try SQLiteDatabase(path: source.path, writable: true)
        let schema = try original.rows("SELECT type,name,tbl_name,rootpage,sql FROM sqlite_schema WHERE sql IS NOT NULL;")
        let tableKinds = Dictionary(uniqueKeysWithValues: try original.rows(
            "SELECT name,wr FROM pragma_table_list WHERE schema='main';").map { (Data($0[0].utf8), $0[1]) })
        let pageSize = try original.rows("PRAGMA page_size;")[0][0]
        let encoding = try original.rows("PRAGMA encoding;")[0][0]
        let autoVacuum = try original.rows("PRAGMA auto_vacuum;")[0][0]
        let userVersion = try original.rows("PRAGMA user_version;")[0][0]
        let applicationID = try original.rows("PRAGMA application_id;")[0][0]
        let journalMode = try original.rows("PRAGMA journal_mode;")[0][0]
        let physical = schema.filter { $0[0] == "table" && $0[3] != "0" }
        var initialSchema = ["PRAGMA page_size=\(pageSize); PRAGMA encoding='\(encoding)'; PRAGMA auto_vacuum=\(autoVacuum); PRAGMA foreign_keys=OFF; PRAGMA writable_schema=ON; BEGIN;"]
        if physical.contains(where: { $0[1] == "sqlite_sequence" }) {
            let temporary = quotedIdentifier("backupcron_sequence_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
            initialSchema += ["CREATE TABLE \(temporary)(id INTEGER PRIMARY KEY AUTOINCREMENT);", "DROP TABLE \(temporary);"]
        }
        initialSchema += physical.filter { $0[1] != "sqlite_sequence" }.map { $0[4] + ";" }
        initialSchema += ["COMMIT; PRAGMA writable_schema=OFF;"]
        let script = destination.deletingLastPathComponent().appendingPathComponent("tables.sql")
        try Data(initialSchema.joined(separator: "\n").utf8).write(to: script)
        var environment = commandEnvironment()
        environment["SQLITE_TMPDIR"] = destination.deletingLastPathComponent().path
        try await execute(executable: "/usr/bin/sqlite3", arguments: ["-init", "/dev/null", "-batch", "-bail", destination.path],
                          environment: environment, standardInputURL: script, onLog: onLog)
        let compact = try SQLiteDatabase(path: destination.path, writable: true)
        try compact.execute("PRAGMA foreign_keys=OFF; PRAGMA ignore_check_constraints=ON; BEGIN;")
        // sqlite_sequence is copied after all AUTOINCREMENT inserts, so the
        // highest deleted ID and deliberately edited sequences also survive.
        for entry in physical.sorted(by: { ($0[1] == "sqlite_sequence" ? 1 : 0) < ($1[1] == "sqlite_sequence" ? 1 : 0) }) {
            let table = entry[1]
            await onLog(L10n.text("database.copying_table", table, Int64(0)))
            let name = quotedIdentifier(table)
            let literal = table.replacingOccurrences(of: "'", with: "''")
            var columns = try original.rows("SELECT name,hidden FROM pragma_table_xinfo('\(literal)');")
            guard !columns.isEmpty else { throw BackupEngineError.commandFailed(L10n.text("database.invalid_copy")) }
            let hasRowID = tableKinds[Data(table.utf8)] != "1"
            var rowID = hasRowID ? ["rowid", "_rowid_", "oid"].first { alias in !columns.contains { $0[0].lowercased() == alias } } : nil
            var renamedColumn: (original: String, temporary: String)?
            if hasRowID && rowID == nil {
                // If all three aliases are real columns, temporarily free one
                // alias in both private files. No user database is altered.
                let index = columns.firstIndex { $0[0].lowercased() == "rowid" }!
                let current = columns[index][0]
                let temporary = "backupcron_rowid_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                let rename = "ALTER TABLE \(name) RENAME COLUMN \(quotedIdentifier(current)) TO \(quotedIdentifier(temporary));"
                try original.execute(rename)
                try compact.execute(rename)
                columns[index][0] = temporary
                renamedColumn = (current, temporary)
                rowID = "rowid"
            }
            let fields = (rowID.map { [$0] } ?? []) + columns.map { $0[0] }
            let writableIndices = (rowID == nil ? [] : [0]) + columns.indices.filter { columns[$0][1] == "0" }.map { $0 + (rowID == nil ? 0 : 1) }
            let query = "SELECT " + fields.map(quotedIdentifier).joined(separator: ",") + " FROM \(name) NOT INDEXED;"
            let read = try original.prepare(query)
            defer { sqlite3_finalize(read) }
            let writableFields = writableIndices.map { quotedIdentifier(fields[$0]) }.joined(separator: ",")
            let placeholders = writableIndices.map { _ in "?" }.joined(separator: ",")
            let insert = try compact.prepare("INSERT INTO \(name)(\(writableFields)) VALUES(\(placeholders));")
            defer { sqlite3_finalize(insert) }
            try compact.execute("DELETE FROM \(name);")
            var expected = SQLiteRowDigest()
            var lastLog = Date()
            var code = sqlite3_step(read)
            while code == SQLITE_ROW {
                try Task.checkCancellation()
                expected.append(read)
                for (parameter, column) in writableIndices.enumerated() {
                    try compact.check(sqlite3_bind_value(insert, Int32(parameter + 1), sqlite3_column_value(read, Int32(column))))
                }
                try compact.check(sqlite3_step(insert), expected: SQLITE_DONE)
                try compact.check(sqlite3_reset(insert))
                sqlite3_clear_bindings(insert)
                if expected.count % 4_096 == 0 && Date().timeIntervalSince(lastLog) >= 1 {
                    await onLog(L10n.text("database.copying_table", table, expected.count))
                    lastLog = Date()
                }
                code = sqlite3_step(read)
            }
            try original.check(code, expected: SQLITE_DONE)
            let verify = try compact.prepare(query)
            defer { sqlite3_finalize(verify) }
            var actual = SQLiteRowDigest()
            code = sqlite3_step(verify)
            while code == SQLITE_ROW {
                try Task.checkCancellation()
                actual.append(verify)
                code = sqlite3_step(verify)
            }
            try compact.check(code, expected: SQLITE_DONE)
            guard actual.count == expected.count, actual.value == expected.value else {
                throw BackupEngineError.commandFailed(L10n.text("database.invalid_copy"))
            }
            if let renamedColumn {
                try compact.execute("ALTER TABLE \(name) RENAME COLUMN \(quotedIdentifier(renamedColumn.temporary)) TO \(quotedIdentifier(renamedColumn.original));")
            }
        }
        // Virtual tables are restored from their original definitions after
        // their shadow tables have been copied. Running CREATE VIRTUAL TABLE
        // would initialise empty shadows and destroy their existing indexes.
        let virtual = schema.filter { $0[0] == "table" && $0[3] == "0" }
        let virtualSchema = virtual.map { entry in
            let values = [entry[1], entry[2], entry[4]].map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }
            return "INSERT INTO sqlite_schema(type,name,tbl_name,rootpage,sql) VALUES('table',\(values[0]),\(values[1]),0,\(values[2]));"
        }
        try compact.execute("PRAGMA user_version=\(userVersion); PRAGMA application_id=\(applicationID); COMMIT;")
        compact.close()
        original.close()
        let objects = schema.filter { ["index", "view", "trigger"].contains($0[0]) }.map { $0[4] + ";" }
        let ftsChecks = virtual.compactMap { entry -> String? in
            guard let specification = sqliteVirtualTable(entry[4]), ["fts3", "fts4", "fts5"].contains(specification.module) else { return nil }
            let name = quotedIdentifier(entry[1])
            return specification.module == "fts5"
                ? "INSERT INTO \(name)(\(name),rank) VALUES('integrity-check',1);"
                : "INSERT INTO \(name)(\(name)) VALUES('integrity-check');"
        }
        return .init(virtualSchema: (["PRAGMA writable_schema=ON; BEGIN;"] + virtualSchema + ["COMMIT; PRAGMA writable_schema=OFF;"]).joined(separator: "\n"),
                     objects: (["PRAGMA foreign_keys=OFF; BEGIN;"] + objects + ["COMMIT;"] + ftsChecks +
                        ["PRAGMA journal_mode=\(journalMode);"]).joined(separator: "\n"))
    }

    private func backupFiles(
        job: BackupJob,
        destinationDirectory: URL,
        baseName: String,
        onProgress: @escaping ProgressHandler
    ) async throws -> BackupResult {
        let source = URL(fileURLWithPath: job.sourcePath)
        let isDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        await onProgress(.init(fraction: 0.12, message: L10n.text("log.copying_files")))

        if job.archiveOutput {
            let output = uniqueURL(in: destinationDirectory, baseName: baseName, pathExtension: "zip")
            await onProgress(.init(fraction: 0.32, message: L10n.text("log.creating_archive")))
            do {
                try await execute(
                    executable: "/usr/bin/ditto",
                    arguments: ["-c", "-k", "--sequesterRsrc"]
                        + (isDirectory ? ["--keepParent"] : [])
                        + [source.path, output.path],
                    onLog: { await onProgress(.init(fraction: 0.72, message: $0)) }
                )
            } catch {
                try? FileManager.default.removeItem(at: output)
                throw error
            }
            return BackupResult(outputURL: output, message: L10n.text("engine.archive_created"))
        }

        let sourceExtension = BackupNaming.outputExtension(for: job, sourceIsDirectory: isDirectory)
        let output = uniqueURL(in: destinationDirectory, baseName: baseName, pathExtension: sourceExtension)
        do {
            if isDirectory {
                try await copyDirectory(from: source, to: output, excluding: []) { fraction in
                    await onProgress(.init(fraction: 0.12 + fraction * 0.78, message: L10n.text("log.copying_files")))
                }
            } else {
                try await copyItem(from: source, to: output) { fraction in
                    await onProgress(.init(fraction: 0.12 + fraction * 0.78, message: L10n.text("log.copying_files")))
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return BackupResult(outputURL: output, message: L10n.text("engine.files_copied"))
    }

    private func backupProject(
        job: BackupJob,
        destinationDirectory: URL,
        baseName: String,
        onProgress: @escaping ProgressHandler
    ) async throws -> BackupResult {
        let source = URL(fileURLWithPath: job.sourcePath, isDirectory: true)
        let exclusions = exclusionSet(from: job.projectExclusions)
        await onProgress(.init(fraction: 0.10, message: L10n.text("log.copying_project")))

        if !job.archiveOutput {
            let output = uniqueURL(in: destinationDirectory, baseName: baseName, pathExtension: "")
            do {
                try await copyDirectory(from: source, to: output, excluding: exclusions) { fraction in
                    await onProgress(.init(fraction: 0.10 + fraction * 0.82, message: L10n.text("log.copying_project")))
                }
            } catch {
                try? FileManager.default.removeItem(at: output)
                throw error
            }
            return BackupResult(outputURL: output, message: L10n.text("engine.project_copied"))
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupCron-\(UUID().uuidString)", isDirectory: true)
        let stagedProject = temporaryDirectory.appendingPathComponent(baseName, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        try await copyDirectory(from: source, to: stagedProject, excluding: exclusions) { fraction in
            await onProgress(.init(fraction: 0.10 + fraction * 0.58, message: L10n.text("log.copying_project")))
        }

        let output = uniqueURL(in: destinationDirectory, baseName: baseName, pathExtension: "zip")
        await onProgress(.init(fraction: 0.72, message: L10n.text("log.creating_archive")))
        do {
            try await execute(
                executable: "/usr/bin/ditto",
                arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", stagedProject.path, output.path],
                onLog: { await onProgress(.init(fraction: 0.88, message: $0)) }
            )
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return BackupResult(outputURL: output, message: L10n.text("engine.project_archive_created"))
    }

    private func backupDatabase(
        job: BackupJob,
        destinationDirectory: URL,
        baseName: String,
        rawExtension: String,
        dumpMessageKey: String,
        successMessageKey: String,
        onProgress: @escaping ProgressHandler,
        dump: @escaping @Sendable (URL, @escaping @Sendable (String) async -> Void) async throws -> Void
    ) async throws -> BackupResult {
        let rawOutput: URL
        let temporaryDirectory: URL?

        if job.archiveOutput {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("BackupCron-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            temporaryDirectory = directory
            rawOutput = directory.appendingPathComponent(baseName).appendingPathExtension(rawExtension)
        } else {
            temporaryDirectory = nil
            rawOutput = uniqueURL(in: destinationDirectory, baseName: baseName, pathExtension: rawExtension)
        }
        defer {
            if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        }

        await onProgress(.init(fraction: 0.15, message: L10n.text(dumpMessageKey)))
        do {
            try await dump(rawOutput) { line in
                await onProgress(.init(fraction: 0.62, message: line))
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: rawOutput.path)
            let rawSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard rawSize > 0 else {
                throw BackupEngineError.commandFailed(L10n.text("engine.empty_dump"))
            }
        } catch {
            try? FileManager.default.removeItem(at: rawOutput)
            throw error
        }

        guard job.archiveOutput else {
            return BackupResult(outputURL: rawOutput, message: L10n.text(successMessageKey))
        }

        let output = uniqueURL(in: destinationDirectory, baseName: baseName, pathExtension: "zip")
        await onProgress(.init(fraction: 0.76, message: L10n.text("log.creating_archive")))
        do {
            try await execute(
                executable: "/usr/bin/ditto",
                arguments: ["-c", "-k", "--sequesterRsrc", rawOutput.path, output.path],
                onLog: { await onProgress(.init(fraction: 0.90, message: $0)) }
            )
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return BackupResult(outputURL: output, message: L10n.text("engine.archive_created"))
    }

    private func runPostgres(
        job: BackupJob,
        password: String,
        output: URL,
        schemaOnly: Bool = false,
        onLog: @escaping @Sendable (String) async -> Void
    ) async throws {
        let dumpArguments = postgresArguments(job: job, schemaOnly: schemaOnly)

        switch job.connectionMode {
        case .direct:
            var environment = commandEnvironment()
            environment["PGPASSWORD"] = password
            environment["PGSSLMODE"] = job.useSSL ? "require" : "prefer"
            let executable = try resolveLocalTool(named: "pg_dump", customPath: job.clientExecutablePath)
            try await execute(executable: executable, arguments: dumpArguments + ["--file", output.path], environment: environment, onLog: onLog)

        case .docker:
            var environment = commandEnvironment()
            environment["PGPASSWORD"] = password
            var arguments = ["docker", "exec", "-e", "PGPASSWORD"]
            if job.useSSL {
                environment["PGSSLMODE"] = "require"
                arguments += ["-e", "PGSSLMODE"]
            }
            arguments += [job.dockerContainer, "pg_dump"] + dumpArguments
            try await execute(executable: "/usr/bin/env", arguments: arguments, environment: environment, standardOutputURL: output, onLog: onLog)

        case .ssh:
            let remoteCommand = postgresRemoteCommand(job: job, schemaOnly: schemaOnly)
            try await execute(executable: "/usr/bin/ssh", arguments: sshArguments(job: job, remoteCommand: remoteCommand), environment: commandEnvironment(), standardOutputURL: output, onLog: onLog)
        }
    }

    func postgresArguments(job: BackupJob, schemaOnly: Bool = false) -> [String] {
        var arguments = postgresConnectionArguments(job: job)
        if schemaOnly { arguments.append("--schema-only") }
        else {
            arguments += job.excludedDatabaseTables.map {
                "--exclude-table=" + quotedIdentifier($0.schema) + "." + quotedIdentifier($0.name)
            }
        }
        return arguments
    }

    private func quotedIdentifier(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func postgresConnectionArguments(job: BackupJob) -> [String] {
        // Explicit conninfo values reach libpq in direct, Docker and SSH modes.
        // Quoting dbname prevents '=' or URI-like names from changing the
        // selected connection. These are libpq escapes, not shell escapes.
        let databaseName = job.databaseName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let connection = "dbname='\(databaseName)' sslmode='\(job.useSSL ? "require" : "prefer")' connect_timeout='15'"
        return [
            "--host", job.host,
            "--port", String(job.port),
            "--username", job.username,
            "--dbname", connection,
            "--no-password"
        ]
    }

    func postgresRemoteCommand(job: BackupJob, schemaOnly: Bool = false) -> String {
        (["pg_dump"] + postgresArguments(job: job, schemaOnly: schemaOnly))
            .map(shellQuoted).joined(separator: " ")
    }

    private func runMySQL(
        job: BackupJob,
        password: String,
        output: URL,
        schemaOnly: Bool = false,
        onLog: @escaping @Sendable (String) async -> Void
    ) async throws {
        let dumpArguments = mysqlArguments(job: job, schemaOnly: schemaOnly)

        switch job.connectionMode {
        case .direct:
            var environment = commandEnvironment()
            environment["MYSQL_PWD"] = password
            let executable = try resolveLocalTool(named: "mysqldump", customPath: job.clientExecutablePath)
            try await execute(executable: executable, arguments: ["--result-file=\(output.path)"] + dumpArguments,
                              environment: environment, onLog: onLog)

        case .docker:
            var environment = commandEnvironment()
            environment["MYSQL_PWD"] = password
            let arguments = ["docker", "exec", "-e", "MYSQL_PWD", job.dockerContainer, "mysqldump"] + dumpArguments
            try await execute(executable: "/usr/bin/env", arguments: arguments, environment: environment, standardOutputURL: output, onLog: onLog)

        case .ssh:
            let remoteCommand = (["mysqldump"] + dumpArguments).map(shellQuoted).joined(separator: " ")
            try await execute(executable: "/usr/bin/ssh", arguments: sshArguments(job: job, remoteCommand: remoteCommand), environment: commandEnvironment(), standardOutputURL: output, onLog: onLog)
        }
    }

    func mysqlArguments(job: BackupJob, schemaOnly: Bool = false) -> [String] {
        var dumpArguments = [
            "--host=\(job.host)",
            "--port=\(job.port)",
            "--user=\(job.username)",
            "--single-transaction"
        ]
        if job.useSSL { dumpArguments.append("--ssl-mode=REQUIRED") }
        if schemaOnly { dumpArguments.append("--no-data") }
        else {
            dumpArguments += job.excludedDatabaseTables.map { "--ignore-table=\($0.schema).\($0.name)" }
        }
        return dumpArguments + ["--", job.databaseName]
    }

    private func validate(_ job: BackupJob) throws {
        guard !job.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BackupEngineError.invalidConfiguration(L10n.text("engine.enter_job_name"))
        }
        guard !job.nameMask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BackupEngineError.invalidConfiguration(L10n.text("validation.name_mask"))
        }
        guard !job.destinationPath.isEmpty else {
            throw BackupEngineError.invalidConfiguration(L10n.text("engine.choose_backup_folder"))
        }

        if job.kind == .files || job.kind == .project || job.kind == .sqlite {
            guard !job.sourcePath.isEmpty, FileManager.default.fileExists(atPath: job.sourcePath) else {
                throw BackupEngineError.invalidConfiguration(L10n.text("engine.source_not_found"))
            }
        }

        if job.kind == .project {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: job.sourcePath, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw BackupEngineError.invalidConfiguration(L10n.text("engine.project_source_required"))
            }
        }

        if job.kind == .files || job.kind == .project {
            let source = resolvedLocation(job.sourcePath)
            let destination = resolvedLocation(job.destinationPath)
            guard !destination.pathComponents.starts(with: source.pathComponents) else {
                throw BackupEngineError.invalidConfiguration(L10n.text("engine.destination_inside_source"))
            }
        }

        if job.kind == .postgres || job.kind == .mysql {
            try validateDatabaseConfiguration(job)
        }
    }

    private func validateDatabaseConfiguration(_ job: BackupJob) throws {
        guard job.kind == .postgres || job.kind == .mysql else {
            throw BackupEngineError.invalidConfiguration(L10n.text("engine.connection_test_database_only"))
        }
        guard !job.host.isEmpty, !job.username.isEmpty, !job.databaseName.isEmpty else {
            throw BackupEngineError.invalidConfiguration(L10n.text("engine.database_fields_required"))
        }
        if job.connectionMode == .docker && job.dockerContainer.isEmpty {
            throw BackupEngineError.invalidConfiguration(L10n.text("engine.docker_container_required"))
        }
        if job.connectionMode == .ssh && (job.sshHost.isEmpty || job.sshUsername.isEmpty) {
            throw BackupEngineError.invalidConfiguration(L10n.text("engine.ssh_fields_required"))
        }
    }

    private func resolvedLocation(_ path: String) -> URL {
        // Foundation does not resolve an ancestor symlink when the full path
        // does not exist yet. Resolve the existing ancestor, then append the
        // missing components so a new destination cannot hide inside a source.
        var existing = URL(fileURLWithPath: path).standardizedFileURL
        var missingComponents: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path) {
            let parent = existing.deletingLastPathComponent()
            guard parent.path != existing.path else { break }
            missingComponents.append(existing.lastPathComponent)
            existing = parent
        }
        var resolved = existing.resolvingSymlinksInPath().standardizedFileURL
        for component in missingComponents.reversed() {
            resolved.appendPathComponent(component)
        }
        return resolved
    }

    private func publishOutput(_ output: URL, in directory: URL) throws -> URL {
        let isDirectory = try output.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        let pathExtension = isDirectory ? "" : output.pathExtension
        let baseName = isDirectory || pathExtension.isEmpty
            ? output.lastPathComponent : output.deletingPathExtension().lastPathComponent

        var suffix: Int? = nil
        while true {
            try Task.checkCancellation()
            let name = suffix.map { "\(baseName)-\($0)" } ?? baseName
            var candidate = directory.appendingPathComponent(name)
            if !pathExtension.isEmpty { candidate.appendPathExtension(pathExtension) }

            // Work and destination are on the same volume. RENAME_EXCL makes
            // collision detection and publication one operation, including
            // collisions with dangling symlinks and other concurrent processes.
            let (status, errorCode) = output.withUnsafeFileSystemRepresentation { sourcePath in
                candidate.withUnsafeFileSystemRepresentation { destinationPath in
                    let status = renamex_np(sourcePath!, destinationPath!, UInt32(RENAME_EXCL))
                    return (status, errno)
                }
            }
            if status == 0 { return candidate }
            guard errorCode == EEXIST else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode), userInfo: [
                    NSFilePathErrorKey: candidate.path
                ])
            }
            suffix = (suffix ?? 1) + 1
        }
    }

    private func uniqueURL(in directory: URL, baseName: String, pathExtension: String) -> URL {
        func candidate(_ suffix: Int?) -> URL {
            let name = suffix.map { "\(baseName)-\($0)" } ?? baseName
            let url = directory.appendingPathComponent(name)
            return pathExtension.isEmpty ? url : url.appendingPathExtension(pathExtension)
        }

        var url = candidate(nil)
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = candidate(index)
            index += 1
        }
        return url
    }

    private func exclusionSet(from value: String) -> Set<String> {
        Set(
            value.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    private func copyItem(
        from source: URL,
        to destination: URL,
        onProgress: @escaping @Sendable (Double) async -> Void
    ) async throws {
        try Task.checkCancellation()
        await onProgress(0.08)
        try FileManager.default.copyItem(at: source, to: destination)
        try Task.checkCancellation()
        await onProgress(1)
    }

    private func copyDirectory(
        from source: URL,
        to destination: URL,
        excluding exclusions: Set<String>,
        onProgress: @escaping @Sendable (Double) async -> Void
    ) async throws {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let entries = try directoryEntries(at: source, keys: keys, excluding: exclusions)

        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let sourcePrefix = source.standardizedFileURL.path + "/"
        for (index, entry) in entries.enumerated() {
            try Task.checkCancellation()
            let sourcePath = entry.standardizedFileURL.path
            guard sourcePath.hasPrefix(sourcePrefix) else { continue }
            let relativePath = String(sourcePath.dropFirst(sourcePrefix.count))
            let target = destination.appendingPathComponent(relativePath)
            let values = try entry.resourceValues(forKeys: Set(keys))
            if values.isDirectory == true && values.isSymbolicLink != true {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: entry, to: target)
            }
            let fraction = Double(index + 1) / Double(max(entries.count, 1))
            await onProgress(fraction)
        }
        await onProgress(1)
    }

    private func directoryEntries(
        at source: URL,
        keys: [URLResourceKey],
        excluding exclusions: Set<String>
    ) throws -> [URL] {
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: source,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw BackupEngineError.commandFailed(L10n.text("engine.source_not_found"))
        }

        var entries: [URL] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            if exclusions.contains(url.lastPathComponent) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            entries.append(url)
        }
        if let enumerationError { throw enumerationError }
        return entries
    }

    private func verifyOutput(
        _ outputURL: URL,
        isArchive: Bool,
        onProgress: @escaping ProgressHandler
    ) async throws -> Int64 {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw BackupEngineError.commandFailed(L10n.text("engine.output_missing"))
        }

        if isArchive {
            try await execute(
                executable: "/usr/bin/unzip",
                arguments: ["-tqq", outputURL.path],
                onLog: { await onProgress(.init(fraction: 0.96, message: $0)) }
            )
        }
        return try outputSize(at: outputURL)
    }

    private func outputSize(at url: URL) throws -> Int64 {
        try Task.checkCancellation()
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        guard values.isDirectory == true else {
            return Int64(values.fileSize ?? 0)
        }

        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else { return 0 }

        var total: Int64 = 0
        for case let itemURL as URL in enumerator {
            try Task.checkCancellation()
            let itemValues = try itemURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if itemValues.isDirectory != true {
                total += Int64(itemValues.fileSize ?? 0)
            }
        }
        if let enumerationError { throw enumerationError }
        return total
    }

    private func commandEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let standardPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = [environment["PATH"], standardPaths].compactMap { $0 }.joined(separator: ":")
        return environment
    }

    private func resolveLocalTool(named name: String, customPath: String) throws -> String {
        let fileManager = FileManager.default
        if !customPath.isEmpty {
            guard fileManager.isExecutableFile(atPath: customPath) else {
                throw BackupEngineError.invalidConfiguration(L10n.text("engine.tool_not_executable", name))
            }
            return customPath
        }

        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/opt/homebrew/opt/libpq/bin/\(name)",
            "/opt/homebrew/opt/mysql-client/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/Applications/Postgres.app/Contents/Versions/latest/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        if let path = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return path
        }

        throw BackupEngineError.invalidConfiguration(L10n.text("engine.tool_not_found", name))
    }

    private func sshArguments(job: BackupJob, remoteCommand: String) -> [String] {
        var arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-p", String(job.sshPort)]
        if !job.sshIdentityPath.isEmpty {
            arguments += ["-i", job.sshIdentityPath]
        }
        arguments += ["\(job.sshUsername)@\(job.sshHost)", remoteCommand]
        return arguments
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func execute(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        standardOutputURL: URL? = nil,
        standardInputURL: URL? = nil,
        onLog: @escaping @Sendable (String) async -> Void
    ) async throws {
        try Task.checkCancellation()
        await onLog(L10n.text("log.running_command", URL(fileURLWithPath: executable).lastPathComponent))

        let outputHandle: FileHandle?
        if let standardOutputURL {
            FileManager.default.createFile(atPath: standardOutputURL.path, contents: nil)
            outputHandle = try FileHandle(forWritingTo: standardOutputURL)
        } else {
            outputHandle = nil
        }
        let inputHandle = try standardInputURL.map { try FileHandle(forReadingFrom: $0) }
        defer { try? inputHandle?.close() }

        let processController = ProcessController()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            let errorPipe = Pipe()
            let logBuffer = ProcessLogBuffer()
            let logDeliveryGroup = DispatchGroup()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment
            process.standardInput = inputHandle ?? FileHandle.nullDevice
            process.standardOutput = outputHandle ?? FileHandle.nullDevice
            process.standardError = errorPipe
            let cancelledBeforeLaunch = processController.attach(process)

            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                for line in logBuffer.consume(data) {
                    logDeliveryGroup.enter()
                    Task {
                        await onLog(line)
                        logDeliveryGroup.leave()
                    }
                }
            }

            process.terminationHandler = { process in
                try? outputHandle?.close()
                errorPipe.fileHandleForReading.readabilityHandler = nil
                let remainingData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                for line in logBuffer.consume(remainingData, flush: true) {
                    logDeliveryGroup.enter()
                    Task {
                        await onLog(line)
                        logDeliveryGroup.leave()
                    }
                }

                let terminationStatus = process.terminationStatus
                logDeliveryGroup.notify(queue: .global(qos: .utility)) {
                    if processController.isCancellationRequested {
                        if let standardOutputURL { try? FileManager.default.removeItem(at: standardOutputURL) }
                        continuation.resume(throwing: CancellationError())
                    } else if terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        if let standardOutputURL { try? FileManager.default.removeItem(at: standardOutputURL) }
                        let message = logBuffer.errorMessage
                        let fallback = L10n.text("engine.command_exit_code", terminationStatus)
                        continuation.resume(throwing: BackupEngineError.commandFailed(message.isEmpty ? fallback : message))
                    }
                }
            }

            do {
                if cancelledBeforeLaunch {
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    try? outputHandle?.close()
                    if let standardOutputURL { try? FileManager.default.removeItem(at: standardOutputURL) }
                    continuation.resume(throwing: CancellationError())
                    return
                }
                try process.run()
                if processController.isCancellationRequested {
                    process.terminate()
                }
            } catch {
                errorPipe.fileHandleForReading.readabilityHandler = nil
                try? outputHandle?.close()
                if let standardOutputURL { try? FileManager.default.removeItem(at: standardOutputURL) }
                continuation.resume(throwing: BackupEngineError.commandFailed(error.localizedDescription))
            }
            }
            try Task.checkCancellation()
        }, onCancel: {
            processController.cancel()
        })
    }
}
