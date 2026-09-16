import SwiftUI

@main
struct MulticastViewApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("MulticastView") {
            ContentView(model: model)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Capture") {
                Button(model.isCapturing ? "Stop" : "Start") {
                    model.isCapturing ? model.stop() : model.start()
                }
                .keyboardShortcut("r", modifiers: .command)

                Button(model.captureState == .paused ? "Resume" : "Pause") {
                    model.togglePause()
                }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(!model.isCapturing)

                Divider()

                Button("Reveal Session Logs in Finder") { model.revealSessionLogs() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])

                Divider()

                Button("Refresh interfaces") { model.refreshInterfaces() }
                Button("Poll switches now") { model.pollSwitches() }
                Button("Refresh this Mac's memberships") { model.refreshMemberships() }
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }
}
