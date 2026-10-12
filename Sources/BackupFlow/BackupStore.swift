import AppKit
import Combine
import Foundation

@MainActor
final class BackupStore: ObservableObject {
    @Published private(set) var jobs: [BackupJob] = []
    @Published private(set) var history: [BackupRun] = []
    @Published private(set) var runningJobIDs: Set<UUID> = []
    @Published private(set) var progressByJob: [UUID: Double] = [:]
    @Published private(set) var liveLogsByJob: [UUID: [String]] = [:]
    @Published private(set) var currentMessageByJob: [UUID: String] = [:]
    @Published private(set) var startedAtByJob: [UUID: Date] = [:]
    @Published var errorMessage: String?
    @Published var schedulerEnabled = true {
        didSet { UserDefaults.standard.set(schedulerEnabled, forKey: "schedulerEnabled") }
    }

    private let engine = BackupEngine()
    private var schedulerTimer: Timer?
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private let stateURL: URL
    private let passwordWriter: (String, UUID) throws -> Void

    init(
        stateDirectory: URL? = nil,
        passwordWriter: @escaping (String, UUID) throws -> Void = { try KeychainStore.setPassword($0, for: $1) }
    ) {
        self.passwordWriter = passwordWriter
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = stateDirectory ?? base.appendingPathComponent("BackupCron", isDirectory: true)
        stateURL = directory.appendingPathComponent("state.json")
        if stateDirectory == nil {
            migrateLegacyStateIfNeeded(from: base.appendingPathComponent("BackupFlow", isDirectory: true))
        }
        schedulerEnabled = UserDefaults.standard.object(forKey: "schedulerEnabled") as? Bool ?? true
        load()
    }

    var successfulRuns: Int { history.filter { $0.status == .success }.count }
    var failedRuns: Int { history.filter { $0.status == .failure }.count }

    func startScheduler() {
        guard schedulerTimer == nil else { return }
        schedulerTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.runDueJobs()
            }
        }
        runDueJobs()
    }

    func addOrUpdate(_ job: BackupJob, password: String? = nil) throws {
        var updatedJobs = jobs
        if let index = updatedJobs.firstIndex(where: { $0.id == job.id }) {
            updatedJobs[index] = job
        } else {
            updatedJobs.append(job)
        }

        var passwordChanged = false
        if job.kind == .postgres || job.kind == .mysql {
            if let password {
                try passwordWriter(password, job.id)
                passwordChanged = true
            }
        } else if jobs.contains(where: { $0.id == job.id && ($0.kind == .postgres || $0.kind == .mysql) }) {
            try passwordWriter("", job.id)
            passwordChanged = true
        }
        do {
            try writeState(jobs: updatedJobs)
        } catch {
            // Keychain and the state file cannot be committed atomically.
            // Report a partial credential update explicitly; retain the draft.
            throw SaveError(reason: error, passwordChanged: passwordChanged)
        }
        jobs = updatedJobs
    }

    @discardableResult
    func delete(_ job: BackupJob) -> Bool {
        let updatedJobs = jobs.filter { $0.id != job.id }
        do {
            try writeState(jobs: updatedJobs)
        } catch {
            errorMessage = SaveError(reason: error, passwordChanged: false).localizedDescription
            return false
        }
        cancel(job)
        jobs = updatedJobs
        do {
            try passwordWriter("", job.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        return true
    }

    func setEnabled(_ enabled: Bool, for jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        var updatedJobs = jobs
        updatedJobs[index].isEnabled = enabled
        do {
            try writeState(jobs: updatedJobs)
            jobs = updatedJobs
        } catch {
            errorMessage = SaveError(reason: error, passwordChanged: false).localizedDescription
        }
    }

    func password(for jobID: UUID) -> String {
        KeychainStore.password(for: jobID)
    }

    func progress(for jobID: UUID) -> Double {
        progressByJob[jobID] ?? 0
    }

    func logs(for jobID: UUID) -> [String] {
        if let live = liveLogsByJob[jobID] { return live }
        return history.first(where: { $0.jobID == jobID })?.logs ?? []
    }

    func currentMessage(for jobID: UUID) -> String {
        currentMessageByJob[jobID]
            ?? history.first(where: { $0.jobID == jobID })?.message
            ?? L10n.text("activity.waiting")
    }

    func run(_ job: BackupJob) {
        guard !runningJobIDs.contains(job.id) else { return }
        runningJobIDs.insert(job.id)
        progressByJob[job.id] = 0
        liveLogsByJob[job.id] = []
        appendLog(L10n.text("log.started", job.name), for: job.id)
        let startedAt = Date()
        startedAtByJob[job.id] = startedAt

        let task = Task {
            do {
                let password: String
                if (job.kind == .postgres || job.kind == .mysql) && job.connectionMode != .ssh {
                    password = await Task.detached(priority: .userInitiated) {
                        KeychainStore.password(for: job.id)
                    }.value
                } else {
                    password = ""
                }
                try Task.checkCancellation()
                let progressStore = self
                let result = try await engine.run(job: job, password: password) { event in
                    await progressStore.record(event, for: job.id)
                }
                finish(
                    job: job,
                    startedAt: startedAt,
                    status: .success,
                    outputPath: result.outputURL.path,
                    outputSizeBytes: result.sizeBytes,
                    message: result.message
                )
            } catch {
                let wasCancelled = error is CancellationError
                record(
                    BackupProgressEvent(
                        fraction: progress(for: job.id),
                        message: wasCancelled
                            ? L10n.text("log.cancelled")
                            : L10n.text("log.failed", error.localizedDescription)
                    ),
                    for: job.id
                )
                finish(
                    job: job,
                    startedAt: startedAt,
                    status: wasCancelled ? .cancelled : .failure,
                    outputPath: nil,
                    outputSizeBytes: nil,
                    message: wasCancelled ? L10n.text("status.cancelled") : error.localizedDescription
                )
            }
        }
        runningTasks[job.id] = task
    }

    func cancel(_ job: BackupJob) {
        runningTasks[job.id]?.cancel()
    }

    private func record(_ event: BackupProgressEvent, for jobID: UUID) {
        progressByJob[jobID] = min(max(event.fraction, 0), 1)
        currentMessageByJob[jobID] = event.message
        guard liveLogsByJob[jobID]?.last.map({ !$0.hasSuffix(event.message) }) ?? true else { return }
        appendLog(event.message, for: jobID)
    }

    private func appendLog(_ message: String, for jobID: UUID) {
        let timestamp = Date().formatted(date: .omitted, time: .standard)
        var logs = liveLogsByJob[jobID] ?? []
        logs.append("[\(timestamp)] \(message)")
        liveLogsByJob[jobID] = Array(logs.suffix(500))
    }

    func reveal(_ run: BackupRun) {
        guard let path = run.outputPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func runDueJobs() {
        guard schedulerEnabled else { return }
        for job in jobs where job.isDue(at: Date()) && !runningJobIDs.contains(job.id) {
            run(job)
        }
    }

    private func finish(
        job: BackupJob,
        startedAt: Date,
        status: BackupStatus,
        outputPath: String?,
        outputSizeBytes: Int64?,
        message: String
    ) {
        let logs = liveLogsByJob[job.id]
        runningJobIDs.remove(job.id)
        startedAtByJob.removeValue(forKey: job.id)
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index].lastRunAt = Date()
        }

        let run = BackupRun(
            jobID: job.id,
            jobName: job.name,
            startedAt: startedAt,
            finishedAt: Date(),
            status: status,
            outputPath: outputPath,
            outputSizeBytes: outputSizeBytes,
            message: message,
            logs: logs
        )
        history.insert(run, at: 0)
        let handledInForeground = BackupAudioFeedback.shared.handleResult(status)
        BackupNotifications.post(run, suppressSound: handledInForeground)
        if status == .success {
            applyRetention(for: job)
        }
        history = Array(history.prefix(200))
        progressByJob.removeValue(forKey: job.id)
        liveLogsByJob.removeValue(forKey: job.id)
        currentMessageByJob.removeValue(forKey: job.id)
        runningTasks.removeValue(forKey: job.id)
        persist()
    }

    private func applyRetention(for job: BackupJob) {
        guard job.retentionCount > 0 else { return }

        let fallbackURL = URL(fileURLWithPath: job.destinationPath, isDirectory: true)
        let destinationURL = job.destinationBookmark?.resolve(matching: job.destinationPath) ?? fallbackURL
        let accessed = destinationURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { destinationURL.stopAccessingSecurityScopedResource() }
        }

        let removedCount = BackupRetention.prune(
            jobID: job.id,
            destinationURL: destinationURL,
            keepCount: job.retentionCount,
            history: &history
        )
        guard removedCount > 0, let currentIndex = history.firstIndex(where: { $0.jobID == job.id }) else {
            return
        }

        let timestamp = Date().formatted(date: .omitted, time: .standard)
        var logs = history[currentIndex].logs ?? []
        logs.append("[\(timestamp)] \(L10n.text("log.retention_removed", removedCount))")
        history[currentIndex].logs = Array(logs.suffix(500))
    }

    private func load() {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder.pretty.decode(PersistedState.self, from: data) else {
            return
        }
        jobs = state.jobs
        history = state.history
    }

    private func persist() {
        do {
            try writeState(jobs: jobs)
        } catch {
            errorMessage = SaveError(reason: error, passwordChanged: false).localizedDescription
        }
    }

    private func writeState(jobs: [BackupJob]) throws {
        let directory = stateURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(PersistedState(jobs: jobs, history: history))
        try data.write(to: stateURL, options: .atomic)
    }

    struct SaveError: LocalizedError {
        let reason: Error
        let passwordChanged: Bool

        var errorDescription: String? {
            L10n.text(
                passwordChanged ? "store.state_save_password_changed" : "store.state_save_failed",
                reason.localizedDescription
            )
        }
    }

    private func migrateLegacyStateIfNeeded(from legacyDirectory: URL) {
        let legacyStateURL = legacyDirectory.appendingPathComponent("state.json")
        guard !FileManager.default.fileExists(atPath: stateURL.path),
              FileManager.default.fileExists(atPath: legacyStateURL.path) else {
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: legacyStateURL, to: stateURL)
        } catch {
            NSLog("BackupCron: %@", L10n.text("store.state_migration_failed", error.localizedDescription))
        }
    }
}

enum BackupRetention {
    @discardableResult
    static func prune(
        jobID: UUID,
        destinationURL: URL,
        keepCount: Int,
        history: inout [BackupRun],
        fileManager: FileManager = .default
    ) -> Int {
        guard keepCount > 0 else { return 0 }

        let destinationPath = destinationURL.standardizedFileURL.resolvingSymlinksInPath().path
        let candidateIndices = history.indices
            .filter { index in
                let run = history[index]
                guard run.jobID == jobID,
                      run.status == .success,
                      let outputPath = run.outputPath else {
                    return false
                }
                let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
                let parentPath = outputURL.deletingLastPathComponent().resolvingSymlinksInPath().path
                return parentPath == destinationPath && fileManager.fileExists(atPath: outputURL.path)
            }
            .sorted { history[$0].finishedAt > history[$1].finishedAt }

        var removedCount = 0
        for index in candidateIndices.dropFirst(keepCount) {
            guard let outputPath = history[index].outputPath else { continue }
            let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
            do {
                try fileManager.removeItem(at: outputURL)
                history[index].outputPath = nil
                history[index].message = L10n.text("history.removed_by_retention")
                removedCount += 1
            } catch {
                NSLog("BackupCron: %@", L10n.text("store.retention_remove_failed", outputURL.lastPathComponent, error.localizedDescription))
            }
        }
        return removedCount
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var pretty: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
