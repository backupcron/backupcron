import SwiftUI

@main
struct BackupCronApp: App {
    @StateObject private var store = BackupStore()

    init() {
        BackupNotifications.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 620)
                .task {
                    store.startScheduler()
                }
        }
        .defaultSize(width: 1120, height: 760)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.text("common.new_job")) {
                    NotificationCenter.default.post(name: .createBackupJob, object: nil)
                }
                .keyboardShortcut("n")
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}

extension Notification.Name {
    static let createBackupJob = Notification.Name("BackupCron.createBackupJob")
}
