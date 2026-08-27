import SwiftUI
import AVFoundation
import Combine
import UserNotifications
import BvfAppKit

struct RecordingView: View {
    @Environment(iCloudManager.self) var cloudManager
    @ObservedObject var recorder: RecordingModel
    @State private var lastSaveDate: Date?
    @State private var errorMessage: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack {
                HStack {
                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color.red.opacity(0.8))
                            .cornerRadius(8)
                    } else if let date = lastSaveDate {
                        TimelineView(.periodic(from: Date(), by: 60)) { _ in
                            Text("Saved \(date.relativeTimeString())")
                                .font(.caption)
                                .foregroundColor(.white)
                                .padding(8)
                                .background(Color.green.opacity(0.8))
                                .cornerRadius(8)
                        }
                    }
                    Spacer()
                }
                .padding()

                Spacer()

                if recorder.isRecording {
                    Text(formatDuration(recorder.recordingDuration))
                        .font(.system(size: 48, weight: .light, design: .monospaced))
                        .foregroundColor(.white)
                }

                Spacer()

                Button(action: toggleRecording) {
                    ZStack {
                        Circle()
                            .stroke(Color.white, lineWidth: 3)
                            .frame(width: 80, height: 80)

                        Circle()
                            .fill(recorder.isRecording ? Color.red : Color.white)
                            .frame(width: 70, height: 70)
                    }
                }
                .disabled(recorder.isSaving)
                .opacity(recorder.isSaving ? 0.5 : 1.0)
                .padding(.bottom, 30)
            }
        }
        .onAppear {
            recorder.configure(cloudManager: cloudManager)

            // Request early — before any interruption could occur — so permission
            // already exists by the time an interruption needs to post its
            // notification. Fire-and-forget; the interruption path doesn't gate on
            // the result, since UNUserNotificationCenter silently no-ops when
            // authorization hasn't been granted.
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        .onChange(of: recorder.lastSaveDate) { _, date in
            lastSaveDate = date
        }
        .onChange(of: recorder.errorMessage) { _, error in
            errorMessage = error
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                recorder.handleBackground()
            } else if newPhase == .active {
                recorder.endBackgroundTaskIfNeeded()
            }
        }
    }

    private func toggleRecording() {
        if recorder.isRecording {
            recorder.stopRecording()
        } else {
            Task {
                if await AVAudioApplication.requestRecordPermission() {
                    recorder.startRecording()
                } else {
                    errorMessage = "Microphone access denied. Enable in Settings > Privacy & Security > Microphone"
                }
            }
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

@MainActor
class RecordingModel: ObservableObject {
    private var secureRecorder: SecureAudioRecorder?
    private var cloudManager: iCloudManager?
    private var durationCancellable: AnyCancellable?
    nonisolated(unsafe) private var interruptionObserver: NSObjectProtocol?
    nonisolated(unsafe) private var routeChangeObserver: NSObjectProtocol?
    nonisolated(unsafe) private var terminateObserver: NSObjectProtocol?

    /// Input port UIDs captured when a recording starts. The route-change observer
    /// compares the live input against this baseline, not against the notification's
    /// previous route — otherwise the route change emitted when the `.record` session
    /// first activates (previous route -> record input) reads as an input change and
    /// auto-stops the recording the instant it starts.
    nonisolated(unsafe) private var recordingInputUIDs: Set<String> = []

    @Published var isRecording = false
    @Published var isSaving = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var lastSaveDate: Date?
    @Published var errorMessage: String?

    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid

    private var currentContext: PushEncryptionContext?

    func configure(cloudManager: iCloudManager) {
        self.cloudManager = cloudManager
        setupInterruptionObserver()
        setupRouteChangeObserver()
        setupTerminateObserver()
    }

    private func setupTerminateObserver() {
        terminateObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                if self?.isRecording == true {
                    self?.stopRecording()
                }
            }
        }
    }

    func startRecording() {
        guard let cloudManager = cloudManager,
              let publicKeyURL = cloudManager.sharedPublicKeyURL,
              let folderURL = cloudManager.appFolderURL else {
            errorMessage = "iCloud not configured"
            return
        }

        do {
            let context = try PushEncryptionContext(publicKeyURL: publicKeyURL, to: folderURL, suffix: "aac")
            currentContext = context

            let recorder = SecureAudioRecorder()
            try recorder.start(encryptionContext: context)
            secureRecorder = recorder

            // Baseline the input the recording started on, now that the session is
            // active. The route-change observer compares against this.
            recordingInputUIDs = Set(AVAudioSession.sharedInstance().currentRoute.inputs.map(\.uid))

            isRecording = true
            recordingDuration = 0
            errorMessage = nil

            durationCancellable = recorder.$duration
                .sink { [weak self] duration in
                    Task { @MainActor in
                        self?.recordingDuration = duration
                    }
                }

            recorder.$error.map { $0?.localizedDescription }.assign(to: &$errorMessage)

        } catch {
            errorMessage = "Recording failed: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        guard let recorder = secureRecorder else { return }

        durationCancellable?.cancel()
        durationCancellable = nil

        do {
            try recorder.stop()
            secureRecorder = nil

            currentContext = nil
            isRecording = false
            lastSaveDate = Date()

            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)

            endBackgroundTaskIfNeeded()

        } catch {
            errorMessage = "Stop recording failed: \(error.localizedDescription)"
            isRecording = false
            secureRecorder = nil
            currentContext = nil

            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.error)

            endBackgroundTaskIfNeeded()
        }
    }

    func handleBackground() {
        backgroundTaskId = UIApplication.shared.beginBackgroundTask { [weak self] in
            Task { @MainActor in
                self?.endBackgroundTaskIfNeeded()
            }
        }
        // Recording continues in background - don't stop it
        // Background task kept as fallback grace period
    }

    func endBackgroundTaskIfNeeded() {
        if backgroundTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskId)
            backgroundTaskId = .invalid
        }
    }

    private func setupInterruptionObserver() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
                return
            }

            Task { @MainActor in
                if type == .began {
                    // Interruption began (phone call, Siri, etc.) - save recording cleanly
                    guard self?.isRecording == true else { return }
                    self?.stopRecording()
                    // Tell the user why recording stopped even while the app is
                    // backgrounded — a delivered local notification is the only
                    // reliable signal then. Foregrounded, the system suppresses it
                    // (no notification-center delegate is registered), matching the
                    // watch app.
                    RecordingModel.postInterruptionNotification()
                }
                // On .ended, user can manually start a new recording
            }
        }
    }

    /// Observes `AVAudioSession.routeChangeNotification` for the lifetime of the
    /// model (registered in `configure`, removed in `deinit`). A mid-recording input
    /// change (e.g. AirPods connecting) is detected by comparing the live input UIDs
    /// against `recordingInputUIDs` (the input the recording started on) rather than
    /// trusting the reason code — this is reason-agnostic and does not false-trigger
    /// on the route change emitted when the `.record` session first activates,
    /// because by then the live input already equals the baseline. On a real input
    /// change, stop and finalize cleanly — mirroring the interruption path — and
    /// notify the user the same way.
    private func setupRouteChangeObserver() {
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                let currentInputs = Set(AVAudioSession.sharedInstance().currentRoute.inputs.map(\.uid))
                guard currentInputs != self.recordingInputUIDs else { return }
                self.stopRecording()
                RecordingModel.postInterruptionNotification()
            }
        }
    }

    /// Posts an immediate local notification so the user finds out a recording was
    /// auto-stopped by an interruption while the app is backgrounded. Mirrors the
    /// watch app; `UNUserNotificationCenter.add` is thread-safe and no delegate is
    /// registered, so the default banner-when-backgrounded / suppressed-when-
    /// foregrounded behavior is exactly what's wanted.
    private static func postInterruptionNotification() {
        let content = UNMutableNotificationContent()
        content.title = "BvfAudio"
        content.body = "Recording interrupted"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    deinit {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = terminateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
