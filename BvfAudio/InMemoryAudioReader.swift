import Foundation
import AudioToolbox

/// Serves a fully in-memory audio `Data` buffer to Core Audio's file APIs via
/// `AudioFileOpenWithCallbacks`, so an encrypted recording can be demuxed/decoded without
/// ever writing plaintext to disk. Shared by transcription and playback — the only
/// in-process consumer of the decrypted container is Core Audio, and it receives bytes
/// through these callbacks (never a file path), so it has no handle to spool to.
nonisolated final class InMemoryAudioReader {
    let data: Data

    init(data: Data) {
        self.data = data
    }
}

nonisolated let inMemoryReadProc: AudioFile_ReadProc = { inClientData, inPosition, requestCount, buffer, outActualCount in
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

nonisolated let inMemoryGetSizeProc: AudioFile_GetSizeProc = { inClientData in
    let reader = Unmanaged<InMemoryAudioReader>.fromOpaque(inClientData).takeUnretainedValue()
    return Int64(reader.data.count)
}
