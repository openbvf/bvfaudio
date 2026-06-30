import SwiftUI
import Combine
import AVFoundation
import BvfAppKitDecrypt

struct RecordView: View {
    @Environment(FileAccessManager.self) private var fileAccessManager
    @StateObject private var recorder = SecureAudioRecorder()

    @State private var responseMessage: ResponseMessage?
    @State private var durationCancellable: AnyCancellable?
    @State private var currentContext: PushEncryptionContext?

    private var publicKeyURL: URL? { fileAccessManager.capturePublicKeyURL }
    private var folderURL: URL? { fileAccessManager.captureFolderURL }

    private var isReady: Bool {
        publicKeyURL != nil && folderURL != nil
    }

    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                headerView
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .padding(.top, 8)

                Spacer()

                if recorder.isRecording {
                    Text(formatDuration(recorder.duration))
                        .font(.system(size: 48, weight: .light, design: .monospaced))
                        .foregroundColor(.primary)
                }

                Spacer()

                Button(action: toggleRecording) {
                    ZStack {
                        Circle()
                            .stroke(Color.primary, lineWidth: 3)
                            .frame(width: 80, height: 80)

                        Circle()
                            .fill(recorder.isRecording ? Color.red : Color.primary)
                            .frame(width: 70, height: 70)
                    }
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!isReady || !recorder.isPrepared)
                .padding(.bottom, 30)
            }
        }
        .onAppear {
            validateConfiguration()
            Task {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    responseMessage = ResponseMessage("Microphone access denied. Enable in System Settings > Privacy & Security > Microphone", type: .error)
                    return
                }
                do {
                    try recorder.prepare()
                } catch {
                    responseMessage = ResponseMessage("Mic init failed: \(error.localizedDescription)", type: .error)
                }
            }
        }
        .onDisappear {
            recorder.teardown()
        }
        .onChange(of: recorder.error?.localizedDescription) { _, message in
            if let message {
                responseMessage = ResponseMessage(message, type: .error)
            }
        }
    }

    private func validateConfiguration() {
        responseMessage = fileAccessManager.validateCaptureConfiguration(folderName: "audio folder")
    }

    private var headerView: some View {
        HStack {
            ReadyIndicatorView(isReady: isReady)

            if !recorder.isPrepared {
                Text("Preparing mic…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if let message = responseMessage {
                Text(message.text)
                    .font(.caption)
                    .foregroundColor(message.type.color)
                    .lineLimit(2)
            }

            Spacer()

            Button(action: toggleRecording) {
                Label(
                    recorder.isRecording ? "Stop" : "Record",
                    systemImage: recorder.isRecording ? "stop.fill" : "record.circle"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(recorder.isRecording ? .red : .accentColor)
            .disabled(!isReady || !recorder.isPrepared)
            .keyboardShortcut("S", modifiers: .command)
        }
    }

    private func toggleRecording() {
        if recorder.isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard let pubKeyURL = publicKeyURL,
              let folderURL = folderURL else {
            responseMessage = ResponseMessage("Missing required folder or public key file", type: .error)
            return
        }

        do {
            let context = try PushEncryptionContext(publicKeyURL: pubKeyURL, to: folderURL, suffix: "aac")
            try recorder.start(encryptionContext: context)
            currentContext = context
            responseMessage = nil
        } catch {
            responseMessage = ResponseMessage("Recording failed: \(error.localizedDescription)", type: .error)
        }
    }

    private func stopRecording() {
        do {
            try recorder.stop()

            currentContext = nil

            responseMessage = ResponseMessage("Saved at \(Date().timeString)", type: .success)
        } catch {
            responseMessage = ResponseMessage("Stop recording failed: \(error.localizedDescription)", type: .error)
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
