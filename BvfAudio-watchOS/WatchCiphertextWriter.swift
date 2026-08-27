import Foundation
import BvfKit

/// Watch-local streaming ciphertext writer. Modeled on BvfAppKit's
/// `PushEncryptionContext`, but WITHOUT the iCloud staging/commit step — this writes
/// directly to a persistent `Outbox/` directory in the watch app's container. Transfer
/// of the outbox file to the phone/host is handled by WCSession; this type only
/// guarantees that ciphertext, and only ciphertext, lands on disk.
///
/// BvfKit encryption, watch-local only: no BvfAppKit, no PushEncryptionContext, no iCloud.
///
/// Writes go to a `.bvf.part` path during recording, not the final `.bvf`
/// name, and `finish()` atomically renames to `.bvf` only after the file handle is
/// closed. `WatchOutboxReconciler.reconcile()` filters to `pathExtension == "bvf"`, so
/// an in-progress recording is invisible to it — previously, a reconcile trigger firing
/// mid-recording (e.g. a reachability change) could `transferFile` the file as it stood
/// at that instant, and per-uuid dedup would then permanently block the real, complete
/// file from ever being sent (truncated/header-only delivery). A `.part` left behind by
/// a process killed before `finish()` renames it (crash, OOM, reboot) is recovered on
/// the next launch by `WatchOutboxReconciler.recoverOrphanedParts()` — promoted to a
/// deliverable `.bvf` if any audio chunk was flushed, or deleted if it's header-only.
final class WatchCiphertextWriter: @unchecked Sendable {
    private let outputHandle: FileHandle
    private let encryptionState: EncryptionState
    nonisolated(unsafe) private var buffer = Data()

    /// Path currently being written to (the `.bvf.part` in-progress file).
    private let inProgressURL: URL

    /// Final `.bvf` path this will become once `finish()` renames it. Published to the
    /// recorder/UI immediately so callers can display the eventual filename, but the
    /// file at this path does not exist until `finish()` returns.
    let outputURL: URL

    /// Starts a new encryption session to `recipientPublicKey` and opens a fresh
    /// `.bvf.part` outbox file, writing the HPKE + secretstream header immediately.
    ///
    /// - Parameter recipientPublicKey: `bvf-pub:` format string.
    nonisolated init(recipientPublicKey: String) throws {
        let encrypter = try Encrypter(recipientPublicKey: recipientPublicKey)
        let (header, state) = try encrypter.start()
        self.encryptionState = state

        let outputURL = WatchCiphertextWriter.makeOutboxFileURL()
        self.outputURL = outputURL
        let inProgressURL = outputURL.appendingPathExtension("part")
        self.inProgressURL = inProgressURL

        try FileManager.default.createDirectory(
            at: inProgressURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: inProgressURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: inProgressURL)
        try outputHandle.write(contentsOf: header)
        self.outputHandle = outputHandle
    }

    /// Append plaintext bytes; flushes an encrypted `BvfConfig.plaintextChunkSize`
    /// chunk to disk each time the internal buffer fills. No plaintext is written to
    /// disk at any point — only ciphertext ever reaches `outputHandle`.
    nonisolated func write(_ data: Data) throws {
        buffer.append(data)

        while buffer.count >= BvfConfig.plaintextChunkSize {
            let chunk = buffer.prefix(BvfConfig.plaintextChunkSize)
            buffer = buffer.dropFirst(BvfConfig.plaintextChunkSize)

            let encrypted = try encryptionState.encryptChunk(Data(chunk), isLast: false)
            try outputHandle.write(contentsOf: encrypted)
        }
    }

    /// Flushes the remaining buffer as the final (TAG_FINAL) chunk, zeroes the
    /// buffer's tail, closes the file handle, then atomically renames the completed
    /// `.bvf.part` file to its final `.bvf` name — only after this rename is the file
    /// visible to `WatchOutboxReconciler` (which filters to `pathExtension == "bvf"`)
    /// and therefore eligible for transfer. Returns the final `.bvf` URL.
    @discardableResult
    nonisolated func finish() throws -> URL {
        defer { Self.zero(&buffer) }

        let encrypted = try encryptionState.encryptChunk(buffer, isLast: true)
        try outputHandle.write(contentsOf: encrypted)
        try outputHandle.close()

        // FileManager.moveItem within the same directory is an atomic rename — the
        // file is never observable in a partially-renamed state.
        try FileManager.default.moveItem(at: inProgressURL, to: outputURL)

        return outputURL
    }

    /// Aborts an in-progress recording that never really got going (e.g. `start()` threw
    /// after the writer was created): closes the handle and removes the `.bvf.part` file
    /// so no orphan is left for `recoverOrphanedParts()` to sweep later. Only ciphertext
    /// ever reached disk, so there is nothing to zero beyond the in-memory buffer, which
    /// deinit handles once the caller drops its reference.
    nonisolated func discard() {
        try? outputHandle.close()
        try? FileManager.default.removeItem(at: inProgressURL)
    }

    deinit {
        Self.zero(&buffer)
        try? outputHandle.close()
    }

    nonisolated private static func zero(_ data: inout Data) {
        data.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress, ptr.count > 0 else { return }
            _ = memset_s(base, ptr.count, 0, ptr.count)
        }
    }

    /// Persistent outbox directory in the app container (Documents/Outbox). Files here
    /// survive app relaunch; `WatchOutboxReconciler` drains this directory via WCSession.
    nonisolated static var outboxDirectoryURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Outbox", isDirectory: true)
    }

    nonisolated private static func makeOutboxFileURL() -> URL {
        let formatter = ISO8601DateFormatter()
        let name = "\(formatter.string(from: Date()))-\(UUID().uuidString).bvf"
        return outboxDirectoryURL.appendingPathComponent(name)
    }
}
