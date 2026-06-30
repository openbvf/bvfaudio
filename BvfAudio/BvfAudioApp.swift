import SwiftUI
import Combine
import BvfAppKitDecrypt

@main
struct BvfAudioApp: App {
    @State private var tabSelection = TabSelection()
    @State private var env = BvfAppKitEnvironment(
        app: "BvfAudio",
        container: "iCloud.io.bvf.shared",
        appGroupIdentifier: "group.io.bvf.shared"
    )

    init() {
        DisableCoreDumps.apply()
    }

    var body: some Scene {
        Window("BvfAudio", id: "main") {
            AppRootView {
                MainView()
                    .environment(tabSelection)
                    .bvfAppKitEnvironment(env)
                    .task {
                        await env.initialize()
                        StagingManager.recoverOrphanedFiles(to: env.cloudManager.appFolderURL)
                    }
            }
        }
        .commands {
            CommandMenu("Tabs") {
                Button("Record") { tabSelection.selected = 0 }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Browse") { tabSelection.selected = 1 }
                    .keyboardShortcut("2", modifiers: .command)
            }
        }

        Settings {
            PreferencesView(appName: "BvfAudio", appGroupIdentifier: "group.io.bvf.shared")
                .bvfAppKitEnvironment(env)
        }
    }
}
