import Foundation

struct ColdStorageOutput {
    var run: BackupRun
    var source: URL
    var bookmark: SecurityScopedBookmark?

    var relativePath: String {
        let date = ISO8601DateFormatter().string(from: run.finishedAt).replacingOccurrences(of: ":", with: "-")
        return "\(String(BackupNaming.sanitize(run.jobName).prefix(80)))-\(run.jobID)/\(date)-\(run.id)/\(source.lastPathComponent)"
    }
}

enum ColdStoragePlan {
    static func outputs(for destination: ColdStorageDestination, jobs: [BackupJob], history: [BackupRun]) throws -> [ColdStorageOutput] {
        var outputs: [ColdStorageOutput] = []
        for id in destination.jobIDs {
            guard let job = jobs.first(where: { $0.id == id }) else { continue }
            let access = job.destinationBookmark?.resolve(matching: job.destinationPath)
            let accessed = access?.startAccessingSecurityScopedResource() ?? false
            defer { if accessed { access?.stopAccessingSecurityScopedResource() } }
            var seen: Set<String> = []
            let available = history.filter { $0.jobID == id && $0.status == .success }.sorted { $0.finishedAt > $1.finishedAt }.compactMap { run -> ColdStorageOutput? in
                guard let path = run.outputPath else { return nil }
                var source = URL(fileURLWithPath: path)
                if let binding = job.destinationVolume, let current = try? binding.connectedDestination(),
                   source.deletingLastPathComponent().standardizedFileURL.path == URL(fileURLWithPath: binding.configuredPath).standardizedFileURL.path {
                    source = current.appendingPathComponent(source.lastPathComponent)
                }
                guard FileManager.default.fileExists(atPath: source.path), seen.insert(source.standardizedFileURL.path).inserted else { return nil }
                return ColdStorageOutput(run: run, source: source, bookmark: job.destinationBookmark)
            }
            guard !available.isEmpty else { throw BackupEngineError.invalidConfiguration(L10n.text("cold.no_backups", job.name)) }
            outputs += available
        }
        guard !outputs.isEmpty else { throw BackupEngineError.invalidConfiguration(L10n.text("cold.choose_jobs")) }
        return outputs
    }

    static func signature(_ destination: ColdStorageDestination, history: [BackupRun]) -> String {
        history.filter { destination.jobIDs.contains($0.jobID) && $0.status == .success }
            .map { $0.id.uuidString }.sorted().joined(separator: ",")
    }
}

struct ColdStorageEngine {
    var resolve: (BackupVolumeBinding) throws -> URL = { try $0.connectedDestination() }

    func copy(_ destination: ColdStorageDestination, jobs: [BackupJob], history: [BackupRun],
              onProgress: @escaping BackupEngine.ProgressHandler) async throws -> BackupResult {
        let scoped = destination.bookmark?.resolve(matching: destination.volume.configuredPath)
        let accessed = scoped?.startAccessingSecurityScopedResource() ?? false
        defer { if accessed { scoped?.stopAccessingSecurityScopedResource() } }
        let root = try resolve(destination.volume).appendingPathComponent("BackupCron Cold Storage/\(destination.id)", isDirectory: true)
        let outputs = try ColdStoragePlan.outputs(for: destination, jobs: jobs, history: history)
        var bytes: Int64 = 0
        for (index, output) in outputs.enumerated() {
            try Task.checkCancellation()
            let sourceAccess = output.bookmark?.resolve(matching: output.bookmark?.originalPath ?? "")
            let sourceAccessed = sourceAccess?.startAccessingSecurityScopedResource() ?? false
            defer { if sourceAccessed { sourceAccess?.stopAccessingSecurityScopedResource() } }
            let target = root.appendingPathComponent(output.relativePath)
            let check = {
                try Task.checkCancellation()
                let current = try resolve(destination.volume).appendingPathComponent("BackupCron Cold Storage/\(destination.id)", isDirectory: true)
                guard current.standardizedFileURL == root.standardizedFileURL else {
                    throw BackupEngineError.invalidConfiguration(L10n.text("disk.unavailable", destination.volume.name))
                }
            }
            bytes += try await BackupEngine().copyColdStorageOutput(from: output.source, to: target, root: root, checkDestination: check) { event in
                var progress = event
                progress.fraction = (Double(index) + event.fraction) / Double(outputs.count)
                progress.message = output.run.jobName + " · " + event.message
                await onProgress(progress)
            }
        }
        return BackupResult(outputURL: root, message: L10n.text("cold.ready"), sizeBytes: bytes)
    }
}
