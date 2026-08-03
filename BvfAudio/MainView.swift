import SwiftUI
import BvfAppKitDecrypt

struct MainView: View {
    @Environment(FileAccessManager.self) private var fileAccessManager
    @Environment(AppSettings.self) private var appSettings
    @Environment(TabSelection.self) var tabSelection
    @State private var showOnboarding = false

    var body: some View {
        @Bindable var tabSelection = tabSelection
        TabView(selection: $tabSelection.selected) {
            RecordView()
                .tabItem {
                    Label("Record", systemImage: "waveform")
                }.tag(0)

            if fileAccessManager.isStandardMode {
                AudioView()
                    .tabItem {
                        Label("Browse", systemImage: "house.fill")
                    }.tag(1)
            }
        }
        .tabCyclingShortcuts(
            selection: $tabSelection.selected,
            count: fileAccessManager.isStandardMode ? 2 : 1
        )
        .task {
            if !fileAccessManager.isConfigured && !appSettings.hasSkippedOnboarding && !fileAccessManager.needsKeyFolderMigration {
                showOnboarding = true
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(appName: "BvfAudio", appGroupIdentifier: "group.io.bvf.shared")
        }
    }
}
