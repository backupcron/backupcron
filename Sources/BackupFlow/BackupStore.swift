import AppKit
import Combine
import Foundation

@MainActor
final class BackupStore: ObservableObject {
    @Published private(set) var jobs: [BackupJob] = [] {
        didSet { settingsBackup.schedule() }
    }
    @Published private(set) var groups: [BackupGroup] = [] {
        didSet { settingsBackup.schedule() }
    }
    @Published private(set) var coldStorages: [ColdStorageDestination] = [] {
        didSet { settingsBackup.schedule() }
    }
    private var coldClaims: [UUID: String] = [:]
    @Published private(set) var history: [BackupRun] = []
    @Published private(set) var runningJobIDs: Set<UUID> = []
    @Published private(set) var progressByJob: [UUID: Double] = [:]
    @Published private(set) var liveLogsByJob: [UUID: [String]] = [:]
    @Published private(set) var currentMessageByJob: [UUID: String] = [:]
    @Published private(set) var phaseByJob: [UUID: BackupProgressPhase] = [:]
    @Published private(set) var startedAtByJob: [UUID: Date] = [:]
    @Published var errorMessage: String?
    @Published var schedulerEnabled = true {
        didSet { defaults.set(schedulerEnabled, forKey: "schedulerEnabled"); settingsBackup.schedule() }
    }

    let settingsBackup: SettingsBackupController
    private let defaults: UserDefaults

    private let engine = BackupEngine()
    private let coldEngine: ColdStorageEngine
    private let volumeProvider: () -> [MountedBackupVolume]
    private var schedulerTimer: Timer?
    private var syncTimer: Timer?
    private var scanningSources = false
    @Published private(set) var folderSyncStates: [UUID: FolderSyncState] = [:]
    private var volumeObservers: [NSObjectProtocol] = []
    private var volumeTracker = VolumeRunTracker()
    @Published private(set) var mountedVolumes: [MountedBackupVolume] = []
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private let stateURL: URL
    private let passwordWriter: (String, UUID) throws -> Void

    init(
        stateDirectory: URL? = nil,
        defaults: UserDefaults = .standard,
        volumeProvider: @escaping () -> [MountedBackupVolume] = MountedBackupVolume.current,
        coldEngine: ColdStorageEngine = ColdStorageEngine(),
        passwordWriter: @escaping (String, UUID) throws -> Void = { try KeychainStore.setPassword($0, for: $1) }
    ) {
        self.volumeProvider = volumeProvider
        self.coldEngine = coldEngine
        self.passwordWriter = passwordWriter
        self.defaults = defaults
        settingsBackup = SettingsBackupController(defaults: defaults)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = stateDirectory ?? base.appendingPathComponent("BackupCron", isDirectory: true)
        stateURL = directory.appendingPathComponent("state.json")
        if stateDirectory == nil {
            migrateLegacyStateIfNeeded(from: base.appendingPathComponent("BackupFlow", isDirectory: true))
        }
        schedulerEnabled = defaults.object(forKey: "schedulerEnabled") as? Bool ?? true
        load()
        if stateDirectory == nil {
            settingsBackup.start { [weak self] in
                SettingsArchive(jobs: self?.jobs ?? [], preferences: .init(defaults: defaults, schedulerEnabled: self?.schedulerEnabled ?? false), groups: self?.groups ?? [], coldStorages: self?.coldStorages ?? [])
            }
        }
    }

    func restoreSettings(_ archive: SettingsArchive) throws {
        guard runningJobIDs.isEmpty else { throw SettingsBackupError.running }
        let validated = try SettingsArchive.decode(archive.encoded())
        let recoveryDirectory = stateURL.deletingLastPathComponent().appendingPathComponent("Settings recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        _ = try SettingsArchiveFile.write(
            SettingsArchive(jobs: jobs, preferences: .init(defaults: defaults, schedulerEnabled: schedulerEnabled), groups: groups, coldStorages: coldStorages),
            to: recoveryDirectory
        )
        let restoredJobs = SettingsArchive(jobs: validated.jobs, preferences: validated.preferences).jobs
        try writeState(jobs: restoredJobs, groups: validated.groups ?? [], coldStorages: validated.coldStorages ?? [])
        schedulerEnabled = false
        coldStorages = validated.coldStorages ?? []
        coldClaims.removeAll()
        groups = validated.groups ?? []
        jobs = restoredJobs
        let preferences = validated.preferences
        defaults.set(preferences.notifyOnSuccess, forKey: BackupNotifications.notifyOnSuccessKey)
        defaults.set(preferences.notifyOnFailure, forKey: BackupNotifications.notifyOnFailureKey)
        defaults.set(preferences.soundEnabled, forKey: BackupSoundPreferences.enabledKey)
        defaults.set(preferences.soundVolume, forKey: BackupSoundPreferences.volumeKey)
        if defaults === UserDefaults.standard {
            BackupAudioFeedback.shared.setEnabled(preferences.soundEnabled)
            BackupAudioFeedback.shared.setVolume(preferences.soundVolume)
        }
    }

    var successfulRuns: Int { history.filter { $0.status == .success }.count }
    var failedRuns: Int { history.filter { $0.status == .failure }.count }

    func trayState(for job: BackupJob) -> BackupTrayState {
        BackupTrayState.resolve(running: runningJobIDs.contains(job.id), phase: phaseByJob[job.id],
                                enabled: job.isEnabled, schedulerEnabled: schedulerEnabled || job.schedule == .manual,
                                waitsForDisk: job.schedule == .onVolumeMount && !mountedVolumes.contains { $0.id == job.destinationVolume?.id },
                                lastRun: history.first { $0.jobID == job.id }?.status, pendingCount: folderSyncStates[job.id]?.pendingCount ?? 0)
    }

    var trayState: BackupTrayState {
        let states = jobs.map { trayState(for: $0) } + coldStorages.map { coldTrayState($0) }
        return BackupTrayState.aggregate(states + (errorMessage == nil ? [] : [.error]))
    }

    @discardableResult
    func saveColdStorage(_ value: ColdStorageDestination) throws -> ColdStorageDestination {
        guard !runningJobIDs.contains(value.id) else { throw BackupEngineError.invalidConfiguration(L10n.text("job.running")) }
        var value = value
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.jobIDs.isEmpty, ColdStorageDestination.valid([value], jobs: jobs) else {
            throw BackupEngineError.invalidConfiguration(L10n.text("cold.invalid"))
        }
        var updated = coldStorages
        if let index = updated.firstIndex(where: { $0.id == value.id }) { updated[index] = value }
        else { updated.append(value) }
        try writeState(jobs: jobs, coldStorages: updated)
        coldStorages = updated
        coldClaims.removeValue(forKey: value.id)
        if schedulerTimer != nil { runConnectedVolumeJobs() }
        return value
    }

    func deleteColdStorage(_ id: UUID) throws {
        guard !runningJobIDs.contains(id) else { throw BackupEngineError.invalidConfiguration(L10n.text("job.running")) }
        let updated = coldStorages.filter { $0.id != id }
        try writeState(jobs: jobs, coldStorages: updated)
        coldStorages = updated
        coldClaims.removeValue(forKey: id)
    }

    func coldStatus(_ item: ColdStorageDestination) -> String {
        if runningJobIDs.contains(item.id) { return currentMessageByJob[item.id] ?? L10n.text("sync.copying") }
        if !item.isEnabled || !schedulerEnabled { return L10n.text("job.paused") }
        if item.volume.destination(in: mountedVolumes) == nil { return L10n.text("disk.waiting") }
        if coldVolumeBusy(item) || item.jobIDs.contains(where: { runningJobIDs.contains($0) }) { return L10n.text("cold.waiting_backups") }
        if let last = history.first(where: { $0.jobID == item.id }), coldClaims[item.id] == ColdStoragePlan.signature(item, history: history) {
            return last.status == .success ? L10n.text("cold.ready") : last.message
        }
        return L10n.text("cold.waiting_backups")
    }

    func coldTrayState(_ item: ColdStorageDestination) -> BackupTrayState {
        if !runningJobIDs.contains(item.id), coldVolumeBusy(item) || item.jobIDs.contains(where: { runningJobIDs.contains($0) }) { return .waitingForSource }
        return BackupTrayState.resolve(running: runningJobIDs.contains(item.id), phase: phaseByJob[item.id],
            enabled: item.isEnabled, schedulerEnabled: schedulerEnabled,
            waitsForDisk: item.volume.destination(in: mountedVolumes) == nil,
            lastRun: history.first { $0.jobID == item.id }?.status)
    }

    private func coldVolumeBusy(_ item: ColdStorageDestination) -> Bool {
        if coldStorages.contains(where: { $0.id != item.id && $0.volume.id == item.volume.id && runningJobIDs.contains($0.id) }) { return true }
        let mount = mountedVolumes.first { $0.id == item.volume.id }?.url.standardizedFileURL.resolvingSymlinksInPath()
        return jobs.contains { job in
            guard runningJobIDs.contains(job.id) else { return false }
            if job.destinationVolume?.id == item.volume.id { return true }
            guard let mount else { return false }
            return URL(fileURLWithPath: job.destinationPath).standardizedFileURL.resolvingSymlinksInPath().pathComponents.starts(with: mount.pathComponents)
        }
    }

    func cancelColdStorage(_ id: UUID) { runningTasks[id]?.cancel() }

    func runColdStorage(_ id: UUID) {
        guard let item = coldStorages.first(where: { $0.id == id }), !runningJobIDs.contains(id),
              !item.jobIDs.contains(where: { runningJobIDs.contains($0) }) else { return }
        coldClaims[id] = ColdStoragePlan.signature(item, history: history)
        runningJobIDs.insert(id)
        progressByJob[id] = 0
        let began = Date()
        startedAtByJob[id] = began
        let selectedJobs = jobs
        let selectedHistory = history
        runningTasks[id] = Task {
            var result: BackupResult?
            let status: BackupStatus
            let message: String
            do {
                result = try await coldEngine.copy(item, jobs: selectedJobs, history: selectedHistory) { event in
                    await self.record(event, for: id)
                }
                status = .success
                message = L10n.text("cold.ready")
            } catch {
                status = error is CancellationError ? .cancelled : .failure
                message = error is CancellationError ? L10n.text("status.cancelled") : error.localizedDescription
            }
            let run = BackupRun(jobID: id, jobName: item.name, startedAt: began, finishedAt: Date(), status: status,
                outputPath: result?.outputURL.path, outputSizeBytes: result?.sizeBytes, message: message, logs: liveLogsByJob[id])
            history.insert(run, at: 0)
            trimHistory()
            runningJobIDs.remove(id)
            runningTasks.removeValue(forKey: id)
            progressByJob.removeValue(forKey: id)
            startedAtByJob.removeValue(forKey: id)
            phaseByJob.removeValue(forKey: id)
            currentMessageByJob.removeValue(forKey: id)
            liveLogsByJob.removeValue(forKey: id)
            persist()
            let handled = BackupAudioFeedback.shared.handleResult(status)
            BackupNotifications.post(run, suppressSound: handled)
        }
    }

    private func checkColdStorages() {
        for item in coldStorages {
            guard item.volume.destination(in: mountedVolumes) != nil else {
                coldClaims.removeValue(forKey: item.id)
                cancelColdStorage(item.id)
                continue
            }
            guard schedulerEnabled, item.isEnabled, !item.jobIDs.isEmpty,
                  !item.jobIDs.contains(where: { runningJobIDs.contains($0) }), !runningJobIDs.contains(item.id),
                  coldClaims[item.id] != ColdStoragePlan.signature(item, history: history) else { continue }
            runColdStorage(item.id)
        }
    }

    func startScheduler() {
        guard schedulerTimer == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification, NSWorkspace.didWakeNotification] {
            volumeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let unmountedURL = notification.name == NSWorkspace.didUnmountNotification
                    ? notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL : nil
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let unmountedURL {
                        for volume in self.mountedVolumes where volume.url.standardizedFileURL == unmountedURL.standardizedFileURL {
                            for item in self.coldStorages where item.volume.id == volume.id {
                                self.coldClaims.removeValue(forKey: item.id)
                                self.cancelColdStorage(item.id)
                            }
                            self.volumeTracker.disconnected(volumeID: volume.id)
                            for job in self.jobs where job.destinationVolume?.id == volume.id {
                                self.cancel(job)
                            }
                        }
                    }
                    self.runConnectedVolumeJobs()
                }
            })
        }
        schedulerTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.runDueJobs()
            }
        }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runConnectedVolumeJobs() }
        }
        runDueJobs()
    }

    deinit {
        schedulerTimer?.invalidate()
        syncTimer?.invalidate()
        for observer in volumeObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    func addOrUpdate(_ job: BackupJob, password: String? = nil) throws {
        guard job.groupID == nil || groups.contains(where: { $0.id == job.groupID }) else { throw BackupGroupError.missing }
        let previous = jobs.first { $0.id == job.id }
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
        prepareSyncState(for: job)
        if previous?.destinationVolume != job.destinationVolume || previous?.schedule != job.schedule
            || previous?.isEnabled != job.isEnabled {
            volumeTracker.forget(jobID: job.id)
        }
        if schedulerTimer != nil { runConnectedVolumeJobs() }
    }

    @discardableResult
    func saveGroup(name: String, id: UUID? = nil, jobIDs: Set<UUID>) throws -> BackupGroup {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw BackupGroupError.invalidName }
        guard !groups.contains(where: { $0.id != id && $0.name.lowercased() == name.lowercased() }) else { throw BackupGroupError.duplicateName }
        guard id == nil || groups.contains(where: { $0.id == id }) else { throw BackupGroupError.missing }
        let group = BackupGroup(id: id ?? UUID(), name: name)
        var updatedGroups = groups
        if let index = updatedGroups.firstIndex(where: { $0.id == group.id }) { updatedGroups[index] = group }
        else { updatedGroups.append(group) }
        var updatedJobs = jobs
        for index in updatedJobs.indices {
            if jobIDs.contains(updatedJobs[index].id) { updatedJobs[index].groupID = group.id }
            else if updatedJobs[index].groupID == group.id { updatedJobs[index].groupID = nil }
        }
        try writeState(jobs: updatedJobs, groups: updatedGroups)
        groups = updatedGroups
        jobs = updatedJobs
        return group
    }

    func deleteGroup(_ id: UUID) throws {
        let updatedGroups = groups.filter { $0.id != id }
        var updatedJobs = jobs
        for index in updatedJobs.indices where updatedJobs[index].groupID == id { updatedJobs[index].groupID = nil }
        try writeState(jobs: updatedJobs, groups: updatedGroups)
        groups = updatedGroups
        jobs = updatedJobs
    }

    func runnableJobs(in groupID: UUID) -> [BackupJob] {
        jobs.filter { $0.groupID == groupID && $0.isEnabled && !runningJobIDs.contains($0.id) }
    }

    func runGroup(_ groupID: UUID) {
        for job in runnableJobs(in: groupID) { run(job) }
    }

    @discardableResult
    func delete(_ job: BackupJob) -> Bool {
        let updatedCold = coldStorages.map { item in var copy = item; copy.jobIDs.removeAll { $0 == job.id }; return copy }
        let updatedJobs = jobs.filter { $0.id != job.id }
        do {
            try writeState(jobs: updatedJobs, coldStorages: updatedCold)
        } catch {
            errorMessage = SaveError(reason: error, passwordChanged: false).localizedDescription
            return false
        }
        cancel(job)
        coldStorages = updatedCold
        jobs = updatedJobs
        folderSyncStates.removeValue(forKey: job.id)
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

    func run(_ job: BackupJob, automatic: Bool = false, verifyAll: Bool = true) {
        guard !runningJobIDs.contains(job.id) else { return }
        prepareSyncState(for: job)
        folderSyncStates[job.id]?.begin()
        runningJobIDs.insert(job.id)
        progressByJob[job.id] = 0
        liveLogsByJob[job.id] = []
        appendLog(L10n.text("log.started", job.name), for: job.id)
        let startedAt = Date()
        startedAtByJob[job.id] = startedAt

        let verifiedFiles = verifyAll ? [:] : (folderSyncStates[job.id]?.checkpoint.files ?? [:])
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
                let result = try await engine.run(job: job, password: password, verifiedSyncFiles: verifiedFiles) { event in
                    await progressStore.record(event, for: job.id)
                }
                finish(
                    job: job,
                    startedAt: startedAt,
                    status: .success,
                    outputPath: result.outputURL.path,
                    outputSizeBytes: result.sizeBytes,
                    message: result.message, automatic: automatic
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
                    message: wasCancelled ? L10n.text("status.cancelled") : error.localizedDescription, automatic: automatic
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
        phaseByJob[jobID] = event.phase
        if let file = event.syncedFile { folderSyncStates[jobID]?.acknowledge(path: file.path, stamp: file.stamp) }
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
        runConnectedVolumeJobs()
        guard schedulerEnabled else { return }
        for job in jobs where job.isDue(at: Date()) && !runningJobIDs.contains(job.id) {
            run(job, automatic: true)
        }
    }

    func runConnectedVolumeJobs() {
        let currentVolumes = volumeProvider()
        let connectedIDs = Set(currentVolumes.map(\.id))
        for volume in mountedVolumes where !connectedIDs.contains(volume.id) {
            for job in jobs where job.destinationVolume?.id == volume.id { cancel(job) }
        }
        mountedVolumes = currentVolumes
        for job in volumeTracker.jobsToRun(jobs, volumes: currentVolumes,
                                          schedulerEnabled: schedulerEnabled, running: runningJobIDs) {
            prepareSyncState(for: job)
            folderSyncStates[job.id]?.reconnect()
            run(job, automatic: true)
        }
        checkColdStorages()
        Task { await checkFolderSyncSources() }
    }

    private func prepareSyncState(for job: BackupJob) {
        guard job.isFolderSync && job.schedule == .onVolumeMount else {
            folderSyncStates.removeValue(forKey: job.id)
            return
        }
        let configuration = FolderSyncCheckpoint.configuration(for: job)
        if folderSyncStates[job.id]?.checkpoint.configuration != configuration {
            folderSyncStates[job.id] = .init(job: job)
        }
    }

    func checkFolderSyncSources() async {
        guard !scanningSources else { return }
        scanningSources = true
        defer { scanningSources = false }
        for job in jobs where job.isFolderSync && job.schedule == .onVolumeMount {
            prepareSyncState(for: job)
            let result = await Task.detached(priority: .utility) {
                Result { try BackupEngine().syncSourceSnapshot(job: job) }
            }.value
            guard let current = jobs.first(where: { $0.id == job.id }),
                  current.isFolderSync, current.schedule == .onVolumeMount,
                  FolderSyncCheckpoint.configuration(for: current) == FolderSyncCheckpoint.configuration(for: job) else { continue }
            switch result {
            case .success(let files): folderSyncStates[job.id]?.observe(files)
            case .failure(let error):
                folderSyncStates[job.id]?.scanError = error.localizedDescription
                folderSyncStates[job.id]?.observed = nil
                folderSyncStates[job.id]?.retryNeeded = true
            }
            if schedulerEnabled, current.isEnabled, !runningJobIDs.contains(job.id),
               current.destinationVolume?.destination(in: mountedVolumes) != nil,
               folderSyncStates[job.id]?.shouldRun(at: Date()) == true {
                run(current, automatic: true, verifyAll: false)
            }
        }
    }

    func syncPendingText(for job: BackupJob) -> String {
        folderSyncStates[job.id]?.pendingCount.map { L10n.text("sync.pending_count", $0) } ?? "—"
    }

    private func finish(
        job: BackupJob,
        startedAt: Date,
        status: BackupStatus,
        outputPath: String?,
        outputSizeBytes: Int64?,
        message: String,
        automatic: Bool
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
        let firstFailure = folderSyncStates[job.id]?.finish(status, at: run.finishedAt) ?? false
        let quiet = automatic && job.isFolderSync && job.schedule == .onVolumeMount
            && (status != .failure || !firstFailure)
        if !quiet {
            let handledInForeground = BackupAudioFeedback.shared.handleResult(status)
            BackupNotifications.post(run, suppressSound: handledInForeground)
        }
        if status == .success {
            applyRetention(for: job)
        }
        trimHistory()
        progressByJob.removeValue(forKey: job.id)
        liveLogsByJob.removeValue(forKey: job.id)
        currentMessageByJob.removeValue(forKey: job.id)
        phaseByJob.removeValue(forKey: job.id)
        runningTasks.removeValue(forKey: job.id)
        persist()
    }

    private func applyRetention(for job: BackupJob) {
        guard !job.isFolderSync, job.retentionCount > 0,
              !coldStorages.contains(where: { $0.jobIDs.contains(job.id) && runningJobIDs.contains($0.id) }) else { return }

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
        coldStorages = (state.coldStorages ?? []).map { item in
            var copy = item; copy.jobIDs = item.jobIDs.filter { id in state.jobs.contains { $0.id == id } }; return copy
        }
        groups = state.groups ?? []
        jobs = state.jobs
        for index in jobs.indices where !groups.contains(where: { $0.id == jobs[index].groupID }) { jobs[index].groupID = nil }
        history = state.history
        for job in jobs where job.isFolderSync && job.schedule == .onVolumeMount {
            folderSyncStates[job.id] = .init(job: job, checkpoint: state.syncCheckpoints?[job.id])
        }
    }

    private func trimHistory() {
        let coldIDs = Set(coldStorages.map(\.id))
        let backups = history.filter { !coldIDs.contains($0.jobID) }.prefix(200)
        let transfers = history.filter { coldIDs.contains($0.jobID) }.prefix(50)
        history = (Array(backups) + Array(transfers)).sorted { $0.finishedAt > $1.finishedAt }
    }

    private func persist() {
        do {
            try writeState(jobs: jobs)
        } catch {
            errorMessage = SaveError(reason: error, passwordChanged: false).localizedDescription
        }
    }

    private func writeState(jobs: [BackupJob], groups: [BackupGroup]? = nil, coldStorages: [ColdStorageDestination]? = nil) throws {
        let directory = stateURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(PersistedState(coldStorages: coldStorages ?? self.coldStorages, groups: groups ?? self.groups, jobs: jobs, history: history, syncCheckpoints: folderSyncStates.filter { id, value in jobs.contains { $0.id == id && $0.isFolderSync && $0.schedule == .onVolumeMount && FolderSyncCheckpoint.configuration(for: $0) == value.checkpoint.configuration } }.mapValues(\.checkpoint)))
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
