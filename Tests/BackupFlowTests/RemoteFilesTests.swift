import Foundation
import Testing
@testable import BackupFlow

struct RemoteFilesTests {
    private func fixture() throws -> (URL, BackupEngine, BackupJob) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("backupcron-remote-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let shell = root.appendingPathComponent("ssh fixture")
        try Data("""
        #!/bin/sh
        while [ "$#" -gt 0 ] && [ "$1" != backupcron-test ]; do shift; done
        [ "$#" -gt 0 ] || exit 91
        shift
        exec /bin/sh -c "$*"
        """.utf8).write(to: shell)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
        var engine = BackupEngine()
        engine.rsyncSSHExecutable = shell.path
        var job = BackupJob()
        job.name = "remote-files"
        job.filesOverSSH = true
        job.sshHost = "backupcron-test"
        job.sshUsername = "backup"
        job.sourcePath = root.appendingPathComponent("source folder ' с файлами").path
        job.destinationPath = root.appendingPathComponent("backups").path
        job.archiveOutput = false
        try FileManager.default.createDirectory(atPath: job.sourcePath, withIntermediateDirectories: true)
        return (root, engine, job)
    }

    @Test func remoteJobsRoundTripAndLegacyJobsStayLocal() throws {
        let legacy = try JSONDecoder().decode(BackupJob.self, from: Data("{}".utf8))
        #expect(!legacy.filesOverSSH)
        let (root, _, job) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let restored = try JSONDecoder().decode(BackupJob.self, from: JSONEncoder().encode(job))
        #expect(restored == job)
        #expect(JobSetupStep.source.validationKey(for: job) == nil)
        var invalid = job
        invalid.sshHost = "host;touch /tmp/not-allowed"
        #expect(JobSetupStep.source.validationKey(for: invalid) != nil)
        invalid = job
        invalid.sourcePath = "relative/path"
        #expect(JobSetupStep.source.validationKey(for: invalid) == "remote.invalid_path")
        invalid = job
        invalid.sshPort = 0
        #expect(JobSetupStep.source.validationKey(for: invalid) != nil)
    }

    @Test func rsyncCopiesUnicodeHiddenFilesAndLinksWithoutChangingSourceOrEarlierCopies() async throws {
        let (root, engine, job) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = URL(fileURLWithPath: job.sourcePath)
        let content = source.appendingPathComponent("документ.txt")
        let firstData = Data("first version".utf8)
        try firstData.write(to: content)
        try Data("hidden".utf8).write(to: source.appendingPathComponent(".hidden"))
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("link").path,
                                                  withDestinationPath: "документ.txt")
        let before = try FileManager.default.attributesOfItem(atPath: content.path)
        let first = try await engine.run(job: job, password: "")
        #expect(try Data(contentsOf: first.outputURL.appendingPathComponent("документ.txt")) == firstData)
        #expect(try Data(contentsOf: first.outputURL.appendingPathComponent(".hidden")) == Data("hidden".utf8))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: first.outputURL.appendingPathComponent("link").path) == "документ.txt")
        #expect(try FileManager.default.attributesOfItem(atPath: content.path)[.modificationDate] as? Date == before[.modificationDate] as? Date)
        try Data("second version".utf8).write(to: content)
        let second = try await engine.run(job: job, password: "")
        #expect(first.outputURL != second.outputURL)
        #expect(try Data(contentsOf: first.outputURL.appendingPathComponent("документ.txt")) == firstData)
        #expect(try Data(contentsOf: second.outputURL.appendingPathComponent("документ.txt")) == Data("second version".utf8))
    }

    @Test func shellMetacharactersStayInsideTheRemotePathAndArchiveIsVerified() async throws {
        let (root, engine, initial) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var job = initial
        let marker = root.appendingPathComponent("injected")
        job.sourcePath = root.appendingPathComponent("$(touch injected); ' quoted").path
        try FileManager.default.createDirectory(atPath: job.sourcePath, withIntermediateDirectories: true)
        try Data("safe".utf8).write(to: URL(fileURLWithPath: job.sourcePath).appendingPathComponent("file"))
        job.archiveOutput = true
        let result = try await engine.run(job: job, password: "")
        #expect(result.outputURL.pathExtension == "zip")
        #expect((result.sizeBytes ?? 0) > 0)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(!FileManager.default.fileExists(atPath: "injected"))
    }

    @Test func failedRemoteTransferDoesNotPublishOrRemoveExistingBackups() async throws {
        let (root, engine, initial) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var job = initial
        job.sourcePath += "/missing"
        let destination = URL(fileURLWithPath: job.destinationPath)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("preserve".utf8).write(to: destination.appendingPathComponent("previous"))
        await #expect(throws: BackupEngineError.self) { try await engine.run(job: job, password: "") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["previous"])
    }
}
