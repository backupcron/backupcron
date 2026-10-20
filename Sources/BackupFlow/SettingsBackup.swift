import AppKit
import Combine
import Foundation

struct SettingsArchive: Codable {
    static let format = "BackupCron.macOS.settings"
    var format = Self.format
    var version = 1
    var createdAt = Date()
    var jobs: [BackupJob]
    var preferences: Preferences

    struct Preferences: Codable, Equatable {
        var schedulerEnabled: Bool
        var notifyOnSuccess: Bool
        var notifyOnFailure: Bool
        var soundEnabled: Bool
        var soundVolume: Double

        init(defaults: UserDefaults, schedulerEnabled: Bool) {
            self.schedulerEnabled = schedulerEnabled
            notifyOnSuccess = defaults.bool(forKey: BackupNotifications.notifyOnSuccessKey)
            notifyOnFailure = defaults.bool(forKey: BackupNotifications.notifyOnFailureKey)
            let sound = BackupSoundPreferences(defaults: defaults)
            soundEnabled = sound.enabled
            soundVolume = sound.volume
        }
    }

    init(jobs: [BackupJob], preferences: Preferences) {
        self.jobs = jobs.map { job in
            var copy = job
            copy.sourceBookmark = nil
            copy.destinationBookmark = nil
            copy.clientExecutableBookmark = nil
            copy.sshIdentityBookmark = nil
            copy.lastRunAt = nil
            return copy
        }
        self.preferences = preferences
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 20 * 1_024 * 1_024 else { throw SettingsBackupError.invalidArchive }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(Self.self, from: data)
        guard archive.format == Self.format, archive.version == 1,
              Set(archive.jobs.map(\.id)).count == archive.jobs.count,
              archive.preferences.soundVolume.isFinite,
              (0...1).contains(archive.preferences.soundVolume),
              archive.jobs.allSatisfy({ job in
                  JobSetupStep.allCases.allSatisfy { $0.validationKey(for: job) == nil }
                  && (BackupJob.minimumIntervalMinutes...BackupJob.maximumIntervalMinutes).contains(job.intervalMinutes)
                  && (1...7).contains(job.weekday) && job.retentionCount >= 0
              }) else { throw SettingsBackupError.invalidArchive }
        return archive
    }
}

enum SettingsBackupError: LocalizedError {
    case invalidArchive, chooseICloud, chooseFolder, running

    var errorDescription: String? {
        switch self {
        case .invalidArchive: L10n.text("settings_backup.invalid")
        case .chooseICloud: L10n.text("settings_backup.icloud_required")
        case .chooseFolder: L10n.text("settings_backup.choose_folder")
        case .running: L10n.text("settings_backup.running")
        }
    }
}

enum SettingsArchiveFile {
    static func write(_ archive: SettingsArchive, to directory: URL) throws -> URL {
        let data = try archive.encoded()
        let stamp = ISO8601DateFormatter().string(from: archive.createdAt).replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("BackupCron-settings-\(stamp)-\(UUID().uuidString).json")
        var coordinationError: NSError?
        var result: Result<Void, Error> = .success(())
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { coordinated in
            result = Result { try data.write(to: coordinated, options: .atomic) }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
        return url
    }

    static func read(_ url: URL) throws -> SettingsArchive {
        var coordinationError: NSError?
        var result: Result<SettingsArchive, Error> = .failure(SettingsBackupError.invalidArchive)
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinated in
            result = Result {
                let size = try coordinated.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 20 * 1_024 * 1_024 else { throw SettingsBackupError.invalidArchive }
                return try SettingsArchive.decode(Data(contentsOf: coordinated))
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }
}

@MainActor
final class SettingsBackupController: ObservableObject {
    static let enabledKey = "settingsBackupEnabled"
    private static let bookmarkKey = "settingsBackupFolder"
    @Published private(set) var enabled: Bool
    @Published private(set) var folderPath: String?
    @Published private(set) var isBusy = false
    @Published var message: String?
    @Published var errorMessage: String?
    private let defaults: UserDefaults
    private var bookmark: Data?
    private var subscriptions: Set<AnyCancellable> = []
    private var pending: Task<Void, Never>?
    private var snapshot: (() -> SettingsArchive)?
    private var lastContent: Data?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: Self.enabledKey)
        bookmark = defaults.data(forKey: Self.bookmarkKey)
        folderPath = try? resolveFolder().path
    }

    func start(snapshot: @escaping () -> SettingsArchive) {
        self.snapshot = snapshot
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.schedule() }
            .store(in: &subscriptions)
        schedule()
    }

    func setEnabled(_ value: Bool) {
        if value && bookmark == nil { chooseFolder(enableAfterSelection: true); return }
        enabled = value
        defaults.set(value, forKey: Self.enabledKey)
        if value { schedule() } else { pending?.cancel() }
    }

    func chooseFolder(enableAfterSelection: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.text("settings_backup.choose_folder")
        if let folderPath { panel.directoryURL = URL(fileURLWithPath: folderPath) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            guard try url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem == true else {
                throw SettingsBackupError.chooseICloud
            }
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            bookmark = data
            folderPath = url.path
            defaults.set(data, forKey: Self.bookmarkKey)
            lastContent = nil
            errorMessage = nil
            if enableAfterSelection { setEnabled(true) } else { schedule() }
        } catch { errorMessage = error.localizedDescription }
    }

    func schedule() {
        guard enabled else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            await self?.backup(automatic: true)
        }
    }

    func backup(automatic: Bool = false) async {
        guard !isBusy, let archive = snapshot?() else { return }
        do {
            var comparable = archive
            comparable.createdAt = Date(timeIntervalSince1970: 0)
            let content = try comparable.encoded()
            if automatic && content == lastContent { return }
            let directory = try resolveFolder()
            let accessed = directory.startAccessingSecurityScopedResource()
            defer { if accessed { directory.stopAccessingSecurityScopedResource() } }
            isBusy = true
            defer { isBusy = false }
            _ = try await Task.detached(priority: .utility) {
                try SettingsArchiveFile.write(archive, to: directory)
            }.value
            lastContent = content
            errorMessage = nil
            message = L10n.text("settings_backup.saved", Date().formatted(date: .abbreviated, time: .shortened))
            if enabled { schedule() }
        } catch { errorMessage = error.localizedDescription }
    }

    func loadForRestore(_ url: URL) async throws -> SettingsArchive {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try await Task.detached(priority: .userInitiated) { try SettingsArchiveFile.read(url) }.value
    }

    private func resolveFolder() throws -> URL {
        guard let bookmark else { throw SettingsBackupError.chooseFolder }
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        if stale {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let updated = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            self.bookmark = updated
            defaults.set(updated, forKey: Self.bookmarkKey)
        }
        return url
    }
}
