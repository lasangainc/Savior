import SwiftUI

@main
struct SaviorApp: App {
    @State private var store = DownloadStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    store.stopAll()
                }
        }
        .defaultSize(width: 860, height: 680)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Download Folder", systemImage: "folder") { store.openDestination() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
        Settings {
            SettingsView(store: store)
        }
    }
}
