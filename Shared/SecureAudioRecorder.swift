import Combine
import Foundation
@preconcurrency import AVFoundation
@preconcurrency import AudioToolbox
import BvfAppKit

private final class EncoderInputContext: @unchecked Sendable {
    nonisolated(unsafe) var bufferList: AudioBufferList
    nonisolated(unsafe) var hasProvided: Bool

    nonisolated init(bufferList: AudioBufferList, hasProvided: Bool) {
        self.bufferList = bufferList
        self.hasProvided = hasProvided
    }
}

private final class InputState: @unchecked Sendable {
    nonisolated(unsafe) var provided = false
}

/// Cross-platform audio recorder that encrypts directly to disk
/// Plaintext audio never touches disk - streams through memory to encrypted file
/// Audited 2026-06-29 (eslogger): no .m4a/.caf/.wav/.aif files written during record→encrypt path.
///
/// Lifecycle:
/// - `prepare()` builds and starts the audio engine; the tap is installed but discards
///   buffers until recording begins. Use to keep the mic warm (instant record start,
///   no Bluetooth SCO negotiation delay).
/// - `start(encryptionContext:)` flips the write flag, resets encoder state, starts
///   the duration timer. Auto-calls `prepare()` if the caller didn't.
/// - `stop()` flips the flag back and finalizes the encryption context. Engine stays
///   running if it was prepared externally; otherwise tears down (preserves the
///   per-recording lifecycle on iOS).
/// - `teardown()` releases the engine and (on iOS) deactivates the audio session.
///
/// Threading model:
/// - Public methods are called from the main thread
/// - Audio tap callback runs on a real-time audio thread, dispatches to `processingQueue`
/// - `processAudioBuffer()`, `encodeToAAC()`, and `pcmAccumulator` access are serialized on `processingQueue`
/// - `stop()` / `teardown()` call `processingQueue.sync {}` to drain pending work before disposing resources
/// - `@Published` properties are updated on MainActor via Task
final class SecureAudioRecorder: ObservableObject, @unchecked Sendable {
    private let processingQueue = DispatchQueue(label: "io.bvf.audio.processing")

    nonisolated(unsafe) private var audioEngine: AVAudioEngine?
    nonisolated(unsafe) private var converter: AVAudioConverter?
    nonisolated(unsafe) private var audioConverter: AudioConverterRef?
    nonisolated(unsafe) private var encryptionContext: PushEncryptionContext?
    nonisolated(unsafe) private var durationTimer: Timer?
    nonisolated(unsafe) private var startTime: Date?

    // PCM accumulation buffer for AAC encoding (needs 1024 frames)
    nonisolated(unsafe) private var pcmAccumulator: [Float] = []
    private let aacFrameSize = 1024

    // Hardware sample rate queried from device
    nonisolated(unsafe) private var hardwareSampleRate: Double = 44100

    // Tap-callback gate: true between start() and stop(), false during keep-warm idle
    nonisolated(unsafe) private var shouldWrite: Bool = false

    // True when prepare() was called externally — stop() will then keep the engine warm
    nonisolated(unsafe) private var isExternallyPrepared: Bool = false

    // Gain multiplier to boost macOS input levels (iOS has automatic gain via AVAudioSession)
    #if os(macOS)
    private let inputGainMultiplier: Float = 1.0
    #else
    private let inputGainMultiplier: Float = 1.0
    #endif

    @Published var isRecording = false
    @Published var isPrepared = false
    @Published var duration: TimeInterval = 0
    @Published var error: Error?

    init() {}

    deinit {
        durationTimer?.invalidate()
        shouldWrite = false
        try? tearDownEngine()
    }

    /// Build and start the audio engine without recording. Use to keep the mic warm so
    /// the first `start(encryptionContext:)` returns instantly (no Bluetooth SCO delay).
    nonisolated func prepare() throws {
        try buildEngine()
        isExternallyPrepared = true
        Task { @MainActor in
            self.isPrepared = true
        }
    }

    /// Stop the audio engine and release the mic. Call when the recording view disappears.
    /// Cleanup failures (e.g. AVAudioSession deactivate on iOS) are ignored — there's no
    /// UI to surface them at view-disappear time.
    nonisolated func teardown() {
        shouldWrite = false
        isExternallyPrepared = false
        try? tearDownEngine()
        Task { @MainActor in
            self.isPrepared = false
        }
    }

    /// Begin writing to the encryption context. If `prepare()` wasn't called, the engine
    /// is built on demand (and torn down in `stop()`).
    nonisolated func start(encryptionContext: PushEncryptionContext) throws {
        // Set context and write flag BEFORE the engine starts emitting buffers so
        // the very first sample is captured.
        self.encryptionContext = encryptionContext

        // Reset encoder state so this recording starts as a fresh AAC stream.
        // Run on processingQueue to serialize with any in-flight processAudioBuffer.
        processingQueue.sync {
            pcmAccumulator.removeAll(keepingCapacity: true)
            converter?.reset()
            if let audioConverter = audioConverter {
                AudioConverterReset(audioConverter)
            }
        }

        shouldWrite = true

        if audioEngine == nil {
            do {
                try buildEngine()
            } catch {
                shouldWrite = false
                self.encryptionContext = nil
                throw error
            }
        }

        let recordStartTime = Date()
        startTime = recordStartTime
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.duration = Date().timeIntervalSince(recordStartTime)
            }
        }

        Task {
            await MainActor.run {
                self.isRecording = true
            }
        }
    }

    /// Stop writing and finalize the encryption stream. Engine stays warm if prepared
    /// externally; otherwise torn down (and on iOS the audio session is deactivated —
    /// any failure to deactivate is propagated).
    nonisolated func stop() throws {
        shouldWrite = false

        durationTimer?.invalidate()
        durationTimer = nil

        // Drain pending tap-callback work before finalizing the encryption stream
        processingQueue.sync { }

        try encryptionContext?.finish()
        encryptionContext = nil

        Task {
            await MainActor.run {
                self.isRecording = false
                self.duration = 0
            }
        }

        if !isExternallyPrepared {
            try tearDownEngine()
        }
    }

    nonisolated private func buildEngine() throws {
        guard audioEngine == nil else { return }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP]
        if #available(iOS 26, *) {
            options.insert(.bluetoothHighQualityRecording)
        }
        try session.setCategory(.record, mode: .default, options: options)
        try session.setActive(true)
        hardwareSampleRate = session.sampleRate
        #endif

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        #if os(macOS)
        hardwareSampleRate = inputFormat.sampleRate
        #endif

        guard SecureAudioRecorder.adtsSampleRates.contains(Int(hardwareSampleRate)) else {
            throw RecorderError.unsupportedSampleRate(hardwareSampleRate)
        }

        guard let aacFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: hardwareSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.formatCreationFailed
        }

        guard let conv = AVAudioConverter(from: inputFormat, to: aacFormat) else {
            throw RecorderError.converterCreationFailed
        }
        converter = conv

        var inputASBD = AudioStreamBasicDescription(
            mSampleRate: hardwareSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var outputASBD = AudioStreamBasicDescription(
            mSampleRate: hardwareSampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,  // Variable bitrate
            mFramesPerPacket: 1024,  // AAC frame size
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        var converterRef: AudioConverterRef?
        let status = AudioConverterNew(&inputASBD, &outputASBD, &converterRef)
        guard status == noErr, let converterRef = converterRef else {
            throw RecorderError.audioConverterCreationFailed
        }
        audioConverter = converterRef

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
    }

    nonisolated private func tearDownEngine() throws {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        // Drain any in-flight tap work before disposing the encoder
        processingQueue.sync { }

        if let audioConverter = audioConverter {
            AudioConverterDispose(audioConverter)
            self.audioConverter = nil
        }
        converter = nil
        pcmAccumulator = []

        #if os(iOS)
        try AVAudioSession.sharedInstance().setActive(false)
        #endif
    }

    nonisolated private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter = converter,
              let encryptionContext = encryptionContext else { return }

        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: buffer.frameLength
        ) else { return }

        var error: NSError?
        let inputState = InputState()
        converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            guard !inputState.provided else {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputState.provided = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error = error {
            Task { @MainActor in self.error = error }
            return
        }

        guard let aacData = encodeToAAC(convertedBuffer) else { return }

        do {
            try encryptionContext.write(aacData)
        } catch {
            Task { @MainActor in self.error = error }
        }
    }

    nonisolated private func encodeToAAC(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let channelData = buffer.floatChannelData,
              let converter = audioConverter else { return nil }

        let frameLength = Int(buffer.frameLength)

        // mono, channel 0 only
        var samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))

        // boosts macOS levels which are lower than iOS
        if inputGainMultiplier != 1.0 {
            for i in 0..<samples.count {
                samples[i] = min(max(samples[i] * inputGainMultiplier, -1.0), 1.0)
            }
        }

        pcmAccumulator.append(contentsOf: samples)

        guard pcmAccumulator.count >= aacFrameSize else { return nil }

        var allEncodedData = Data()

        while pcmAccumulator.count >= aacFrameSize {
            let inputFrames = aacFrameSize
            let channelBuffer = Array(pcmAccumulator.prefix(inputFrames))
            pcmAccumulator.removeFirst(inputFrames)

            // max AAC frame is ~768 bytes for mono
            let maxOutputSize = 768
            var outputData = Data(count: maxOutputSize)
            var outputBuffer = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(maxOutputSize),
                    mData: nil
                )
            )

            // Pin channelBuffer memory for entire encoding operation
            let encodedData = channelBuffer.withUnsafeBytes { (inputPtr: UnsafeRawBufferPointer) -> Data? in
                // Create context manually to avoid MainActor isolation on struct initializer
                let inputContext = EncoderInputContext(
                    bufferList: .init(
                        mNumberBuffers: 1,
                        mBuffers: .init(
                            mNumberChannels: 1,
                            mDataByteSize: UInt32(inputFrames * MemoryLayout<Float>.size),
                            mData: UnsafeMutableRawPointer(mutating: inputPtr.baseAddress)
                        )
                    ),
                    hasProvided: false
                )
                let contextPtr = Unmanaged.passUnretained(inputContext).toOpaque()

                return outputData.withUnsafeMutableBytes { (outputBytes: UnsafeMutableRawBufferPointer) -> Data? in
                    outputBuffer.mBuffers.mData = outputBytes.baseAddress

                    var ioOutputDataPacketSize: UInt32 = 1
                    var outPacketDescription = AudioStreamPacketDescription()

                    let status = AudioConverterFillComplexBuffer(
                        converter,
                        { _, ioNumberDataPackets, ioData, _, inUserData in
                            let context = Unmanaged<EncoderInputContext>.fromOpaque(inUserData!).takeUnretainedValue()

                            guard !context.hasProvided else {
                                ioNumberDataPackets.pointee = 0
                                return 561015674  // kAudioConverterErr_NoDataNow
                            }

                            ioData.pointee = context.bufferList
                            ioNumberDataPackets.pointee = 1024
                            context.hasProvided = true
                            return noErr
                        },
                        contextPtr,
                        &ioOutputDataPacketSize,
                        &outputBuffer,
                        &outPacketDescription
                    )

                    guard status == noErr, ioOutputDataPacketSize > 0 else {
                        return nil
                    }

                    let actualSize = Int(outputBuffer.mBuffers.mDataByteSize)
                    return Data(bytes: outputBytes.baseAddress!, count: actualSize)
                }
            }

            guard let aacFrame = encodedData else { continue }

            let adtsFrame = SecureAudioRecorder.addADTSHeader(to: aacFrame, sampleRate: Int(hardwareSampleRate), channels: 1)
            allEncodedData.append(adtsFrame)
        }

        return allEncodedData.isEmpty ? nil : allEncodedData
    }

    nonisolated static func addADTSHeader(to data: Data, sampleRate: Int, channels: Int) -> Data {
        // ADTS header (7 bytes)
        var header = Data(count: 7)

        // Sync word (0xFFF)
        header[0] = 0xFF
        header[1] = 0xF1  // MPEG-4, no CRC

        // Profile (AAC LC = 1), sample rate index, channel config
        let sampleRateIndex = SecureAudioRecorder.getSampleRateIndex(sampleRate)
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
            // Guarded against in buildEngine; reaching this means the invariant was bypassed.
            preconditionFailure("ADTS sample rate \(sampleRate) not in supported table")
        }
        return idx
    }
}

enum RecorderError: LocalizedError {
    case formatCreationFailed
    case converterCreationFailed
    case audioConverterCreationFailed
    case unsupportedSampleRate(Double)

    var errorDescription: String? {
        switch self {
        case .formatCreationFailed:
            return "Failed to create audio format"
        case .converterCreationFailed:
            return "Failed to create audio converter"
        case .audioConverterCreationFailed:
            return "Failed to create AudioToolbox converter"
        case .unsupportedSampleRate(let rate):
            return "Unsupported hardware sample rate: \(Int(rate)) Hz"
        }
    }
}
