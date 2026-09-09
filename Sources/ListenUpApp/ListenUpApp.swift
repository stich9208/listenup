import SwiftUI

@main
struct ListenUpDesktopApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 640)
        }
        .windowStyle(.titleBar)

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 600, height: 440)
        }
    }
}
