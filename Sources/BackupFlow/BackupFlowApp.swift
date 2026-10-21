import AppKit
import SwiftUI

@main
struct BackupCronApp: App {
    @StateObject private var store = BackupStore()

    init() {
        BackupNotifications.configure()
    }

    var body: some Scene {
        Window("BackupCron", id: "main") {
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

        MenuBarExtra("BackupCron", systemImage: "externaldrive.badge.timemachine") {
            BackupCronMenu()
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct BackupCronMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(L10n.text("menu.open")) {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button(L10n.text("menu.quit")) {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

extension Notification.Name {
    static let createBackupJob = Notification.Name("BackupCron.createBackupJob")
}
