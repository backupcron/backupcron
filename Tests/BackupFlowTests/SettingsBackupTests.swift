import Foundation
import ServiceManagement
import Testing
@testable import BackupFlow

@Suite struct SettingsBackupTests {
    @Test @MainActor func coldStorageArchivesPreserveDeviceAndSelectionWithoutLocalAccessTokens() throws {
        let source = job()
        let volume = BackupVolumeBinding(id: "fixture-volume", name: "Offline", relativePath: "reserve", configuredPath: "/Volumes/Offline/reserve")
        let item = ColdStorageDestination(name: "Reserve", volume: volume, jobIDs: [source.id],
            bookmark: SecurityScopedBookmark(data: Data("local-access".utf8), originalPath: volume.configuredPath))
        let archive = SettingsArchive(jobs: [source], preferences: .init(defaults: .standard, schedulerEnabled: true), coldStorages: [item])
        let restored = try SettingsArchive.decode(archive.encoded())
        let saved = try #require(restored.coldStorages?.first)
        #expect(saved.volume == volume && saved.jobIDs == [source.id])
        #expect(saved.bookmark == nil)
        var invalid = archive
        invalid.coldStorages?[0].jobIDs = [UUID()]
        #expect(throws: (any Error).self) { try SettingsArchive.decode(invalid.encoded()) }
        invalid = archive
        invalid.coldStorages?[0].volume.relativePath = "../outside"
        #expect(throws: (any Error).self) { try SettingsArchive.decode(invalid.encoded()) }
    }

    @Test @MainActor func settingsBeforeColdStorageRemainCompatible() throws {
        let archive = SettingsArchive(jobs: [job()], preferences: .init(defaults: .standard, schedulerEnabled: true))
        var object = try #require(JSONSerialization.jsonObject(with: archive.encoded()) as? [String: Any])
        object.removeValue(forKey: "coldStorages")
        let restored = try SettingsArchive.decode(JSONSerialization.data(withJSONObject: object))
        #expect(restored.coldStorages == nil && restored.jobs.count == 1)
    }

    @Test @MainActor func groupsSurviveRestartExportAndRestoreWithoutLosingJobs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaultsName = "BackupCron.group-test.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: defaultsName) }
        let store = BackupStore(stateDirectory: directory, defaults: defaults, passwordWriter: { _, _ in })
        var files = job(); files.name = "Files"
        var database = job(); database.name = "Database"; database.isEnabled = false
        try store.addOrUpdate(files); try store.addOrUpdate(database)
        let group = try store.saveGroup(name: "  Website  ", jobIDs: [files.id, database.id])
        #expect(group.name == "Website")
        #expect(store.jobs.allSatisfy { $0.groupID == group.id })
        #expect(store.runnableJobs(in: group.id).map(\.id) == [files.id])
        #expect(throws: (any Error).self) { try store.saveGroup(name: "website", jobIDs: []) }
        let empty = try store.saveGroup(name: "Empty", jobIDs: [])
        let restarted = BackupStore(stateDirectory: directory, defaults: defaults)
        #expect(restarted.groups == [group, empty])
        #expect(restarted.jobs.map(\.id) == [files.id, database.id])
        _ = try store.saveGroup(name: "Renamed", id: group.id, jobIDs: [files.id])
        #expect(store.jobs.first { $0.id == database.id }?.groupID == nil)
        var moved = try #require(store.jobs.first { $0.id == database.id }); moved.groupID = empty.id
        try store.addOrUpdate(moved)
        let archive = try SettingsArchive.decode(SettingsArchive(jobs: store.jobs, preferences: .init(defaults: defaults, schedulerEnabled: true), groups: store.groups).encoded())
        try store.deleteGroup(group.id)
        #expect(store.jobs.count == 2 && store.jobs.first { $0.id == files.id }?.groupID == nil)
        #expect(store.jobs.first { $0.id == database.id }?.groupID == empty.id)
        try store.restoreSettings(archive)
        #expect(store.groups.map(\.name) == ["Renamed", "Empty"])
        #expect(store.jobs.first { $0.id == files.id }?.groupID == group.id)
        #expect(store.jobs.first { $0.id == database.id }?.groupID == empty.id)
        var invalid = archive; invalid.groups = []
        #expect(throws: (any Error).self) { try store.restoreSettings(invalid) }
        #expect(store.groups.count == 2 && store.jobs.count == 2)
        let stateURL = directory.appendingPathComponent("state.json")
        try FileManager.default.removeItem(at: stateURL)
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try store.deleteGroup(group.id) }
        #expect(store.groups.count == 2 && store.jobs.first { $0.id == files.id }?.groupID == group.id)
    }

    @Test @MainActor func oldSettingsWithoutGroupsRemainCompatible() throws {
        let archive = SettingsArchive(jobs: [job()], preferences: .init(defaults: .standard, schedulerEnabled: true))
        var json = try #require(JSONSerialization.jsonObject(with: archive.encoded()) as? [String: Any])
        json.removeValue(forKey: "groups")
        let restored = try SettingsArchive.decode(JSONSerialization.data(withJSONObject: json))
        #expect(restored.groups == nil && restored.jobs[0].groupID == nil)
    }

    @Test @MainActor func groupRunStartsOnlyEnabledMembersOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaultsName = "BackupCron.group-run.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: defaultsName) }
        let source = directory.appendingPathComponent("fixture.txt")
        try Data("group fixture".utf8).write(to: source)
        let store = BackupStore(stateDirectory: directory.appendingPathComponent("state"), defaults: defaults)
        var first = BackupJob(); first.name = "Files"; first.sourcePath = source.path; first.destinationPath = directory.appendingPathComponent("out").path; first.schedule = .manual; first.archiveOutput = false
        var second = first; second.id = UUID(); second.name = "Database export"
        var paused = first; paused.id = UUID(); paused.name = "Paused"; paused.isEnabled = false
        var outside = first; outside.id = UUID(); outside.name = "Other resource"
        for item in [first, second, paused, outside] { try store.addOrUpdate(item) }
        let group = try store.saveGroup(name: "Resource", jobIDs: [first.id, second.id, paused.id])
        store.runGroup(group.id); store.runGroup(group.id)
        #expect(store.runningJobIDs == [first.id, second.id])
        let deadline = Date().addingTimeInterval(15)
        while !store.runningJobIDs.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        #expect(store.runningJobIDs.isEmpty)
        #expect(store.history.count == 2)
        #expect(Set(store.history.map(\.jobID)) == [first.id, second.id])
        #expect(store.history.allSatisfy { $0.status == .success })
    }

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
