import Foundation
import Testing
@testable import BackupFlow

private final class ColdVolumeFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var connected = true
    let root: URL
    init(_ root: URL) { self.root = root }
    func setConnected(_ value: Bool) { lock.lock(); connected = value; lock.unlock() }
    func current() -> [MountedBackupVolume] { lock.lock(); defer { lock.unlock() }; return connected ? [.init(id: "cold-fixture", url: root)] : [] }
    func resolve(_ binding: BackupVolumeBinding) throws -> URL {
        guard let value = binding.destination(in: current()) else { throw CocoaError(.fileNoSuchFile) }
        return value
    }
}

@Suite struct ColdStorageTests {
    private func stateEncoder() -> JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return encoder }
    private func fixture() throws -> (URL, BackupJob, BackupRun, ColdStorageDestination, ColdVolumeFixture) {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let local = root.appendingPathComponent("local"); let disk = root.appendingPathComponent("disk")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
        let source = local.appendingPathComponent("бекап.sql")
        try Data("completed backup".utf8).write(to: source)
        var job = BackupJob(); job.name = "База данных"; job.sourcePath = root.appendingPathComponent("original").path; job.destinationPath = local.path; job.schedule = .manual
        let run = BackupRun(jobID: job.id, jobName: job.name, startedAt: Date(), finishedAt: Date(), status: .success, outputPath: source.path, message: "done")
        let item = ColdStorageDestination(name: "Offline", volume: .init(id: "cold-fixture", name: "Disk", relativePath: "", configuredPath: disk.path), jobIDs: [job.id])
        return (root, job, run, item, ColdVolumeFixture(disk))
    }

    @Test func completedCopiesAreVerifiedSkippedAndRepairedWithoutDeletingOriginals() async throws {
        let (root, job, run, item, volume) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let engine = ColdStorageEngine(resolve: volume.resolve)
        let result = try await engine.copy(item, jobs: [job], history: [run], onProgress: { _ in })
        let target = result.outputURL.appendingPathComponent(ColdStorageOutput(run: run, source: URL(fileURLWithPath: run.outputPath!)).relativePath)
        let original = try Data(contentsOf: URL(fileURLWithPath: run.outputPath!))
        #expect(try Data(contentsOf: target) == original)
        let date = try target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        _ = try await engine.copy(item, jobs: [job], history: [run], onProgress: { _ in })
        #expect(try target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == date)
        try Data(repeating: 120, count: original.count).write(to: target)
        _ = try await engine.copy(item, jobs: [job], history: [run], onProgress: { _ in })
        #expect(try Data(contentsOf: target) == original)
        #expect(try Data(contentsOf: URL(fileURLWithPath: run.outputPath!)) == original)
        let sentinel = result.outputURL.appendingPathComponent("keep.txt"); try Data("keep".utf8).write(to: sentinel)
        var next = run; next.id = UUID(); next.outputPath = root.appendingPathComponent("local/new.sql").path; next.finishedAt = Date()
        try Data("new".utf8).write(to: URL(fileURLWithPath: next.outputPath!)); try FileManager.default.removeItem(atPath: run.outputPath!)
        _ = try await engine.copy(item, jobs: [job], history: [next, run], onProgress: { _ in })
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
    }

    @Test func directoryCopiesPreserveEmptyDirectoriesAndExcludeUnselectedOrFailedRuns() async throws {
        let (root, job, first, item, volume) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("local/folder"); try FileManager.default.createDirectory(at: folder.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: folder.appendingPathComponent("data.tmp"))
        var run = first; run.outputPath = folder.path
        var failed = first; failed.id = UUID(); failed.status = .failure
        var other = first; other.id = UUID(); other.jobID = UUID()
        let engine = ColdStorageEngine(resolve: volume.resolve)
        let result = try await engine.copy(item, jobs: [job], history: [run, failed, other], onProgress: { _ in })
        let target = result.outputURL.appendingPathComponent(ColdStorageOutput(run: run, source: folder).relativePath)
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("empty").path))
        #expect(try Data(contentsOf: target.appendingPathComponent("data.tmp")) == Data("payload".utf8))
        #expect(try ColdStoragePlan.outputs(for: item, jobs: [job], history: [run, failed, other]).count == 1)
    }

    @Test func disconnectDoesNotReportSuccessAndReconnectCompletes() async throws {
        let (root, job, run, item, volume) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let engine = ColdStorageEngine(resolve: volume.resolve)
        do {
            _ = try await engine.copy(item, jobs: [job], history: [run]) { _ in volume.setConnected(false) }
            Issue.record("A disconnected destination reported success")
        } catch { }
        volume.setConnected(true)
        let result = try await engine.copy(item, jobs: [job], history: [run], onProgress: { _ in })
        #expect(result.sizeBytes == 16)
        #expect(FileManager.default.fileExists(atPath: run.outputPath!))
    }

    @Test func destinationLinksAndOverlappingSourcesAreRejected() async throws {
        let (root, job, run, item, volume) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside"); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: volume.root.appendingPathComponent("BackupCron Cold Storage"), withDestinationURL: outside)
        await #expect(throws: (any Error).self) { try await ColdStorageEngine(resolve: volume.resolve).copy(item, jobs: [job], history: [run], onProgress: { _ in }) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        try FileManager.default.removeItem(at: volume.root.appendingPathComponent("BackupCron Cold Storage"))
        var overlapping = run; overlapping.outputPath = root.path
        await #expect(throws: (any Error).self) { try await ColdStorageEngine(resolve: volume.resolve).copy(item, jobs: [job], history: [overlapping], onProgress: { _ in }) }
    }

    @Test @MainActor func configurationSurvivesRestartRestoreAndRemovalKeepsCopies() throws {
        let (root, job, run, item, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let stateDir = root.appendingPathComponent("state"); try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try stateEncoder().encode(PersistedState(jobs: [job], history: [run])).write(to: stateDir.appendingPathComponent("state.json"))
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = BackupStore(stateDirectory: stateDir, defaults: defaults)
        try store.saveColdStorage(item)
        let restarted = BackupStore(stateDirectory: stateDir, defaults: defaults)
        #expect(restarted.coldStorages == [item])
        let archive = SettingsArchive(jobs: store.jobs, preferences: .init(defaults: defaults, schedulerEnabled: true), coldStorages: store.coldStorages)
        try store.deleteColdStorage(item.id); #expect(store.jobs.count == 1 && store.history.count == 1)
        try store.restoreSettings(archive); #expect(store.coldStorages == [item] && !store.schedulerEnabled)
        #expect(store.delete(job)); #expect(store.coldStorages[0].jobIDs.isEmpty)
        _ = try SettingsArchive.decode(SettingsArchive(jobs: store.jobs, preferences: .init(defaults: defaults, schedulerEnabled: false), coldStorages: store.coldStorages).encoded())
    }

    @Test @MainActor func connectionRunsOnceAndAnotherConnectionRunsAgain() async throws {
        let (root, job, run, item, volume) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let stateDir = root.appendingPathComponent("state"); try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try stateEncoder().encode(PersistedState(coldStorages: [item], jobs: [job], history: [run])).write(to: stateDir.appendingPathComponent("state.json"))
        let store = BackupStore(stateDirectory: stateDir, defaults: UserDefaults(suiteName: UUID().uuidString)!, volumeProvider: volume.current, coldEngine: .init(resolve: volume.resolve))
        store.runConnectedVolumeJobs()
        var remaining = 1000
        while !store.runningJobIDs.isEmpty && remaining > 0 { try await Task.sleep(for: .milliseconds(10)); remaining -= 1 }
        #expect(store.runningJobIDs.isEmpty)
        #expect(store.history.filter { $0.jobID == item.id }.count == 1)
        #expect(store.history.first?.status == .success)
        store.runConnectedVolumeJobs(); #expect(store.runningJobIDs.isEmpty)
        volume.setConnected(false); store.runConnectedVolumeJobs()
        volume.setConnected(true); store.runConnectedVolumeJobs()
        remaining = 1000
        while !store.runningJobIDs.isEmpty && remaining > 0 { try await Task.sleep(for: .milliseconds(10)); remaining -= 1 }
        #expect(store.runningJobIDs.isEmpty)
        #expect(store.history.filter { $0.jobID == item.id }.count == 2)
        #expect(store.history.filter { $0.jobID == job.id }.count == 1)
    }
}
