import Combine
import Foundation
@preconcurrency import AVFoundation
import UserNotifications
import os

/// Watch-local recorder: AVAudioEngine input tap -> AVAudioConverter (PCM -> AAC) ->
/// ADTS framing -> WatchCiphertextWriter (BvfKit encryption). The ONLY audio artifact
/// this ever writes to disk is the encrypted outbox file — no plaintext .aac/.pcm/.caf/
/// .wav ever touches storage.
///
/// AAC encoding uses AVFoundation's `AVAudioConverter`: AudioToolbox's C converter
/// (AudioConverterRef / AudioConverterNew / AudioConverterFillComplexBuffer) does not
/// exist on watchOS, but `AVAudioConverter` produces compressed AAC output directly.
///
/// The recipient public key is supplied per-call to `start(recipientPublicKey:)`,
/// sourced from `WatchConnectivityManager` (provisioned from the iPhone via WCSession
/// application context). Callers gate the record affordance on a key being present;
/// `start` still throws defensively if called without one.
final class WatchAudioRecorder: ObservableObject, @unchecked Sendable {
    enum Status: Equatable {
        case idle
        case recording
        case encoderUnavailable
        /// Auto-stopped by an `AVAudioSession` interruption (e.g. an alarm). watchOS
        /// cannot resume a backgrounded recording after an interruption, so the
        /// decision is to finalize immediately rather than lie about still recording —
        /// this state exists so the UI can show why it stopped instead of either a
        /// frozen "recording" screen or a silent, unexplained return to idle.
        case interrupted
    }

    private let processingQueue = DispatchQueue(label: "io.bvf.audio.watch.processing")

    nonisolated(unsafe) private var audioEngine: AVAudioEngine?
    nonisolated(unsafe) private var aacConverter: AVAudioConverter?
    nonisolated(unsafe) private var ciphertextWriter: WatchCiphertextWriter?
    nonisolated(unsafe) private var durationTimer: Timer?
    nonisolated(unsafe) private var shouldWrite = false
    nonisolated(unsafe) private var interruptionObserver: NSObjectProtocol?
    nonisolated(unsafe) private var routeChangeObserver: NSObjectProtocol?

    /// Input port UIDs captured once the recording's audio route has settled (in
    /// `buildEngine`). The route-change observer compares the live input against THIS
    /// baseline, not against the notification's previous route — otherwise the
    /// route change emitted when the `.record` session first activates (previous
    /// route -> record input) reads as an input change and auto-stops the recording
    /// the instant it starts.
    nonisolated(unsafe) private var recordingInputUIDs: Set<String> = []

    /// Guards `finalize(interrupted:)` against concurrent/double invocation. `stop()`
    /// runs on the main actor while the interruption observer fires on AVAudioSession's
    /// internal thread, so the "already finalizing?" check-and-set MUST be atomic — a
    /// plain Bool would let both callers pass the guard and run `finish()` concurrently
    /// on the same unsynchronized `WatchCiphertextWriter`, a data race that could corrupt
    /// the secretstream state or file handle. The flag lives inside the lock so it can't
    /// be touched unsynchronized. Reset to false in `start()`.
    private let finalizeGuard = OSAllocatedUnfairLock(initialState: false)

    @Published var isRecording = false
    @Published var duration: TimeInterval = 0
    @Published var error: Error?
    @Published var outboxFileURL: URL?
    @Published var status: Status = .idle
    /// Set when `status` becomes `.interrupted`, for the UI to display; cleared when a
    /// new recording starts.
    @Published var interruptionMessage: String?

    private final class InputState: @unchecked Sendable {
        nonisolated(unsafe) var provided = false
    }

    init() {}

    deinit {
        durationTimer?.invalidate()
        shouldWrite = false
        try? tearDownEngine()
    }

    /// - Parameter recipientPublicKey: `bvf-pub:` format string. Callers must ensure
    ///   this is non-nil (i.e. gate the record UI on a provisioned key) before calling;
    ///   this throws `WatchAudioRecorderError.noRecipientKey` as a defensive fallback.
    nonisolated func start(recipientPublicKey: String?) throws {
        guard let recipientPublicKey, !recipientPublicKey.isEmpty else {
            throw WatchAudioRecorderError.noRecipientKey
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)

        // Everything from here creates hot state (an open ciphertext handle, `shouldWrite`,
        // an engine/observers). If any step throws — e.g. `buildEngine()` on
        // encoderUnavailable/unsupportedSampleRate — unwind it all so nothing is left
        // running: otherwise the session stays active, `shouldWrite` stays true, and a
        // header-only `.bvf.part` is orphaned on disk.
        let writer: WatchCiphertextWriter
        do {
            writer = try WatchCiphertextWriter(recipientPublicKey: recipientPublicKey)
            ciphertextWriter = writer

            shouldWrite = true
            finalizeGuard.withLock { $0 = false }

            try buildEngine()
        } catch {
            // `buildEngine()` sets `status` on its own failure paths, so the UI reason is
            // preserved; discard() closes the handle and deletes the header-only `.part`.
            shouldWrite = false
            ciphertextWriter?.discard()
            ciphertextWriter = nil
            try? tearDownEngine()
            try? session.setActive(false)
            throw error
        }

        Task { @MainActor in self.outboxFileURL = writer.outputURL }

        let recordStartTime = Date()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.duration = Date().timeIntervalSince(recordStartTime)
            }
        }

        Task { @MainActor in
            self.error = nil
            self.interruptionMessage = nil
            self.isRecording = true
            self.status = .recording
        }
    }

    /// User-initiated stop. Runs the same finalize path an interruption uses; see
    /// `finalize(interrupted:)`.
    nonisolated func stop() {
        finalize(interrupted: false)
    }

    /// Shared finalize path for both a user-tapped stop and an auto-stop triggered by
    /// an `AVAudioSession` interruption (e.g. an alarm) — watchOS cannot resume a
    /// backgrounded recording after an interruption, so both cases end the recording
    /// the same way: stop writing, drain, finish the ciphertext (preserving whatever
    /// audio was captured up to this point), tear down, and reconcile so the file
    /// delivers. `interrupted` only changes what's reported to the UI afterward.
    ///
    /// Single-entry via `finalizeGuard`: an interruption and a racing user stop() run on
    /// different threads, so the check-and-set is atomic — exactly one caller runs the
    /// body and the other returns immediately.
    ///
    /// Non-throwing: teardown and the UI reset to idle ALWAYS run, even if
    /// `ciphertextWriter.finish()` fails (e.g. disk full on the final write). A throw
    /// escaping here would otherwise leave the engine running, the mic hot, and the UI
    /// wedged on "recording". On a finish() failure the `.bvf.part` is left on disk;
    /// `recoverOrphanedParts()` promotes and delivers it (truncated) on the next launch,
    /// and the failure is surfaced to the UI via `error`.
    nonisolated private func finalize(interrupted: Bool) {
        let shouldProceed = finalizeGuard.withLock { alreadyFinalizing -> Bool in
            if alreadyFinalizing { return false }
            alreadyFinalizing = true
            return true
        }
        guard shouldProceed else { return }

        shouldWrite = false

        durationTimer?.invalidate()
        durationTimer = nil

        // finish() can throw (e.g. disk full on the final write), but the teardown and
        // UI reset below MUST still run — so capture the outcome instead of letting it
        // propagate. On failure the `.bvf.part` stays on disk for next-launch recovery.
        //
        // Run finish() + the writer nil-out ON processingQueue so they serialize (FIFO)
        // after the last in-flight processAudioBuffer write. The tap is still installed at
        // this point (it's removed later, in tearDownEngine), so a callback that slips
        // past `shouldWrite` and enqueues after the drain above would otherwise run
        // write() concurrently with finish() on the same unsynchronized
        // WatchCiphertextWriter state. On the queue, such a late callback instead sees a
        // nil writer (via processAudioBuffer's `guard let writer`) and no-ops. Mirrors
        // SecureAudioRecorder.stop() and SecureVideoRecorder.finishEncryptionSync().
        var finishedURL: URL?
        var finishError: Error?
        processingQueue.sync {
            do {
                finishedURL = try ciphertextWriter?.finish()
            } catch {
                finishError = error
            }
            ciphertextWriter = nil
        }

        try? tearDownEngine()

        if interrupted {
            // Posted only on the interruption path, never on a normal user-tapped stop,
            // and posted even if finish() failed so the user still learns the recording
            // stopped. The audio session is still "active" at this point in the
            // interruption delegate's execution window, so the process has enough
            // background execution left to schedule this — the system then delivers the
            // banner+haptic even if the app is currently backgrounded (wrist down).
            WatchAudioRecorder.postInterruptionNotification()
        }

        Task { @MainActor in
            self.isRecording = false
            self.duration = 0
            self.status = interrupted ? .interrupted : .idle
            self.interruptionMessage = interrupted ? "Recording interrupted" : nil
            if let finishError {
                self.error = finishError
            } else if let finishedURL {
                self.outboxFileURL = finishedURL
                // Trigger delivery immediately after a recording lands in the outbox,
                // rather than waiting for the next activation/reachability/foreground
                // trigger.
                WatchOutboxReconciler.shared.reconcile()
                // Skipped when interrupted — INTERRUPTED is the badge then; the file
                // still delivers via the reconcile above.
                if !interrupted,
                   let parsed = WatchOutboxReconciler.parseOutboxFilename(finishedURL.lastPathComponent) {
                    WatchConnectivityManager.shared.markSending(uuid: parsed.uuid)
                }
            }
        }
    }

    /// Posts an immediate local notification so the user finds out a recording was
    /// auto-stopped even while the app is backgrounded (wrist down) — a haptic alone
    /// (e.g. via WKInterfaceDevice) is unreliable in the background, but a local
    /// notification is delivered by the system regardless of foreground state.
    /// `UNUserNotificationCenter.add` is thread-safe, so this is callable from the
    /// nonisolated interruption-observer callback without hopping to the main actor.
    /// No delegate is registered: the default behavior (banner+haptic when
    /// backgrounded, suppressed when foregrounded) is exactly what's wanted here,
    /// since the foreground case already shows the `.interrupted` UI state.
    nonisolated private static func postInterruptionNotification() {
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

    nonisolated private func buildEngine() throws {
        guard audioEngine == nil else { return }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let converter = WatchAudioRecorder.makeAACConverter(from: inputFormat, sampleRate: inputFormat.sampleRate) else {
            Task { @MainActor in self.status = .encoderUnavailable }
            throw WatchAudioRecorderError.encoderUnavailable
        }

        // Validate up front: the ADTS header can only encode rates in this table. If the
        // AAC bitstream's actual rate isn't one of them, fail loudly now rather than
        // writing a header that disagrees with the data — a mismatch plays back at
        // grossly wrong speed.
        guard WatchAudioRecorder.adtsSampleRates.contains(Int(converter.outputFormat.sampleRate)) else {
            Task { @MainActor in self.status = .encoderUnavailable }
            throw WatchAudioRecorderError.unsupportedSampleRate(converter.outputFormat.sampleRate)
        }

        aacConverter = converter

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self, self.shouldWrite else { return }
            guard let bufferCopy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
            bufferCopy.frameLength = buffer.frameLength
            if let src = buffer.floatChannelData, let dst = bufferCopy.floatChannelData {
                for ch in 0..<Int(buffer.format.channelCount) {
                    memcpy(dst[ch], src[ch], Int(buffer.frameLength) * MemoryLayout<Float>.size)
                }
            }
            self.processingQueue.async {
                self.processAudioBuffer(bufferCopy)
            }
        }

        try engine.start()
        audioEngine = engine

        // Baseline the input the recording actually started on, now that the session
        // is active and the route has settled. The route-change observer compares
        // against this.
        recordingInputUIDs = Set(AVAudioSession.sharedInstance().currentRoute.inputs.map(\.uid))

        registerInterruptionObserver()
        registerRouteChangeObserver()
    }

    /// Observes `AVAudioSession.interruptionNotification` only while a recording is
    /// active (registered here in `buildEngine`, removed in `tearDownEngine`). On
    /// `.began`, auto-stops and finalizes — watchOS cannot resume a backgrounded
    /// recording after an interruption (e.g. an alarm), so the alternative is
    /// capture silently stopping while the UI keeps showing "recording" with a
    /// climbing wall-clock timer. `.ended` is deliberately ignored — no resume
    /// is attempted.
    nonisolated private func registerInterruptionObserver() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            guard let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue),
                  type == .began else {
                return
            }
            self.finalize(interrupted: true)
        }
    }

    nonisolated private func removeInterruptionObserver() {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        interruptionObserver = nil
    }

    /// Observes `AVAudioSession.routeChangeNotification` only while a recording is
    /// active (registered here in `buildEngine`, removed in `tearDownEngine`). A
    /// mid-recording input change (e.g. AirPods connecting) invalidates the
    /// fixed-rate `AVAudioConverter`/tap built in `buildEngine` for the prior input's
    /// format, and watchOS can't seamlessly rebuild and continue — so this auto-stops
    /// and finalizes exactly like an interruption. A "real" input change is detected
    /// by comparing the live input UIDs against `recordingInputUIDs` (the input the
    /// recording started on) rather than trusting the reason code — this is
    /// reason-agnostic and, crucially, does not false-trigger on the route change
    /// emitted when the `.record` session first activates, because by then the live
    /// input already equals the baseline.
    nonisolated private func registerRouteChangeObserver() {
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            let currentInputs = Set(AVAudioSession.sharedInstance().currentRoute.inputs.map(\.uid))
            guard currentInputs != self.recordingInputUIDs else { return }
            self.finalize(interrupted: true)
        }
    }

    nonisolated private func removeRouteChangeObserver() {
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
        routeChangeObserver = nil
    }

    nonisolated private static func makeAACConverter(from inputFormat: AVAudioFormat, sampleRate: Double) -> AVAudioConverter? {
        var aacASBD = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let aacFormat = AVAudioFormat(streamDescription: &aacASBD) else { return nil }
        return AVAudioConverter(from: inputFormat, to: aacFormat)
    }

    nonisolated private func tearDownEngine() throws {
        removeInterruptionObserver()
        removeRouteChangeObserver()

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        processingQueue.sync {}

        aacConverter = nil

        try AVAudioSession.sharedInstance().setActive(false)
    }

    nonisolated private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let aacConverter = aacConverter,
              let writer = ciphertextWriter,
              let aacData = encodeToAAC(buffer, converter: aacConverter),
              !aacData.isEmpty else { return }

        do {
            try writer.write(aacData)
        } catch {
            Task { @MainActor in self.error = error }
        }
    }

    /// One AVAudioConverter PCM -> AAC conversion, ADTS-framed. Returns nil on any
    /// error or when the converter yields no compressed bytes for this buffer.
    ///
    /// A single `convert()` call can emit MULTIPLE AAC packets into `outputBuffer`
    /// (packetCapacity is 8) — each packet is exactly 1024 samples and needs its OWN
    /// 7-byte ADTS header; wrapping the whole multi-packet buffer in a single header
    /// produces a frame-length that only covers the first packet, so decoders sync on
    /// packet 1 and silently drop the rest. `packetDescriptions` gives each packet's
    /// offset/size within `outputBuffer.data` so they can be sliced and ADTS-wrapped
    /// individually.
    nonisolated private func encodeToAAC(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) -> Data? {
        let outputBuffer = AVAudioCompressedBuffer(
            format: converter.outputFormat,
            packetCapacity: 8,
            maximumPacketSize: 768
        )

        var error: NSError?
        let inputState = InputState()
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            guard !inputState.provided else {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputState.provided = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard error == nil, status != .error, outputBuffer.byteLength > 0 else { return nil }

        let packetCount = Int(outputBuffer.packetCount)
        guard packetCount > 0 else { return nil }

        let sampleRate = Int(converter.outputFormat.sampleRate)
        let sourceData = Data(bytes: outputBuffer.data, count: Int(outputBuffer.byteLength))

        guard packetCount > 1, let descriptions = outputBuffer.packetDescriptions else {
            // Single packet (or no per-packet descriptions available, which AAC/VBR
            // should always provide when packetCount > 1) — wrap the whole buffer as
            // one ADTS frame. Correct whenever packetCount == 1.
            return WatchAudioRecorder.addADTSHeader(to: sourceData, sampleRate: sampleRate, channels: 1)
        }

        var result = Data()
        for i in 0..<packetCount {
            let desc = descriptions[i]
            let offset = Int(desc.mStartOffset)
            let size = Int(desc.mDataByteSize)
            guard offset >= 0, size > 0, offset + size <= sourceData.count else { continue }

            let packetBytes = sourceData.subdata(in: offset..<(offset + size))
            result.append(WatchAudioRecorder.addADTSHeader(to: packetBytes, sampleRate: sampleRate, channels: 1))
        }

        return result.isEmpty ? nil : result
    }

    nonisolated static func addADTSHeader(to data: Data, sampleRate: Int, channels: Int) -> Data {
        var header = Data(count: 7)

        header[0] = 0xFF
        header[1] = 0xF1

        let sampleRateIndex = WatchAudioRecorder.getSampleRateIndex(sampleRate)
        header[2] = UInt8((1 << 6) | (sampleRateIndex << 2) | (channels >> 2))
        header[3] = UInt8((channels & 0x3) << 6)

        let frameLength = 7 + data.count
        header[3] |= UInt8((frameLength >> 11) & 0x3)
        header[4] = UInt8((frameLength >> 3) & 0xFF)
        header[5] = UInt8((frameLength & 0x7) << 5) | 0x1F
        header[6] = 0xFC

        var result = header
        result.append(data)
        return result
    }

    nonisolated static let adtsSampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    nonisolated static func getSampleRateIndex(_ sampleRate: Int) -> Int {
        guard let idx = adtsSampleRates.firstIndex(of: sampleRate) else {
            // Unreachable: buildEngine validates converter.outputFormat.sampleRate
            // against adtsSampleRates before recording starts and throws
            // unsupportedSampleRate if it isn't in the table, so encodeToAAC can never
            // reach this function with an unrecognized rate. Crashing here surfaces a
            // real sample-rate mismatch rather than silently writing a wrong ADTS header.
            preconditionFailure("ADTS sample rate \(sampleRate) not in supported table — should have been rejected in buildEngine.")
        }
        return idx
    }
}

enum WatchAudioRecorderError: LocalizedError {
    case encoderUnavailable
    case noRecipientKey
    case unsupportedSampleRate(Double)

    var errorDescription: String? {
        switch self {
        case .encoderUnavailable:
            return "AAC encoder unavailable on this device (AVAudioConverter could not produce a compressed-output converter)"
        case .noRecipientKey:
            return "No recipient public key provisioned yet. Reopen BvfAudio on iPhone to set up."
        case .unsupportedSampleRate(let rate):
            return "AAC encoder produced an unsupported sample rate (\(Int(rate)) Hz) that cannot be represented in an ADTS header."
        }
    }
}
