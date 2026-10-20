import Foundation
import ServiceManagement
import Testing
@testable import BackupFlow

@Suite struct SettingsBackupTests {
    private func job() -> BackupJob {
        var job = BackupJob()
        job.name = "Settings fixture"
        job.sourcePath = "/tmp/source"
        job.destinationPath = "/tmp/destination"
        job.schedule = .daily
        job.lastRunAt = Date()
        job.sourceBookmark = SecurityScopedBookmark(data: Data("local-access".utf8), originalPath: job.sourcePath)
        return job
    }

    @Test @MainActor func archiveRoundTripOmitsDeviceAccessAndKeepsSettings() throws {
        let name = "BackupCron.settings-test.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: BackupSoundPreferences.enabledKey)
        defaults.set(0.25, forKey: BackupSoundPreferences.volumeKey)
        defaults.set("password-secret", forKey: "unrelated-password")
        let archive = SettingsArchive(jobs: [job()], preferences: .init(defaults: defaults, schedulerEnabled: true))
        let data = try archive.encoded()
        let restored = try SettingsArchive.decode(data)
        #expect(restored.jobs[0].name == "Settings fixture")
        #expect(restored.jobs[0].sourceBookmark == nil)
        #expect(restored.jobs[0].lastRunAt == nil)
        #expect(restored.preferences.soundEnabled)
        #expect(restored.preferences.soundVolume == 0.25)
        #expect(!String(decoding: data, as: UTF8.self).contains("password-secret"))
    }

    @Test @MainActor func snapshotsAreDistinctAndExistingFilesArePreserved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = SettingsArchive(jobs: [job()], preferences: .init(defaults: .standard, schedulerEnabled: true))
        let first = try SettingsArchiveFile.write(archive, to: directory)
        let original = try Data(contentsOf: first)
        let second = try SettingsArchiveFile.write(archive, to: directory)
        #expect(first != second)
        #expect(try Data(contentsOf: first) == original)
        #expect(try SettingsArchiveFile.read(second).jobs[0].id == archive.jobs[0].id)
    }

    @Test @MainActor func invalidArchivesDoNotChangeSavedState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = "BackupCron.settings-test.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: name) }
        let store = BackupStore(stateDirectory: directory, defaults: defaults)
        try store.addOrUpdate(job())
        let original = try Data(contentsOf: directory.appendingPathComponent("state.json"))
        var archive = SettingsArchive(jobs: [job()], preferences: .init(defaults: defaults, schedulerEnabled: false))
        archive.version = 99
        #expect(throws: (any Error).self) { try store.restoreSettings(archive) }
        archive.version = 1
        archive.jobs.append(archive.jobs[0])
        #expect(throws: (any Error).self) { try store.restoreSettings(archive) }
        #expect(throws: (any Error).self) { try SettingsArchive.decode(Data("{}".utf8)) }
        #expect(try Data(contentsOf: directory.appendingPathComponent("state.json")) == original)
        #expect(store.schedulerEnabled)
    }

    @Test @MainActor func restoreSavesRecoveryAndPausesScheduler() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = "BackupCron.settings-test.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: name) }
        let store = BackupStore(stateDirectory: directory, defaults: defaults)
        let originalJob = job()
        try store.addOrUpdate(originalJob)
        var newJob = job(); newJob.name = "Restored"
        let archive = SettingsArchive(jobs: [newJob], preferences: .init(defaults: defaults, schedulerEnabled: true))
        try store.restoreSettings(archive)
        #expect(store.jobs.count == 1)
        #expect(store.jobs[0].name == "Restored")
        #expect(store.jobs[0].sourceBookmark == nil)
        #expect(!store.schedulerEnabled)
        let recovered = BackupStore(stateDirectory: directory, defaults: defaults)
        #expect(recovered.jobs[0].id == newJob.id)
        #expect(!recovered.schedulerEnabled)
        let recovery = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("Settings recovery"), includingPropertiesForKeys: nil)
        #expect(recovery.count == 1)
        #expect(try SettingsArchiveFile.read(recovery[0]).jobs[0].id == originalJob.id)
    }

    @Test @MainActor func loginFailuresReflectActualSystemState() {
        let service = SettingsLoginService()
        let controller = LaunchAtLoginController(service: service)
        service.fail = true
        controller.setEnabled(true)
        #expect(!controller.isEnabled)
        #expect(controller.errorMessage != nil)
        service.fail = false
        controller.setEnabled(true)
        #expect(controller.isEnabled)
        service.status = .notRegistered
        controller.refresh()
        #expect(!controller.isEnabled)
        service.status = .notFound
        controller.setEnabled(false)
        #expect(controller.errorMessage == nil)
    }

    @Test @MainActor func automaticCopiesTrackChangesAndSkipUnchangedSettings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "BackupCron.settings-test.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: name) }
        defaults.set(try directory.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil), forKey: "settingsBackupFolder")
        defaults.set(true, forKey: SettingsBackupController.enabledKey)
        let controller = SettingsBackupController(defaults: defaults)
        var currentJob = job()
        controller.start { SettingsArchive(jobs: [currentJob], preferences: .init(defaults: defaults, schedulerEnabled: true)) }
        await controller.backup(automatic: true)
        #expect(controller.errorMessage == nil)
        await controller.backup(automatic: true)
        var files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        currentJob.name = "Changed"
        controller.schedule()
        try await Task.sleep(for: .seconds(1.5))
        files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 2)
        #expect(try files.contains { try SettingsArchiveFile.read($0).jobs[0].name == "Changed" })
        try await Task.sleep(for: .seconds(1.2))
        defaults.set(0.75, forKey: BackupSoundPreferences.volumeKey)
        try await Task.sleep(for: .seconds(1.5))
        files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 3)
        #expect(try files.contains { try SettingsArchiveFile.read($0).preferences.soundVolume == 0.75 })
        controller.setEnabled(false)
        currentJob.name = "Disabled"
        controller.schedule()
        try await Task.sleep(for: .seconds(1.2))
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count == 3)
    }

    @Test @MainActor func failedRecoverySaveLeavesSettingsUntouched() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = "BackupCron.settings-test.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: name) }
        let store = BackupStore(stateDirectory: directory, defaults: defaults)
        let current = job()
        try store.addOrUpdate(current)
        try Data("blocked".utf8).write(to: directory.appendingPathComponent("Settings recovery"))
        let original = try Data(contentsOf: directory.appendingPathComponent("state.json"))
        let archive = SettingsArchive(jobs: [], preferences: .init(defaults: defaults, schedulerEnabled: false))
        #expect(throws: (any Error).self) { try store.restoreSettings(archive) }
        #expect(store.jobs[0].id == current.id)
        #expect(store.schedulerEnabled)
        #expect(try Data(contentsOf: directory.appendingPathComponent("state.json")) == original)
    }
}

private final class SettingsLoginService: LaunchAtLoginService {
    var status: SMAppService.Status = .notRegistered
    var fail = false
    func register() throws {
        if fail { throw CocoaError(.fileWriteNoPermission) }
        status = .enabled
    }
    func unregister() throws { status = .notRegistered }
}
