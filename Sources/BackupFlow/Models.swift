import Foundation

enum BackupKind: String, Codable, CaseIterable, Identifiable {
    case files
    case project
    case sqlite
    case postgres
    case mysql

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: L10n.text("kind.files")
        case .project: L10n.text("kind.project")
        case .sqlite: "SQLite"
        case .postgres: "PostgreSQL"
        case .mysql: "MySQL"
        }
    }

    var symbol: String {
        switch self {
        case .files: "folder.fill"
        case .project: "hammer.fill"
        case .sqlite: "cylinder.split.1x2.fill"
        case .postgres: "server.rack"
        case .mysql: "externaldrive.fill.badge.timemachine"
        }
    }

    var tintName: String {
        switch self {
        case .files: "blue"
        case .project: "teal"
        case .sqlite: "purple"
        case .postgres: "indigo"
        case .mysql: "orange"
        }
    }
}

enum ScheduleKind: String, Codable, CaseIterable, Identifiable {
    case manual
    case interval
    case hourly
    case daily
    case weekly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: L10n.text("schedule.manual")
        case .interval: L10n.text("schedule.interval")
        case .hourly: L10n.text("schedule.hourly")
        case .daily: L10n.text("schedule.daily")
        case .weekly: L10n.text("schedule.weekly")
        }
    }
}

enum DatabaseConnectionMode: String, Codable, CaseIterable, Identifiable {
    case direct
    case docker
    case ssh

    var id: String { rawValue }

    var title: String {
        switch self {
        case .direct: L10n.text("connection.direct")
        case .docker: "Docker"
        case .ssh: L10n.text("connection.ssh")
        }
    }

    var symbol: String {
        switch self {
        case .direct: "network"
        case .docker: "shippingbox.fill"
        case .ssh: "terminal.fill"
        }
    }
}

struct SecurityScopedBookmark: Codable, Equatable {
    var data: Data
    var originalPath: String

    static func create(for url: URL) -> SecurityScopedBookmark? {
        guard let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return nil }
        return SecurityScopedBookmark(data: data, originalPath: url.standardizedFileURL.path)
    }

    func resolve(matching currentPath: String) -> URL? {
        guard URL(fileURLWithPath: currentPath).standardizedFileURL.path == originalPath else {
            return nil
        }

        var isStale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }
}

struct BackupJob: Codable, Identifiable, Equatable {
    var id = UUID()
    static var defaultName: String { L10n.text("job.default_name") }
    static let defaultNameMask = "{job}-{date}-{time}"
    static let defaultProjectExclusions = "node_modules, vendor, .build, DerivedData"
    // A missing field belongs to an older saved job, not a newly created one.
    private static let legacyProjectExclusions = ".git, node_modules, vendor, .build, DerivedData"
    static let minimumIntervalMinutes = 5
    static let maximumIntervalMinutes = 1_440

    var name = BackupJob.defaultName
    var kind: BackupKind = .files
    var sourcePath = ""
    var destinationPath = ""
    var sourceBookmark: SecurityScopedBookmark?
    var destinationBookmark: SecurityScopedBookmark?
    var clientExecutableBookmark: SecurityScopedBookmark?
    var sshIdentityBookmark: SecurityScopedBookmark?
    var archiveOutput = true
    var nameMask = BackupJob.defaultNameMask
    var retentionCount = 0
    var projectExclusions = BackupJob.defaultProjectExclusions
    var databaseName = ""
    var excludedDatabaseTables: [DatabaseTableReference] = []
    var host = "localhost"
    var port = 5432
    var username = ""
    var connectionMode: DatabaseConnectionMode = .direct
    var useSSL = false
    var clientExecutablePath = ""
    var dockerContainer = ""
    var sshHost = ""
    var sshPort = 22
    var sshUsername = ""
    var sshIdentityPath = ""
    var schedule: ScheduleKind = .manual
    var intervalMinutes = 60
    var scheduledTime = Calendar.current.date(from: DateComponents(hour: 2, minute: 0)) ?? Date()
    var weekday = 2
    var isEnabled = true
    var createdAt = Date()
    var lastRunAt: Date?

    var hasDatabaseSource: Bool { kind == .sqlite || kind == .postgres || kind == .mysql }

    var databaseTargetIdentity: [String] {
        if kind == .sqlite { return [kind.rawValue, sourcePath] }
        let database = [kind.rawValue, connectionMode.rawValue, host, String(port), databaseName]
        switch connectionMode {
        case .direct: return database
        case .docker: return database + [dockerContainer]
        case .ssh: return database + [sshHost, String(sshPort), sshUsername]
        }
    }

    var databaseConnectionIdentity: [String] {
        guard kind != .sqlite else { return databaseTargetIdentity }
        let connection = databaseTargetIdentity + [username, String(useSSL)]
        switch connectionMode {
        case .direct: return connection + [clientExecutablePath]
        case .docker: return connection
        case .ssh: return connection + [sshIdentityPath]
        }
    }

    // Keep the switch and the editable exclusion list as one persisted setting.
    var includesGitMetadata: Bool {
        get { !projectExclusionNames.contains(".git") }
        set {
            guard newValue != includesGitMetadata else { return }
            if newValue {
                projectExclusions = projectExclusionNames.filter { $0 != ".git" }.joined(separator: ", ")
            } else {
                projectExclusions += projectExclusions.isEmpty ? ".git" : ", .git"
            }
        }
    }

    private var projectExclusionNames: [String] {
        projectExclusions.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var connectionDescription: String {
        switch connectionMode {
        case .direct:
            return "\(username)@\(host):\(port)/\(databaseName)"
        case .docker:
            return "Docker: \(dockerContainer) → \(databaseName)"
        case .ssh:
            return "\(sshUsername)@\(sshHost):\(sshPort) → \(databaseName)"
        }
    }

    var scheduleDescription: String {
        switch schedule {
        case .manual:
            return L10n.text("schedule.manual_only")
        case .interval:
            return L10n.text("schedule.every_minutes", effectiveIntervalMinutes)
        case .hourly:
            return L10n.text("schedule.hourly")
        case .daily:
            return L10n.text(
                "schedule.daily_at",
                scheduledTime.formatted(date: .omitted, time: .shortened)
            )
        case .weekly:
            let symbols = Calendar.current.weekdaySymbols
            let index = max(1, min(7, weekday)) - 1
            return L10n.text(
                "schedule.weekly_at",
                symbols[index].capitalized,
                scheduledTime.formatted(date: .omitted, time: .shortened)
            )
        }
    }

    var nextRunAt: Date? {
        nextRun(after: Date())
    }

    func nextRun(after now: Date, calendar: Calendar = .current) -> Date? {
        guard isEnabled else { return nil }

        switch schedule {
        case .manual:
            return nil
        case .interval:
            return nextInterval(
                after: now,
                anchor: lastRunAt ?? createdAt,
                seconds: TimeInterval(effectiveIntervalMinutes * 60)
            )
        case .hourly:
            return nextInterval(after: now, anchor: lastRunAt ?? createdAt, seconds: 3_600)
        case .daily:
            let time = calendar.dateComponents([.hour, .minute], from: scheduledTime)
            var components = calendar.dateComponents([.year, .month, .day], from: now)
            components.hour = time.hour
            components.minute = time.minute
            components.second = 0
            let today = calendar.date(from: components) ?? now
            return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
        case .weekly:
            let time = calendar.dateComponents([.hour, .minute], from: scheduledTime)
            var components = DateComponents()
            components.weekday = weekday
            components.hour = time.hour
            components.minute = time.minute
            components.second = 0
            return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime)
        }
    }

    func isDue(at now: Date, calendar: Calendar = .current) -> Bool {
        guard isEnabled, schedule != .manual else { return false }

        switch schedule {
        case .manual:
            return false
        case .interval:
            return now.timeIntervalSince(lastRunAt ?? createdAt) >= TimeInterval(effectiveIntervalMinutes * 60)
        case .hourly:
            return now.timeIntervalSince(lastRunAt ?? createdAt) >= 3600
        case .daily:
            let last = lastRunAt ?? createdAt
            let scheduledToday = scheduledDate(on: now, calendar: calendar)
            return scheduledToday <= now && last < scheduledToday
        case .weekly:
            var components = DateComponents()
            components.weekday = weekday
            let time = calendar.dateComponents([.hour, .minute], from: scheduledTime)
            components.hour = time.hour
            components.minute = time.minute
            components.second = 0
            guard let mostRecent = calendar.nextDate(
                after: now,
                matching: components,
                matchingPolicy: .nextTime,
                direction: .backward
            ) else { return false }
            return (lastRunAt ?? createdAt) < mostRecent
        }
    }

    private func scheduledDate(on date: Date, calendar: Calendar) -> Date {
        let time = calendar.dateComponents([.hour, .minute], from: scheduledTime)
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = time.hour
        components.minute = time.minute
        components.second = 0
        return calendar.date(from: components) ?? date
    }

    private var effectiveIntervalMinutes: Int {
        min(max(intervalMinutes, Self.minimumIntervalMinutes), Self.maximumIntervalMinutes)
    }

    private func nextInterval(after now: Date, anchor: Date, seconds: TimeInterval) -> Date {
        let firstCandidate = anchor.addingTimeInterval(seconds)
        guard firstCandidate <= now else { return firstCandidate }
        let completedIntervals = floor(now.timeIntervalSince(anchor) / seconds)
        return anchor.addingTimeInterval((completedIntervals + 1) * seconds)
    }
}

extension BackupJob {
    private enum CodingKeys: String, CodingKey {
        case id, name, kind, sourcePath, destinationPath, databaseName, host, port, username
        case sourceBookmark, destinationBookmark, clientExecutableBookmark, sshIdentityBookmark
        case archiveOutput, nameMask, retentionCount, projectExclusions, excludedDatabaseTables
        case connectionMode, useSSL, clientExecutablePath, dockerContainer
        case sshHost, sshPort, sshUsername, sshIdentityPath
        case schedule, intervalMinutes, scheduledTime, weekday, isEnabled, createdAt, lastRunAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? BackupJob.defaultName
        kind = try container.decodeIfPresent(BackupKind.self, forKey: .kind) ?? .files
        sourcePath = try container.decodeIfPresent(String.self, forKey: .sourcePath) ?? ""
        destinationPath = try container.decodeIfPresent(String.self, forKey: .destinationPath) ?? ""
        sourceBookmark = try container.decodeIfPresent(SecurityScopedBookmark.self, forKey: .sourceBookmark)
        destinationBookmark = try container.decodeIfPresent(SecurityScopedBookmark.self, forKey: .destinationBookmark)
        clientExecutableBookmark = try container.decodeIfPresent(SecurityScopedBookmark.self, forKey: .clientExecutableBookmark)
        sshIdentityBookmark = try container.decodeIfPresent(SecurityScopedBookmark.self, forKey: .sshIdentityBookmark)
        archiveOutput = try container.decodeIfPresent(Bool.self, forKey: .archiveOutput) ?? true
        nameMask = try container.decodeIfPresent(String.self, forKey: .nameMask) ?? BackupJob.defaultNameMask
        retentionCount = try container.decodeIfPresent(Int.self, forKey: .retentionCount) ?? 0
        projectExclusions = try container.decodeIfPresent(String.self, forKey: .projectExclusions)
            ?? BackupJob.legacyProjectExclusions
        databaseName = try container.decodeIfPresent(String.self, forKey: .databaseName) ?? ""
        excludedDatabaseTables = try container.decodeIfPresent([DatabaseTableReference].self, forKey: .excludedDatabaseTables) ?? []
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? "localhost"
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 5432
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        connectionMode = try container.decodeIfPresent(DatabaseConnectionMode.self, forKey: .connectionMode) ?? .direct
        useSSL = try container.decodeIfPresent(Bool.self, forKey: .useSSL) ?? false
        clientExecutablePath = try container.decodeIfPresent(String.self, forKey: .clientExecutablePath) ?? ""
        dockerContainer = try container.decodeIfPresent(String.self, forKey: .dockerContainer) ?? ""
        sshHost = try container.decodeIfPresent(String.self, forKey: .sshHost) ?? ""
        sshPort = try container.decodeIfPresent(Int.self, forKey: .sshPort) ?? 22
        sshUsername = try container.decodeIfPresent(String.self, forKey: .sshUsername) ?? ""
        sshIdentityPath = try container.decodeIfPresent(String.self, forKey: .sshIdentityPath) ?? ""
        schedule = try container.decodeIfPresent(ScheduleKind.self, forKey: .schedule) ?? .manual
        intervalMinutes = min(
            max(
                try container.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 60,
                BackupJob.minimumIntervalMinutes
            ),
            BackupJob.maximumIntervalMinutes
        )
        scheduledTime = try container.decodeIfPresent(Date.self, forKey: .scheduledTime)
            ?? Calendar.current.date(from: DateComponents(hour: 2, minute: 0))
            ?? Date()
        weekday = try container.decodeIfPresent(Int.self, forKey: .weekday) ?? 2
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastRunAt = try container.decodeIfPresent(Date.self, forKey: .lastRunAt)
    }
}

struct DatabaseTableReference: Codable, Hashable, Sendable {
    var schema: String
    var name: String
    var displayName: String { schema + "." + name }

    // Database identifiers can differ only by Unicode normalization. Swift's
    // default String equality would merge those distinct tables in selections.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.schema.utf8.elementsEqual(rhs.schema.utf8) && lhs.name.utf8.elementsEqual(rhs.name.utf8)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(Data(schema.utf8))
        hasher.combine(Data(name.utf8))
    }
}

struct DatabaseTableInfo: Decodable, Identifiable, Equatable, Sendable {
    var schema: String
    var name: String
    var objectType: String
    var sizeBytes: Int64?
    var requiredTables: [DatabaseTableReference] = []
    var parentTables: [DatabaseTableReference] = []
    var dependencyInspectionError: String? = nil
    var id: DatabaseTableReference { .init(schema: schema, name: name) }
}

struct DatabaseCatalog: Decodable, Equatable, Sendable {
    var sizeBytes: Int64?
    var tables: [DatabaseTableInfo]

    // A partition/inheritance child belongs to an excluded parent, including
    // children created since the job was saved. Foreign-key children do not.
    func effectiveExclusions(_ exclusions: [DatabaseTableReference]) -> Set<DatabaseTableReference> {
        var result = Set(exclusions)
        var changed = true
        while changed {
            changed = false
            for table in tables where !result.contains(table.id) {
                if table.parentTables.contains(where: result.contains) {
                    result.insert(table.id)
                    changed = true
                }
            }
        }
        return result
    }

    func selectedSize(excluding exclusions: [DatabaseTableReference]) -> Int64? {
        let excluded = effectiveExclusions(exclusions)
        var total: Int64 = 0
        for table in tables where !excluded.contains(table.id) {
            guard let size = table.sizeBytes, size >= 0 else { return nil }
            let sum = total.addingReportingOverflow(size)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return total
    }

    func selectionError(excluding exclusions: [DatabaseTableReference]) -> String? {
        let excluded = effectiveExclusions(exclusions)
        let included = tables.filter { !excluded.contains($0.id) }
        if !tables.isEmpty && included.isEmpty { return L10n.text("database.select_one") }
        for table in included {
            if let dependency = table.requiredTables.first(where: excluded.contains) {
                return L10n.text("database.required_table", dependency.displayName, table.id.displayName)
            }
            if !excluded.isEmpty, table.dependencyInspectionError != nil {
                return L10n.text("database.dependencies_unknown", table.id.displayName)
            }
        }
        return nil
    }
}

// Keep selections attached to their source while the user edits connection
// fields, including intermediate text values and switching back to a source.
struct DatabaseSelectionDraft {
    private var selections: [[String]: [DatabaseTableReference]] = [:]

    mutating func move(from previous: BackupJob, to current: BackupJob) -> [DatabaseTableReference] {
        selections[previous.databaseTargetIdentity] = previous.excludedDatabaseTables
        return selections[current.databaseTargetIdentity] ?? []
    }

    static func requiresInspection(original: BackupJob?, draft: BackupJob, passwordChanged: Bool) -> Bool {
        guard draft.hasDatabaseSource else { return false }
        guard let original else { return true }
        return passwordChanged || original.databaseConnectionIdentity != draft.databaseConnectionIdentity ||
            Set(original.excludedDatabaseTables) != Set(draft.excludedDatabaseTables)
    }
}

struct DiskSpaceAvailability: Equatable, Sendable {
    var volumeID: String
    var availableBytes: Int64?
    var path: String
}

struct DatabaseSpaceEstimate: Equatable, Sendable {
    var rawBytes: Int64?
    var workingBytes: Int64?
    var archiveBytes: Int64?

    init(job: BackupJob, catalog: DatabaseCatalog?) {
        // SQLite first copies the entire database, even when most tables will
        // be excluded. Rebuilding and sorting indexes use the same work volume.
        let source = job.kind == .sqlite ? catalog?.sizeBytes : catalog?.selectedSize(excluding: job.excludedDatabaseTables)
        rawBytes = Self.multiply(source, by: job.kind == .sqlite ? 1 : 2)
        workingBytes = Self.multiply(rawBytes, by: job.kind == .sqlite && !job.excludedDatabaseTables.isEmpty ? 3 : 1)
        // Allow for ZIP overhead and incompressible input. SQL estimates are
        // heuristic: physical table sizes do not predict SQL text precisely.
        archiveBytes = rawBytes.flatMap { Self.add($0, $0 / 100, 65_536) }
    }

    private static func multiply(_ value: Int64?, by factor: Int64) -> Int64? {
        guard let value, value >= 0 else { return nil }
        let result = value.multipliedReportingOverflow(by: factor)
        return result.overflow ? nil : result.partialValue
    }

    static func add(_ values: Int64...) -> Int64? {
        var total: Int64 = 0
        for value in values {
            guard value >= 0 else { return nil }
            let result = total.addingReportingOverflow(value)
            guard !result.overflow else { return nil }
            total = result.partialValue
        }
        return total
    }
}

struct DatabaseSpaceRequirement: Identifiable, Equatable, Sendable {
    var locationKey: String
    var disk: DiskSpaceAvailability
    var requiredBytes: Int64?
    var id: String { locationKey }
    var isInsufficient: Bool {
        guard let requiredBytes, let available = disk.availableBytes else { return false }
        return available < requiredBytes
    }

    static func plan(estimate: DatabaseSpaceEstimate, destination: DiskSpaceAvailability,
                     temporary: DiskSpaceAvailability, archive: Bool) -> [Self] {
        guard archive else {
            return [.init(locationKey: "database.space_destination", disk: destination, requiredBytes: estimate.workingBytes)]
        }
        if !destination.volumeID.isEmpty && destination.volumeID == temporary.volumeID {
            let peak = estimate.rawBytes.flatMap { raw in
                estimate.archiveBytes.flatMap { DatabaseSpaceEstimate.add(raw, $0) }
            }.flatMap { archivePeak in estimate.workingBytes.map { max($0, archivePeak) } }
            var disk = destination
            if let available = temporary.availableBytes {
                disk.availableBytes = disk.availableBytes.map { min($0, available) } ?? available
            }
            return [.init(locationKey: "database.space_shared", disk: disk, requiredBytes: peak)]
        }
        return [.init(locationKey: "database.space_destination", disk: destination, requiredBytes: estimate.archiveBytes),
                .init(locationKey: "database.space_temporary", disk: temporary, requiredBytes: estimate.workingBytes)]
    }
}

enum BackupStatus: String, Codable {
    case success
    case failure
    case cancelled
}

struct BackupRun: Codable, Identifiable, Equatable {
    var id = UUID()
    var jobID: UUID
    var jobName: String
    var startedAt: Date
    var finishedAt: Date
    var status: BackupStatus
    var outputPath: String?
    var outputSizeBytes: Int64? = nil
    var message: String
    var logs: [String]? = nil

    var duration: TimeInterval {
        finishedAt.timeIntervalSince(startedAt)
    }
}

enum BackupNaming {
    static func render(mask: String, job: BackupJob, date: Date = Date(), calendar: Calendar = .current) -> String {
        let locale = Locale(identifier: "en_US_POSIX")
        let dateFormatter = DateFormatter()
        dateFormatter.locale = locale
        dateFormatter.calendar = calendar
        dateFormatter.timeZone = calendar.timeZone
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let timeFormatter = DateFormatter()
        timeFormatter.locale = locale
        timeFormatter.calendar = calendar
        timeFormatter.timeZone = calendar.timeZone
        timeFormatter.dateFormat = "HH-mm-ss"

        let replacements = [
            "{job}": job.name,
            "{type}": job.kind.rawValue,
            "{date}": dateFormatter.string(from: date),
            "{time}": timeFormatter.string(from: date)
        ]
        var remaining = mask[...]
        var expanded = ""
        // Read only the original mask. Inserted job names are literal values,
        // so tokens inside them cannot be expanded again in dictionary order.
        while !remaining.isEmpty {
            if let replacement = replacements.first(where: { remaining.hasPrefix($0.key) }) {
                expanded.append(replacement.value)
                remaining.removeFirst(replacement.key.count)
            } else {
                expanded.append(remaining.removeFirst())
            }
        }
        return sanitize(expanded)
    }

    static func outputExtension(for job: BackupJob, sourceIsDirectory: Bool = false) -> String {
        if job.archiveOutput { return "zip" }
        switch job.kind {
        case .files:
            return sourceIsDirectory ? "" : URL(fileURLWithPath: job.sourcePath).pathExtension
        case .project:
            return ""
        case .sqlite:
            return "sqlite3"
        case .postgres, .mysql:
            return "sql"
        }
    }

    private static func sanitize(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let mapped = value.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
        let collapsed = mapped.split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        return trimmed.isEmpty ? "backup" : trimmed
    }
}

struct PersistedState: Codable {
    var jobs: [BackupJob]
    var history: [BackupRun]
}

// Presentation is derived from recorded outcomes, never from an enabled timer.
enum BackupHealth: Equatable {
    case neverRun, running, success, failure, cancelled

    var titleKey: String {
        switch self {
        case .neverRun: "ux.not_run"
        case .running: "activity.in_progress"
        case .success: "ux.backup_created"
        case .failure: "ux.last_failed"
        case .cancelled: "ux.last_cancelled"
        }
    }

    var needsAttention: Bool { self == .failure || self == .cancelled || self == .neverRun }
}

struct JobSnapshot {
    let latestAttempt: BackupRun?
    let latestSuccess: BackupRun?
    let health: BackupHealth

    init(jobID: UUID, history: [BackupRun], isRunning: Bool) {
        let runs = history.filter { $0.jobID == jobID }.sorted { $0.finishedAt > $1.finishedAt }
        latestAttempt = runs.first
        latestSuccess = runs.first { $0.status == .success }
        if isRunning { health = .running }
        else {
            switch latestAttempt?.status {
            case .success: health = .success
            case .failure: health = .failure
            case .cancelled: health = .cancelled
            case nil: health = .neverRun
            }
        }
    }
}

enum BackupScheduleState: Equatable {
    case manual, paused, afterCurrent, due, scheduled(Date)

    init(job: BackupJob, schedulerEnabled: Bool, isRunning: Bool, now: Date = Date()) {
        if job.schedule == .manual { self = .manual }
        else if !schedulerEnabled || !job.isEnabled { self = .paused }
        else if isRunning { self = .afterCurrent }
        else if job.isDue(at: now) { self = .due }
        else if let next = job.nextRun(after: now) { self = .scheduled(next) }
        else { self = .paused }
    }

    var text: String {
        switch self {
        case .manual: L10n.text("schedule.manual_only")
        case .paused: L10n.text("status.scheduler_paused")
        case .afterCurrent: L10n.text("ux.after_current")
        case .due: L10n.text("ux.waiting_scheduler")
        case .scheduled(let date): date.formatted(date: .abbreviated, time: .shortened)
        }
    }
}

enum JobSetupStep: Int, CaseIterable, Identifiable {
    case source, destination, schedule
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .source: L10n.text("common.source")
        case .destination: L10n.text("editor.destination")
        case .schedule: L10n.text("common.schedule")
        }
    }

    func validationKey(for job: BackupJob) -> String? {
        func empty(_ value: String) -> Bool { value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        switch self {
        case .source:
            if empty(job.name) { return "validation.enter_name" }
            if job.kind == .postgres || job.kind == .mysql {
                if empty(job.host) || empty(job.username) || empty(job.databaseName) { return "validation.database_parameters" }
                if !(1...65535).contains(job.port) { return "ux.invalid_port" }
                if job.connectionMode == .docker && empty(job.dockerContainer) { return "validation.docker_container" }
                if job.connectionMode == .ssh {
                    if empty(job.sshHost) || empty(job.sshUsername) { return "validation.ssh_connection" }
                    if !(1...65535).contains(job.sshPort) { return "ux.invalid_port" }
                }
            } else if empty(job.sourcePath) { return "validation.choose_source" }
        case .destination:
            if empty(job.destinationPath) { return "validation.choose_destination" }
            if empty(job.nameMask) { return "validation.name_mask" }
        case .schedule:
            break
        }
        return nil
    }
}
