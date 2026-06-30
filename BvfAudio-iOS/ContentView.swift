import SwiftUI
import BvfAppKit

struct ContentView: View {
    @Environment(iCloudManager.self) var cloudManager
    @ObservedObject var recorder: RecordingModel
    @State private var isReady = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let error = errorMessage {
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding()
            } else if isReady {
                RecordingView(recorder: recorder)
            } else {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Connecting to iCloud...")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .padding()
            }
        }
        .onAppear {
            if cloudManager.isAvailable {
                checkSetup()
            }
        }
        .onChange(of: cloudManager.isAvailable) { _, available in
            if available {
                checkSetup()
            }
        }
    }

    private func checkSetup() {
        guard cloudManager.isAvailable,
              let _ = cloudManager.appFolderURL,
              let publicKeyURL = cloudManager.sharedPublicKeyURL else {
            errorMessage = "iCloud Drive is required. Enable iCloud in Settings → [Your Name] → iCloud → iCloud Drive."
            return
        }

        if FileManager.default.fileExists(atPath: publicKeyURL.path) {
            isReady = true
            errorMessage = nil
        } else {
            errorMessage = "iCloud must be set up in this app on a computer first."
        }
    }
}
