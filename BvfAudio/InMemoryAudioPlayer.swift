import Foundation
import AVFoundation
import AudioToolbox

/// Plays a decrypted recording with no plaintext file on disk and no encoded container
/// handed to a convenience player. The encrypted-then-decrypted AAC buffer is demuxed and
/// decoded to PCM in memory via `ExtAudioFile` over `InMemoryAudioReader` callbacks, then
/// scheduled on an `AVAudioPlayerNode`. The only framework that touches the container is
/// Core Audio's decoder, fed through our read callback: it never receives a file path or a
/// whole `Data` it could spool, so there is no tier-1 write surface (unlike `AVAudioPlayer(data:)`).
///
/// The whole file is decoded to PCM up front (frame-accurate seek, exact duration, and no
/// reliance on random-access into a raw ADTS stream). That trades memory: ~635 MB/hour for
/// mono float32. Acceptable for typical voice recordings; a scaling limit for very long ones.
@MainActor
final class InMemoryAudioPlayer {
    /// Called on the main actor when playback reaches the end of the recording.
    var onPlaybackEnded: (() -> Void)?

    let duration: TimeInterval

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let sampleRate: Double

    /// Decoded PCM, split into ~1 s chunks, with each chunk's absolute start frame.
    private let chunks: [AVAudioPCMBuffer]
    private let startFrames: [AVAudioFramePosition]
    private let totalFrames: AVAudioFramePosition

    /// Absolute frame the currently-scheduled run began at (the node's own clock restarts
    /// from zero on every (re)schedule, so `currentTime` adds this base).
    private var seekBaseFrame: AVAudioFramePosition = 0
    private var scheduled = false
    private var isPlaying = false
    /// Bumped on every (re)schedule so a stale completion handler from a superseded run
    /// (after seek/stop) can't fire the end callback.
    private var generation: UInt64 = 0

    // MARK: - Construction

    /// Decrypted-buffer → player. Decoding runs off the main actor.
    static func make(data: Data) async throws -> InMemoryAudioPlayer {
        let decoded = try await Task.detached(priority: .userInitiated) {
            try decode(data: data)
        }.value
        return try InMemoryAudioPlayer(decoded: decoded)
    }

    private init(decoded: DecodedAudio) throws {
        format = decoded.format
        sampleRate = decoded.sampleRate
        chunks = decoded.chunks
        startFrames = decoded.startFrames
        totalFrames = decoded.totalFrames
        duration = decoded.sampleRate > 0 ? Double(decoded.totalFrames) / decoded.sampleRate : 0

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
    }

    // MARK: - Transport

    func play() {
        if !scheduled { scheduleRun(from: 0) }
        node.play()
        isPlaying = true
    }

    func pause() {
        node.pause()
        isPlaying = false
    }

    func stop() {
        node.stop()
        engine.stop()
        isPlaying = false
        scheduled = false
    }

    func seek(to time: TimeInterval) {
        let wasPlaying = isPlaying
        let frame = AVAudioFramePosition((time * sampleRate).rounded())
        scheduleRun(from: max(0, min(frame, totalFrames)))
        if wasPlaying { node.play() }
    }

    var currentTime: TimeInterval {
        guard let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else {
            return Double(seekBaseFrame) / sampleRate
        }
        let frames = seekBaseFrame + playerTime.sampleTime
        return min(max(Double(frames) / sampleRate, 0), duration)
    }

    // MARK: - Scheduling

    /// (Re)schedule playback starting at an absolute frame. Clears any prior run; the last
    /// buffer carries the end-of-playback completion, guarded by `generation`.
    private func scheduleRun(from frame: AVAudioFramePosition) {
        node.stop()
        generation &+= 1
        let gen = generation
        seekBaseFrame = frame

        // Seek to (or past) the end: nothing to play; leave un-scheduled so the next play()
        // restarts from the top.
        guard frame < totalFrames, !chunks.isEmpty else {
            scheduled = false
            return
        }
        scheduled = true

        let (startIndex, offset) = locate(frame)
        let last = chunks.count - 1

        for i in startIndex...last {
            let buffer: AVAudioPCMBuffer
            if i == startIndex, offset > 0 {
                guard let partial = Self.slice(chunks[i], from: offset) else { continue }
                buffer = partial
            } else {
                buffer = chunks[i]
            }

            if i == last {
                node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.generation == gen else { return }
                        self.isPlaying = false
                        self.scheduled = false
                        self.onPlaybackEnded?()
                    }
                }
            } else {
                node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack, completionHandler: nil)
            }
        }
    }

    /// Largest chunk index whose start frame is <= `frame`, plus the in-chunk offset.
    private func locate(_ frame: AVAudioFramePosition) -> (index: Int, offset: AVAudioFrameCount) {
        var lo = 0, hi = startFrames.count - 1, idx = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if startFrames[mid] <= frame { idx = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return (idx, AVAudioFrameCount(frame - startFrames[idx]))
    }

    /// A copy of `buffer` from `offset` to its end (non-interleaved float32).
    private static func slice(_ buffer: AVAudioPCMBuffer, from offset: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard offset < buffer.frameLength,
              let src = buffer.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength - offset),
              let dst = out.floatChannelData else { return nil }
        let count = Int(buffer.frameLength - offset)
        for ch in 0..<Int(buffer.format.channelCount) {
            memcpy(dst[ch], src[ch].advanced(by: Int(offset)), count * MemoryLayout<Float>.size)
        }
        out.frameLength = buffer.frameLength - offset
        return out
    }

    // MARK: - Decode (off the main actor)

    /// Immutable decode result. `@unchecked Sendable`: the buffers are produced here and only
    /// ever read afterward (never mutated), so handing them to the main actor is safe.
    private nonisolated struct DecodedAudio: @unchecked Sendable {
        let format: AVAudioFormat
        let sampleRate: Double
        let chunks: [AVAudioPCMBuffer]
        let startFrames: [AVAudioFramePosition]
        let totalFrames: AVAudioFramePosition
    }

    private nonisolated static func decode(data: Data) throws -> DecodedAudio {
        let reader = InMemoryAudioReader(data: data)
        let readerPtr = Unmanaged.passRetained(reader).toOpaque()
        defer { Unmanaged<InMemoryAudioReader>.fromOpaque(readerPtr).release() }

        var audioFileID: AudioFileID?
        var status = AudioFileOpenWithCallbacks(
            readerPtr, inMemoryReadProc, nil, inMemoryGetSizeProc, nil, AudioFileTypeID(0), &audioFileID
        )
        guard status == noErr, let fileID = audioFileID else { throw AudioPlayerError.open(status) }
        defer { AudioFileClose(fileID) }

        var extAudioFile: ExtAudioFileRef?
        status = ExtAudioFileWrapAudioFileID(fileID, false, &extAudioFile)
        guard status == noErr, let extFile = extAudioFile else { throw AudioPlayerError.open(status) }
        defer { ExtAudioFileDispose(extFile) }

        var sourceFormat = AudioStreamBasicDescription()
        var propertySize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = ExtAudioFileGetProperty(extFile, kExtAudioFileProperty_FileDataFormat, &propertySize, &sourceFormat)
        guard status == noErr else { throw AudioPlayerError.open(status) }

        let sampleRate = sourceFormat.mSampleRate > 0 ? sourceFormat.mSampleRate : 44100
        let channels = max(1, sourceFormat.mChannelsPerFrame)

        // Client format: deinterleaved float32 at the source rate, AVAudioEngine's native format.
        var clientASBD = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        status = ExtAudioFileSetProperty(
            extFile,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientASBD
        )
        guard status == noErr else { throw AudioPlayerError.open(status) }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels), interleaved: false
        ) else { throw AudioPlayerError.format }

        let chunkCapacity = AVAudioFrameCount(sampleRate)  // ~1 s
        var chunks: [AVAudioPCMBuffer] = []
        var startFrames: [AVAudioFramePosition] = []
        var total: AVAudioFramePosition = 0

        while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkCapacity) else { break }
            buffer.frameLength = chunkCapacity  // makes the buffer list's byte sizes reflect capacity
            var frames = chunkCapacity
            let readStatus = ExtAudioFileRead(extFile, &frames, buffer.mutableAudioBufferList)
            // A read error means a corrupt/truncated tail (e.g. a force-quit recording that
            // never got its final tag): keep everything decoded cleanly and stop.
            if readStatus != noErr { break }
            if frames == 0 { break }
            buffer.frameLength = frames
            startFrames.append(total)
            chunks.append(buffer)
            total += AVAudioFramePosition(frames)
        }

        guard !chunks.isEmpty else { throw AudioPlayerError.empty }
        return DecodedAudio(
            format: format, sampleRate: sampleRate,
            chunks: chunks, startFrames: startFrames, totalFrames: total
        )
    }
}

enum AudioPlayerError: LocalizedError {
    case open(OSStatus)
    case format
    case empty

    var errorDescription: String? {
        switch self {
        case .open(let status): return "Could not decode recording (status \(status))"
        case .format: return "Unsupported audio format"
        case .empty: return "Recording contained no decodable audio"
        }
    }
}
