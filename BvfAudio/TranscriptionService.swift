import Speech
import AVFoundation
import AudioToolbox

private final class InMemoryAudioReader {
    let data: Data

    init(data: Data) {
        self.data = data
    }
}

private let inMemoryReadProc: AudioFile_ReadProc = { inClientData, inPosition, requestCount, buffer, outActualCount in
    let reader = Unmanaged<InMemoryAudioReader>.fromOpaque(inClientData).takeUnretainedValue()
    let position = Int(inPosition)
    let count = Int(requestCount)

    guard position >= 0, position < reader.data.count else {
        outActualCount.pointee = 0
        return noErr
    }

    let availableBytes = reader.data.count - position
    let bytesToRead = min(count, availableBytes)

    reader.data.withUnsafeBytes { bytes in
        let sourcePtr = bytes.baseAddress!.advanced(by: position)
        buffer.copyMemory(from: sourcePtr, byteCount: bytesToRead)
    }

    outActualCount.pointee = UInt32(bytesToRead)
    return noErr
}

private let inMemoryGetSizeProc: AudioFile_GetSizeProc = { inClientData in
    let reader = Unmanaged<InMemoryAudioReader>.fromOpaque(inClientData).takeUnretainedValue()
    return Int64(reader.data.count)
}

final class TranscriptionService {
    func transcribe(audioData: Data) async throws -> String {
        let locale = Locale(identifier: "en-US")
        let preset = SpeechTranscriber.Preset(
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        let transcriber = SpeechTranscriber(locale: locale, preset: preset)

        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await downloader.downloadAndInstall()
        }

        let reader = InMemoryAudioReader(data: audioData)
        let readerPtr = Unmanaged.passRetained(reader).toOpaque()
        defer { Unmanaged<InMemoryAudioReader>.fromOpaque(readerPtr).release() }

        var audioFileID: AudioFileID?
        var status = AudioFileOpenWithCallbacks(
            readerPtr,
            inMemoryReadProc,
            nil,
            inMemoryGetSizeProc,
            nil,
            AudioFileTypeID(0),
            &audioFileID
        )
        guard status == noErr, let fileID = audioFileID else {
            throw TranscriptionError.fileError(NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
        }
        defer { AudioFileClose(fileID) }

        var extAudioFile: ExtAudioFileRef?
        status = ExtAudioFileWrapAudioFileID(fileID, false, &extAudioFile)
        guard status == noErr, let extFile = extAudioFile else {
            throw TranscriptionError.fileError(NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
        }
        defer { ExtAudioFileDispose(extFile) }

        var sourceFormat = AudioStreamBasicDescription()
        var propertySize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = ExtAudioFileGetProperty(
            extFile,
            kExtAudioFileProperty_FileDataFormat,
            &propertySize,
            &sourceFormat
        )
        guard status == noErr else {
            throw TranscriptionError.fileError(NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
        }

        // Set client format: 16kHz int16 PCM (required by SpeechAnalyzer)
        let channels = sourceFormat.mChannelsPerFrame
        let targetSampleRate: Float64 = 16000.0
        var clientASBD = AudioStreamBasicDescription(
            mSampleRate: targetSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        status = ExtAudioFileSetProperty(
            extFile,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientASBD
        )
        guard status == noErr else {
            throw TranscriptionError.fileError(NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
        }

        let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: true
        )!

        let (inputStream, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        Task { try await analyzer.start(inputSequence: inputStream) }

        // Consume results concurrently to avoid backpressure deadlock
        let resultTask = Task {
            var r = ""
            for try await response in transcriber.results {
                if response.isFinal {
                    r.append(response.text.description)
                }
            }
            return r
        }

        ExtAudioFileSeek(extFile, 0)
        let bufferFrameCapacity: UInt32 = 4096
        let bytesPerFrame = Int(clientASBD.mBytesPerFrame)
        let readBufSize = Int(bufferFrameCapacity) * bytesPerFrame
        var totalFramesFed: UInt32 = 0

        while true {
            var readData = Data(count: readBufSize)
            var frameCount = bufferFrameCapacity
            var abl = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: clientASBD.mChannelsPerFrame,
                    mDataByteSize: UInt32(readBufSize),
                    mData: nil
                )
            )
            status = readData.withUnsafeMutableBytes { ptr -> OSStatus in
                abl.mBuffers.mData = ptr.baseAddress
                return ExtAudioFileRead(extFile, &frameCount, &abl)
            }
            guard status == noErr else {
                throw TranscriptionError.fileError(NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
            }
            if frameCount == 0 { break }

            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount) else {
                throw TranscriptionError.fileError(NSError(domain: "TranscriptionService", code: -1))
            }
            pcmBuffer.frameLength = frameCount
            let byteCount = Int(frameCount) * bytesPerFrame
            memcpy(pcmBuffer.mutableAudioBufferList.pointee.mBuffers.mData,
                   readData.withUnsafeBytes { $0.baseAddress! },
                   byteCount)

            totalFramesFed += frameCount
            inputBuilder.yield(AnalyzerInput(buffer: pcmBuffer))
        }

        inputBuilder.finish()

        if totalFramesFed == 0 {
            resultTask.cancel()
            return ""
        }

        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await resultTask.value
    }
}

enum TranscriptionError: LocalizedError {
    case notSupported
    case notAuthorized
    case recognitionFailed(Error)
    case fileError(Error)
    case invalidPublicKey

    var errorDescription: String? {
        switch self {
        case .notSupported:
            return "On-device speech recognition is not supported on this device or locale"
        case .notAuthorized:
            return "Speech recognition permission not granted"
        case .recognitionFailed(let error):
            return "Transcription failed: \(error.localizedDescription)"
        case .fileError(let error):
            return "File operation failed: \(error.localizedDescription)"
        case .invalidPublicKey:
            return "Invalid public key format"
        }
    }
}
