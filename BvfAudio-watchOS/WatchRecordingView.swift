import SwiftUI
import AVFoundation
import UserNotifications

/// Watch recording UI. Minimal record/stop + elapsed time + post-recording delivery
/// status. Gates recording on a recipient public key having been provisioned from
/// the iPhone via `WatchConnectivityManager` (WCSession application context) —
/// observes it live, so the UI flips from the empty state to record-enabled the
/// moment a key arrives, no relaunch needed.
struct WatchRecordingView: View {
    @StateObject private var recorder = WatchAudioRecorder()
    private let connectivity = WatchConnectivityManager.shared
    @State private var errorMessage: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if connectivity.recipientPublicKey == nil {
                emptyStateView
            } else {
                recordingView
            }
        }
        .onChange(of: recorder.error?.localizedDescription) { _, newValue in
            errorMessage = newValue
        }
        .onChange(of: scenePhase) { _, newPhase in
            // App foreground is a reconcile trigger — catches outbox files
            // left over from a force-quit mid-transfer, or accumulated while
            // unreachable.
            guard newPhase == .active else { return }
            WatchOutboxReconciler.shared.reconcile()
        }
        .onAppear {
            // Request early — before any interruption could occur — so permission
            // already exists by the time WatchAudioRecorder needs to post an
            // interruption notification. Fire-and-forget; the interruption path
            // itself doesn't check/gate on the result, since UNUserNotificationCenter
            // silently no-ops when authorization hasn't been granted.
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("Reopen BvfAudio on iPhone to set up.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var recordingView: some View {
        VStack(spacing: 12) {
            Text(formatDuration(recorder.duration))
                .font(.system(size: 28, weight: .light, design: .monospaced))

            statusBadge

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            } else if let interruptionMessage = recorder.interruptionMessage {
                Text(interruptionMessage)
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
            }

            Button(action: toggleRecording) {
                ZStack {
                    Circle()
                        .stroke(Color.white, lineWidth: 2)
                        .frame(width: 54, height: 54)
                    Circle()
                        .fill(recorder.isRecording ? Color.red : Color.white)
                        .frame(width: 46, height: 46)
                }
            }
            .buttonStyle(.plain)
            .disabled(recorder.status == .encoderUnavailable)
        }
        .padding()
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch recorder.status {
        case .idle:
            deliveryBadge
        case .recording:
            // Intentionally empty — like iOS, recording shows only the timer.
            EmptyView()
        case .encoderUnavailable:
            Text("AAC encoder unavailable")
                .font(.caption2)
                .foregroundColor(.red)
        case .interrupted:
            // Recording auto-stopped by an AVAudioSession interruption (e.g. an
            // alarm) — watchOS can't resume a backgrounded recording, so this is
            // shown so the user sees why it stopped rather than a frozen timer or
            // a silent return to idle. recorder.interruptionMessage carries the
            // detail text shown just below (see recordingView).
            Text("INTERRUPTED")
                .font(.caption.bold())
                .foregroundColor(.orange)
        }
    }

    /// Post-recording SENDING…/SENT badge; see `WatchConnectivityManager.deliveryState`.
    @ViewBuilder
    private var deliveryBadge: some View {
        switch connectivity.deliveryState {
        case .sending:
            Text("SENDING…")
                .font(.caption.bold())
                .foregroundColor(.orange)
        case .sent:
            Text("SENT")
                .font(.caption.bold())
                .foregroundColor(.green)
        case .none:
            EmptyView()
        }
    }

    private func toggleRecording() {
        if recorder.isRecording {
            // Non-throwing: any finalize failure (e.g. disk full on the final write) is
            // surfaced via recorder.error, which the .onChange handler maps to
            // errorMessage — no local catch needed.
            recorder.stop()
        } else {
            Task {
                let granted = await AVAudioApplication.requestRecordPermission()
                guard granted else {
                    errorMessage = "Microphone access denied."
                    return
                }
                do {
                    try recorder.start(recipientPublicKey: connectivity.recipientPublicKey)
                    errorMessage = nil
                } catch {
                    errorMessage = "Start failed: \(error.localizedDescription)"
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
