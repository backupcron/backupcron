import AppKit
import Foundation
import Testing
@testable import BackupFlow

struct VolumeSyncTests {
    @Test func trayAnimationOnlyCelebratesNewSuccessAndStopsAfterwards() {
        var animation = BackupTrayAnimation()
        animation.update(state: .ready, at: 0)
        #expect(animation.mode == .idle)
        animation.update(state: .copying, at: 1)
        animation.update(state: .copying, at: 1.3)
        #expect(abs(animation.progress(at: 1.3) - 0.25) < 0.0001)
        animation.completed(.success)
        animation.update(state: .copying, at: 2)
        #expect(animation.mode == .copying)
        animation.update(state: .waitingForSource, at: 2.1)
        #expect(animation.mode == .idle)
        animation.update(state: .ready, at: 3)
        #expect(animation.mode == .success)
        animation.update(state: .ready, at: 4.39)
        #expect(animation.mode == .success)
        animation.update(state: .ready, at: 4.41)
        #expect(animation.mode == .idle)
        animation.update(state: .ready, at: 10)
        #expect(animation.mode == .idle)
        for result in [BackupStatus.failure, .cancelled] {
            animation.completed(.success)
            animation.update(state: .ready, at: 11)
            animation.completed(result)
            animation.update(state: .ready, at: 11.1)
            #expect(animation.mode == .idle)
        }
        animation.completed(.success)
        animation.update(state: .error, at: 12)
        animation.update(state: .ready, at: 13)
        #expect(animation.mode == .idle)
    }

    @Test @MainActor func trayAnimationFramesRenderDistinctImages() throws {
        func pixels(_ image: NSImage) throws -> Data {
            try #require(image.tiffRepresentation)
        }
        let first = BackupTrayIconRenderer.rotation(progress: 0)
        let later = BackupTrayIconRenderer.rotation(progress: 0.125)
        #expect(first.isTemplate && later.isTemplate)
        #expect(try pixels(first) != pixels(later))
        #expect(try pixels(BackupTrayIconRenderer.success(progress: 0.05)) != pixels(BackupTrayIconRenderer.success(progress: 0.6)))
    }

    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("backupcron-sync-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func syncJob(in root: URL) throws -> BackupJob {
        var job = BackupJob()
        job.sourcePath = root.appendingPathComponent("source").path
        job.destinationPath = root.appendingPathComponent("destination").path
        job.synchronizeFolder = true
        try FileManager.default.createDirectory(atPath: job.sourcePath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: job.destinationPath, withIntermediateDirectories: true)
        return job
    }

    private func volumeJob(id: String = "volume-a") -> BackupJob {
        var job = BackupJob()
        job.schedule = .onVolumeMount
        job.sourcePath = "/local/backups"
        job.destinationPath = "/Volumes/Archive/Backups"
        job.destinationVolume = .init(id: id, name: "Archive", relativePath: "Backups", configuredPath: job.destinationPath)
        return job
    }

    @Test func settingsRoundTripAndLegacyJobsStayUnchanged() throws {
        let legacy = try JSONDecoder().decode(BackupJob.self, from: Data("{}".utf8))
        #expect(!legacy.synchronizeFolder)
        #expect(legacy.destinationVolume == nil)
        #expect(legacy.schedule == .manual)
        var job = volumeJob()
        job.synchronizeFolder = true
        let archive = SettingsArchive(jobs: [job], preferences: .init(defaults: .standard, schedulerEnabled: true))
        let restored = try SettingsArchive.decode(archive.encoded()).jobs[0]
        #expect(restored.synchronizeFolder)
        #expect(restored.destinationVolume == job.destinationVolume)
        #expect(restored.schedule == .onVolumeMount)
        #expect(restored.nextRunAt == nil)
        #expect(!restored.isDue(at: Date().addingTimeInterval(1_000_000)))
        #expect(BackupScheduleState(job: restored, schedulerEnabled: true, isRunning: false) == .waitingForDisk)
        #expect(BackupScheduleState(job: restored, schedulerEnabled: false, isRunning: false) == .paused)
    }

    @Test func matchesDiskIdentityAfterRenameAndRejectsAmbiguityAndTraversal() throws {
        let job = volumeJob()
        var binding = try #require(job.destinationVolume)
        let renamed = MountedBackupVolume(id: binding.id, url: URL(fileURLWithPath: "/Volumes/Renamed"))
        #expect(binding.destination(in: [renamed])?.path == "/Volumes/Renamed/Backups")
        #expect(binding.destination(in: [.init(id: "different-disk", url: URL(fileURLWithPath: "/Volumes/Archive"))]) == nil)
        #expect(binding.destination(in: [renamed, renamed]) == nil)
        #expect(!binding.matches(path: "/Volumes/Archive/Other"))
        binding.relativePath = "../escape"
        #expect(binding.destination(in: [renamed]) == nil)
        #expect(BackupVolumeBinding.capture(for: FileManager.default.temporaryDirectory) == nil)
        let missingPath = "/private/tmp/backupcron-disconnected-volume/Backups"
        let offline = BackupVolumeBinding(id: "offline", name: "Offline", relativePath: "Backups", configuredPath: missingPath)
        #expect(offline.matches(path: missingPath))
    }

    @Test func runsOncePerConnectionAndSeparatelyForEachDiskAndJob() {
        let first = volumeJob()
        let second = volumeJob(id: "volume-b")
        var otherJobOnFirst = first
        otherJobOnFirst.id = UUID()
        let a = MountedBackupVolume(id: "volume-a", url: URL(fileURLWithPath: "/Volumes/A"))
        let b = MountedBackupVolume(id: "volume-b", url: URL(fileURLWithPath: "/Volumes/B"))
        let jobs = [first, second, otherJobOnFirst]
        var tracker = VolumeRunTracker()
        #expect(tracker.jobsToRun(jobs, volumes: [], schedulerEnabled: true, running: []).isEmpty)
        #expect(tracker.jobsToRun(jobs, volumes: [a], schedulerEnabled: true, running: []).map(\.id) == [first.id, otherJobOnFirst.id])
        #expect(tracker.jobsToRun(jobs, volumes: [a], schedulerEnabled: true, running: []).isEmpty)
        #expect(tracker.jobsToRun(jobs, volumes: [a, b], schedulerEnabled: true, running: []).map(\.id) == [second.id])
        _ = tracker.jobsToRun(jobs, volumes: [b], schedulerEnabled: true, running: [])
        #expect(tracker.jobsToRun(jobs, volumes: [a, b], schedulerEnabled: true, running: []).map(\.id) == [first.id, otherJobOnFirst.id])
    }

    @Test func pausedDisabledRunningAndEditedJobsRespectConnectionState() {
        var job = volumeJob()
        let volume = MountedBackupVolume(id: "volume-a", url: URL(fileURLWithPath: "/Volumes/A"))
        var tracker = VolumeRunTracker()
        #expect(tracker.jobsToRun([job], volumes: [volume], schedulerEnabled: false, running: []).isEmpty)
        job.isEnabled = false
        #expect(tracker.jobsToRun([job], volumes: [volume], schedulerEnabled: true, running: []).isEmpty)
        job.isEnabled = true
        #expect(tracker.jobsToRun([job], volumes: [volume], schedulerEnabled: true, running: [job.id]).isEmpty)
        #expect(tracker.jobsToRun([job], volumes: [volume], schedulerEnabled: true, running: []).count == 1)
        tracker.disconnected(volumeID: volume.id)
        #expect(tracker.jobsToRun([job], volumes: [volume], schedulerEnabled: true, running: [job.id]).isEmpty)
        #expect(tracker.jobsToRun([job], volumes: [volume], schedulerEnabled: true, running: []).count == 1)
        tracker.forget(jobID: job.id)
        job.destinationPath = "/Volumes/A/Unbound"
        #expect(tracker.jobsToRun([job], volumes: [volume], schedulerEnabled: true, running: []).isEmpty)
        #expect(JobSetupStep.schedule.validationKey(for: job) == "disk.choose_external")
    }

    @Test func synchronizationAccumulatesBackupsAndUpdatesSameSizeSameDateFiles() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var job = try syncJob(in: root)
        job.nameMask = ""
        let source = URL(fileURLWithPath: job.sourcePath)
        let destination = URL(fileURLWithPath: job.destinationPath)
        let sourceFile = source.appendingPathComponent("backup with spaces 雪.zip")
        let destinationFile = destination.appendingPathComponent(sourceFile.lastPathComponent)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try Data("AAAA".utf8).write(to: sourceFile)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: sourceFile.path)
        let engine = BackupEngine()
        let first = try await engine.run(job: job, password: "")
        #expect(first.outputURL == destination)
        #expect(try Data(contentsOf: destinationFile) == Data("AAAA".utf8))
        let inode = try FileManager.default.attributesOfItem(atPath: destinationFile.path)[.systemFileNumber] as? NSNumber
        _ = try await engine.run(job: job, password: "")
        #expect(try FileManager.default.attributesOfItem(atPath: destinationFile.path)[.systemFileNumber] as? NSNumber == inode)
        try Data("BBBB".utf8).write(to: sourceFile)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: sourceFile.path)
        let nested = source.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("new backup".utf8).write(to: nested.appendingPathComponent("new.sql"))
        _ = try await engine.run(job: job, password: "")
        #expect(try Data(contentsOf: destinationFile) == Data("BBBB".utf8))
        #expect(try Data(contentsOf: sourceFile) == Data("BBBB".utf8))
        #expect(try Data(contentsOf: destination.appendingPathComponent("nested/new.sql")) == Data("new backup".utf8))
        try FileManager.default.removeItem(at: sourceFile)
        _ = try await engine.run(job: job, password: "")
        #expect(try Data(contentsOf: destinationFile) == Data("BBBB".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted() == [sourceFile.lastPathComponent, "nested"].sorted())
    }

    @Test func disconnectedDiskNeverCreatesAFallbackDestination() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var job = try syncJob(in: root)
        job.schedule = .onVolumeMount
        job.destinationPath = root.appendingPathComponent("absent-disk/Backups").path
        job.destinationVolume = .init(id: UUID().uuidString, name: "Absent disk", relativePath: "Backups", configuredPath: job.destinationPath)
        await #expect(throws: BackupEngineError.self) { try await BackupEngine().run(job: job, password: "") }
        #expect(!FileManager.default.fileExists(atPath: job.destinationPath))
    }

    @Test func synchronizationRejectsOverlappingFoldersAndFileSources() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var job = try syncJob(in: root)
        job.destinationPath = job.sourcePath + "/child"
        await #expect(throws: BackupEngineError.self) { try await BackupEngine().run(job: job, password: "") }
        job.destinationPath = root.path
        await #expect(throws: BackupEngineError.self) { try await BackupEngine().run(job: job, password: "") }
        job.destinationPath = job.sourcePath
        await #expect(throws: BackupEngineError.self) { try await BackupEngine().run(job: job, password: "") }
        let file = root.appendingPathComponent("file.zip")
        try Data("backup".utf8).write(to: file)
        job.sourcePath = file.path
        await #expect(throws: BackupEngineError.self) { try await BackupEngine().run(job: job, password: "") }
    }

    @Test func failurePreservesExistingDestinationAndSource() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let job = try syncJob(in: root)
        let sourceFile = URL(fileURLWithPath: job.sourcePath).appendingPathComponent("conflict")
        let folder = URL(fileURLWithPath: job.destinationPath).appendingPathComponent("conflict")
        try Data("new".utf8).write(to: sourceFile)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let oldFile = folder.appendingPathComponent("old-backup.zip")
        try Data("saved".utf8).write(to: oldFile)
        await #expect(throws: BackupEngineError.self) { try await BackupEngine().run(job: job, password: "") }
        #expect(try Data(contentsOf: oldFile) == Data("saved".utf8))
        #expect(try Data(contentsOf: sourceFile) == Data("new".utf8))
    }

    @Test func cancellationPreservesDestination() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let job = try syncJob(in: root)
        let saved = URL(fileURLWithPath: job.destinationPath).appendingPathComponent("saved.zip")
        try Data("existing".utf8).write(to: saved)
        let task = Task {
            try await BackupEngine().run(job: job, password: "") { event in
                if event.fraction == 0.12 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: saved) == Data("existing".utf8))
    }

    @Test func allNewInterfaceStringsAreLocalized() {
        let keys = ["disk.on_connect", "disk.waiting", "disk.choose_external", "disk.unavailable", "disk.trigger",
                    "disk.connected", "disk.disconnected", "disk.choose_folder", "disk.device", "sync.operation",
                    "sync.backup_mode", "sync.mode", "sync.keep_files", "sync.copying", "sync.completed",
                    "sync.choose_source_folder", "sync.overlapping_paths", "tray.copying", "tray.waiting_source",
                    "sync.waiting_source", "sync.source_not_ready", "sync.verification_failed", "sync.path_conflict", "sync.pending", "sync.pending_count"]
        for language in L10n.supportedLanguages {
            for key in keys { #expect(L10n.text(key, language: language) != key) }
        }
    }
}

extension VolumeSyncTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BACKUPCRON_TEST_VOLUME_PATH"] != nil))
    @MainActor func mountedVolumeStartsAutomaticallyOnlyOnce() async throws {
        let volumePath = try #require(ProcessInfo.processInfo.environment["BACKUPCRON_TEST_VOLUME_PATH"])
        let root = try fixture()
        let destination = URL(fileURLWithPath: volumePath).appendingPathComponent("sync-fixture-\(UUID())")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        var job = try syncJob(in: root)
        job.destinationPath = destination.path
        job.destinationBookmark = SecurityScopedBookmark.create(for: destination)
        let binding = try #require(BackupVolumeBinding.capture(for: destination))
        job.destinationVolume = binding
        job.schedule = .onVolumeMount
        #expect(try job.destinationVolume?.connectedDestination().standardizedFileURL.path == destination.standardizedFileURL.path)
        try Data("new".utf8).write(to: URL(fileURLWithPath: job.sourcePath).appendingPathComponent("backup.sql"))
        let suite = "backupcron-volume-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BackupStore(stateDirectory: root.appendingPathComponent("state"), defaults: defaults, passwordWriter: { _, _ in })
        try store.addOrUpdate(job)
        store.startScheduler()
        for _ in 0..<1000 where !store.runningJobIDs.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.history.count == 1)
        #expect(store.history.first?.status == .success)
        #expect(try Data(contentsOf: destination.appendingPathComponent("backup.sql")) == Data("new".utf8))
        store.startScheduler()
        #expect(store.runningJobIDs.isEmpty)
        #expect(store.history.count == 1)
        await store.checkFolderSyncSources()
        #expect(store.folderSyncStates[job.id]?.pendingCount == 0)
        try Data("later".utf8).write(to: URL(fileURLWithPath: job.sourcePath).appendingPathComponent("later.sql"))
        await store.checkFolderSyncSources()
        for _ in 0..<1000 where !store.runningJobIDs.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.history.count == 2)
        #expect(try Data(contentsOf: destination.appendingPathComponent("later.sql")) == Data("later".utf8))
        await store.checkFolderSyncSources()
        #expect(store.folderSyncStates[job.id]?.pendingCount == 0)
        #expect(store.runningJobIDs.isEmpty)
        let restored = BackupStore(stateDirectory: root.appendingPathComponent("state"), defaults: defaults, passwordWriter: { _, _ in })
        await restored.checkFolderSyncSources()
        #expect(restored.folderSyncStates[job.id]?.pendingCount == 0)
        #expect(restored.folderSyncStates[job.id]?.checkpoint.lastSuccess != nil)
    }

    @Test @MainActor func synchronizationDoesNotApplyPreviousBackupRetention() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var job = try syncJob(in: root)
        job.synchronizeFolder = false
        job.archiveOutput = false
        job.retentionCount = 1
        try Data("saved".utf8).write(to: URL(fileURLWithPath: job.sourcePath).appendingPathComponent("backup.sql"))
        let suite = "backupcron-retention-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BackupStore(stateDirectory: root.appendingPathComponent("state"), defaults: defaults, passwordWriter: { _, _ in })
        try store.addOrUpdate(job)
        store.run(job)
        for _ in 0..<1000 where !store.runningJobIDs.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.history.first?.status == .success)
        let previous = try #require(store.history.first?.outputPath)
        job.synchronizeFolder = true
        try store.addOrUpdate(job)
        store.run(job)
        for _ in 0..<1000 where !store.runningJobIDs.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.history.first?.status == .success)
        #expect(FileManager.default.fileExists(atPath: previous))
        #expect(try Data(contentsOf: URL(fileURLWithPath: job.destinationPath).appendingPathComponent("backup.sql")) == Data("saved".utf8))
    }
}

private actor SyncTestCounter {
    private(set) var value = 0
    func next() -> Int { value += 1; return value }
}

extension VolumeSyncTests {
    private var fastSyncEngine: BackupEngine {
        BackupEngine(syncPolicy: .init(quietPeriod: .zero, retryDelays: [.milliseconds(1), .milliseconds(1)]))
    }

    @Test func changingSourcePreservesOldCopyUntilRetrySucceeds() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let job = try syncJob(in: root)
        let source = URL(fileURLWithPath: job.sourcePath).appendingPathComponent("backup.sql")
        let target = URL(fileURLWithPath: job.destinationPath).appendingPathComponent("backup.sql")
        try Data("first".utf8).write(to: source)
        try Data("saved".utf8).write(to: target)
        let timestamp = try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as! Date
        let verification = SyncTestCounter(), waiting = SyncTestCounter()
        _ = try await fastSyncEngine.run(job: job, password: "") { event in
            if event.phase == .verifying, await verification.next() == 1 {
                try! Data("final".utf8).write(to: source)
                try! FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: source.path)
            }
            if event.phase == .waitingForSource {
                _ = await waiting.next()
                #expect(try! Data(contentsOf: target) == Data("saved".utf8))
            }
        }
        #expect(await waiting.value == 1)
        #expect(try Data(contentsOf: target) == Data("final".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: job.destinationPath) == ["backup.sql"])
    }

    @Test func retriesAreBoundedAndNeverPublishAnUnstableSource() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let job = try syncJob(in: root)
        let source = URL(fileURLWithPath: job.sourcePath).appendingPathComponent("backup.sql")
        let target = URL(fileURLWithPath: job.destinationPath).appendingPathComponent("backup.sql")
        try Data("new".utf8).write(to: source); try Data("saved".utf8).write(to: target)
        let attempts = SyncTestCounter()
        await #expect(throws: BackupEngineError.self) {
            try await fastSyncEngine.run(job: job, password: "") { event in
                if event.phase == .verifying {
                    let number = await attempts.next()
                    try! Data("change-\(number)".utf8).write(to: source)
                }
            }
        }
        #expect(await attempts.value == 3)
        #expect(try Data(contentsOf: target) == Data("saved".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: job.destinationPath) == ["backup.sql"])
    }

    @Test func readyFilesCopyWhileTemporaryFilesWaitForRename() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let job = try syncJob(in: root)
        let source = URL(fileURLWithPath: job.sourcePath)
        let destination = URL(fileURLWithPath: job.destinationPath)
        try Data("pending".utf8).write(to: source.appendingPathComponent("backup.sql.part"))
        try Data("ready".utf8).write(to: source.appendingPathComponent("ready.sql"))
        _ = try await fastSyncEngine.run(job: job, password: "") { event in
            if event.phase == .waitingForSource {
                #expect(try! Data(contentsOf: destination.appendingPathComponent("ready.sql")) == Data("ready".utf8))
                #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("backup.sql.part").path))
                try! FileManager.default.moveItem(at: source.appendingPathComponent("backup.sql.part"), to: source.appendingPathComponent("backup.sql"))
            }
        }
        #expect(try Data(contentsOf: destination.appendingPathComponent("backup.sql")) == Data("pending".utf8))
    }

    @Test func cancellationWhileWaitingDoesNotPublishOrRetry() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let job = try syncJob(in: root)
        try Data("pending".utf8).write(to: URL(fileURLWithPath: job.sourcePath).appendingPathComponent("backup.tmp"))
        let task = Task {
            try await fastSyncEngine.run(job: job, password: "") { event in
                if event.phase == .waitingForSource { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: job.destinationPath).isEmpty)
    }

    @Test func destinationLinksNeverReplaceExternalFiles() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let job = try syncJob(in: root)
        let target = URL(fileURLWithPath: job.destinationPath).appendingPathComponent("backup.sql")
        let other = root.appendingPathComponent("other.sql")
        try Data("saved".utf8).write(to: other)
        try Data("new".utf8).write(to: URL(fileURLWithPath: job.sourcePath).appendingPathComponent("backup.sql"))
        await #expect(throws: BackupEngineError.self) {
            try await fastSyncEngine.run(job: job, password: "") { event in
                if event.phase == .verifying { try! FileManager.default.createSymbolicLink(at: target, withDestinationURL: other) }
            }
        }
        #expect(try Data(contentsOf: other) == Data("saved".utf8))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path) == other.path)
    }

    @Test func trayNeverShowsSuccessForUnrunCancelledOrMissingDisk() {
        func state(_ running: Bool = false, _ phase: BackupProgressPhase? = nil, _ enabled: Bool = true,
                   _ scheduler: Bool = true, _ missing: Bool = false, _ last: BackupStatus? = nil) -> BackupTrayState {
            BackupTrayState.resolve(running: running, phase: phase, enabled: enabled, schedulerEnabled: scheduler, waitsForDisk: missing, lastRun: last)
        }
        #expect(state() == .notRun)
        #expect(state(false, nil, true, true, false, .success) == .ready)
        #expect(state(false, nil, true, true, false, .cancelled) == .cancelled)
        #expect(state(false, nil, true, true, false, .failure) == .error)
        #expect(state(false, nil, true, true, true, .success) == .waitingForDisk)
        #expect(state(false, nil, true, false, true, .success) == .paused)
        #expect(state(true, .waitingForSource, false, false) == .waitingForSource)
        #expect(BackupTrayState.aggregate([.ready, .error, .copying]) == .copying)
        #expect(BackupTrayState.aggregate([]) == .notRun)
    }
}

extension VolumeSyncTests {
    @Test func continuousQueueTracksReceiptsWithoutLosingArrivalsDuringCopy() throws {
        var job = volumeJob(); job.synchronizeFolder = true
        var state = FolderSyncState(job: job)
        let now = Date()
        state.observe(["first.sql": "first", "pending.part": "writing", "empty": "directory"])
        #expect(state.pendingCount == 2)
        state.acknowledge(path: "first.sql", stamp: "first")
        state.acknowledge(path: "empty", stamp: "directory")
        #expect(state.pendingCount == 1)
        state.observe(["first.sql": "first", "second.sql": "second"])
        state.finish(.success, at: now)
        #expect(state.pendingCount == 1)
        #expect(state.shouldRun(at: now))
        state.acknowledge(path: "second.sql", stamp: "second")
        state.finish(.success, at: now)
        #expect(!state.shouldRun(at: now.addingTimeInterval(100)))
        let data = try JSONEncoder().encode(state.checkpoint)
        var restored = FolderSyncState(job: job, checkpoint: try JSONDecoder().decode(FolderSyncCheckpoint.self, from: data))
        restored.observe(["first.sql": "first", "second.sql": "second", "offline.sql": "new"])
        #expect(restored.pendingCount == 1)
        #expect(restored.checkpoint.lastSuccess == now)
        job.sourcePath = "/another/source"
        #expect(FolderSyncState(job: job, checkpoint: state.checkpoint).checkpoint.files.isEmpty)
    }

    @Test func continuousRetriesBackOffDeduplicateFailuresAndRespectStop() {
        var job = volumeJob(); job.synchronizeFolder = true
        var state = FolderSyncState(job: job)
        let now = Date()
        state.observe(["backup.sql": "first"])
        let firstFailure = state.finish(.failure, at: now)
        #expect(firstFailure)
        #expect(!state.shouldRun(at: now.addingTimeInterval(299)))
        #expect(state.shouldRun(at: now.addingTimeInterval(300)))
        let repeatedFailure = state.finish(.failure, at: now.addingTimeInterval(300))
        #expect(!repeatedFailure)
        state.observe(["backup.sql": "changed"])
        #expect(state.shouldRun(at: now.addingTimeInterval(301)))
        state.finish(.cancelled, at: now)
        #expect(!state.shouldRun(at: now.addingTimeInterval(1000)))
        state.reconnect()
        #expect(state.shouldRun(at: now))
        state.finish(.success, at: now)
        let newFailure = state.finish(.failure, at: now)
        #expect(newFailure)
    }

    @Test func continuousInventoryMatchesPublishedReceiptsAndDetectsSameDateEdits() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let job = try syncJob(in: root)
        let source = URL(fileURLWithPath: job.sourcePath)
        let first = source.appendingPathComponent("first.sql")
        try Data("first".utf8).write(to: first)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("empty"), withIntermediateDirectories: false)
        let receipts = SyncReceiptCollector()
        _ = try await fastSyncEngine.run(job: job, password: "") { event in
            if let file = event.syncedFile { await receipts.add(file.path, file.stamp) }
        }
        let inventory = try fastSyncEngine.syncSourceSnapshot(job: job)
        #expect(await receipts.files == inventory)
        let timestamp = try FileManager.default.attributesOfItem(atPath: first.path)[.modificationDate] as! Date
        try Data("other".utf8).write(to: first)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: first.path)
        #expect(try fastSyncEngine.syncSourceSnapshot(job: job)["first.sql"] != inventory["first.sql"])
        try Data("second".utf8).write(to: source.appendingPathComponent("second.sql"))
        _ = try await fastSyncEngine.run(job: job, password: "", verifiedSyncFiles: inventory)
        #expect(try Data(contentsOf: URL(fileURLWithPath: job.destinationPath).appendingPathComponent("first.sql")) == Data("other".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: job.destinationPath).appendingPathComponent("second.sql")) == Data("second".utf8))
    }

    @Test func incrementalSyncDoesNotReopenAcknowledgedFiles() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let job = try syncJob(in: root)
        let source = URL(fileURLWithPath: job.sourcePath)
        try Data("first".utf8).write(to: source.appendingPathComponent("first.sql"))
        _ = try await fastSyncEngine.run(job: job, password: "")
        let inventory = try fastSyncEngine.syncSourceSnapshot(job: job)
        try Data("second".utf8).write(to: source.appendingPathComponent("second.sql"))
        let receipts = SyncReceiptCollector()
        _ = try await fastSyncEngine.run(job: job, password: "", verifiedSyncFiles: inventory) { event in
            if let file = event.syncedFile { await receipts.add(file.path, file.stamp) }
        }
        #expect(await receipts.files.keys.sorted() == ["second.sql"])
    }

    @Test func previousStateDecodesWithoutSyncCheckpoints() throws {
        let state = try JSONDecoder().decode(PersistedState.self, from: Data("{\"jobs\":[],\"history\":[]}".utf8))
        #expect(state.syncCheckpoints == nil)
    }
}

private actor SyncReceiptCollector {
    var files: [String: String] = [:]
    func add(_ path: String, _ stamp: String) { files[path] = stamp }
}
