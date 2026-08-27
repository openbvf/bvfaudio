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
                    // Wire up the iCloud folder reference PhoneConnectivityManager
                    // needs to commit watch-delivered files, as early as possible — a
                    // WCSession-triggered background launch could deliver a file shortly
                    // after this .task starts.
                    PhoneConnectivityManager.shared.configure(cloudManager: cloudManager)
                    StagingManager.recoverOrphanedFiles(to: cloudManager.appFolderURL)
                }
        }
    }
}
