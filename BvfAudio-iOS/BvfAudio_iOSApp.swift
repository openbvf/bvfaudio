import SwiftUI
import BvfAppKit

@main
struct BvfAudio_iOSApp: App {
    @State private var cloudManager = iCloudManager("BvfAudio", container: "iCloud.io.bvf.shared")
    @StateObject private var recordingModel = RecordingModel()

    init() {
    }

    var body: some Scene {
        WindowGroup {
            ContentView(recorder: recordingModel)
                .environment(cloudManager)
                .task {
                    await cloudManager.initialize()
                    recordingModel.configure(cloudManager: cloudManager)
                    StagingManager.recoverOrphanedFiles(to: cloudManager.appFolderURL)
                }
        }
    }
}
