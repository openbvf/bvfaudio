import BvfKit
import Foundation
import WatchConnectivity

/// Reliable watch -> iPhone delivery of encrypted `.bvf` files.
///
/// Design principle: `Documents/Outbox/*.bvf` IS the ledger. A file present there means
/// "not yet acknowledged by the phone." Deletion happens ONLY on a positive ack
/// (`didReceiveUserInfo` with `ackedUUID`). `WCSession`'s `didFinishFileTransfer` is
/// deliberately ignored (not even implemented) — the iOS 17.5+/watchOS file-transfer
/// completion signal is known to be unreliable, so correctness comes from our own
/// ack/dedup, never from that delegate call.
///
/// `transferFile` itself is resilient to app suspension/relaunch (the system persists
/// and resumes the queue), so the only things this type must get right are: (a) don't
/// double-enqueue a file that's already mid-transfer, and (b) re-enqueue anything still
/// sitting in the Outbox whenever there's a plausible new opportunity to send it.
@MainActor
final class WatchOutboxReconciler {
    static let shared = WatchOutboxReconciler()

    private init() {}

    /// Enumerate `Documents/Outbox/*.bvf`, skip anything already transferring (matched by
    /// uuid, not file path, since a resend after relaunch is a new local URL for the same
    /// logical file), and enqueue the rest via `transferFile(_:metadata:)`.
    ///
    /// Safe to call redundantly from multiple triggers (activation, reachability changes,
    /// foreground, post-recording) — the in-flight check makes repeated calls a no-op for
    /// files already enqueued.
    func reconcile() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default

        let outboxDir = WatchCiphertextWriter.outboxDirectoryURL
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: outboxDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        // pathExtension == "bvf" deliberately excludes in-progress `.bvf.part` files —
        // WatchCiphertextWriter writes there during recording and only renames to the
        // final `.bvf` name in finish(), so a still-recording file is never visible
        // here (previously, grabbing an in-progress file mid-recording and then
        // dedup-blocking the real completed file was the truncated-delivery bug).
        let bvfFiles = entries.filter { $0.pathExtension == "bvf" }
        guard !bvfFiles.isEmpty else { return }

        let inFlightUUIDs = Set(session.outstandingFileTransfers.compactMap { $0.file.metadata?["uuid"] as? String })

        for fileURL in bvfFiles {
            // Unparseable name: leave in place rather than transfer it blind.
            guard let parsed = Self.parseOutboxFilename(fileURL.lastPathComponent) else { continue }
            guard !inFlightUUIDs.contains(parsed.uuid) else { continue }

            let metadata: [String: Any] = [
                "uuid": parsed.uuid,
                "timestamp": parsed.isoTimestamp,
                "suffix": "aac",
            ]
            session.transferFile(fileURL, metadata: metadata)
        }
    }

    /// Crash/kill recovery: promotes or discards orphaned `.bvf.part` files left behind
    /// when the app PROCESS was killed mid-recording (force-quit, crash, OOM jettison,
    /// reboot, battery death) before `WatchCiphertextWriter.finish()` could rename the
    /// file to `.bvf`. A truncated bvf-v1 file with no final TAG_FINAL chunk decrypts
    /// fine (confirmed) — it just yields the partial audio captured before the kill —
    /// so a `.part` with at least one flushed ciphertext chunk is worth recovering.
    ///
    /// For each `.bvf.part` file: if its size is greater than `BvfConfig.headerSize`
    /// (i.e. at least one 64 KB plaintext chunk was durably flushed), promote it by
    /// dropping the `.part` extension — `WatchOutboxReconciler.reconcile()` then picks
    /// it up as a normal complete `.bvf` file on the next trigger. If the size is at or
    /// below the header size (nothing but the HPKE/secretstream header was ever
    /// written — no audio survived), delete it; there is nothing to deliver.
    ///
    /// SAFETY: this must be called EXACTLY ONCE per process launch, before any
    /// recording could possibly be active — see call site in `BvfAudio_watchOSApp.init()`
    /// for why. Calling this while a recording is in progress would promote (or delete)
    /// an in-progress file mid-write, which is exactly the truncated-delivery bug that
    /// motivated writing to `.part` in the first place. Do NOT call this from
    /// `reconcile()` or any scenePhase/foreground/reachability trigger.
    func recoverOrphanedParts() {
        let outboxDir = WatchCiphertextWriter.outboxDirectoryURL
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: outboxDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let partFiles = entries.filter { $0.pathExtension == "part" }
        guard !partFiles.isEmpty else { return }

        for partURL in partFiles {
            let fileSize = (try? partURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

            if fileSize > BvfConfig.headerSize {
                // At least one flushed chunk of real audio — promote to a deliverable .bvf.
                try? FileManager.default.moveItem(at: partURL, to: partURL.deletingPathExtension())
            } else {
                // Header-only, no audio survived — nothing to deliver.
                try? FileManager.default.removeItem(at: partURL)
            }
        }
    }

    /// Positive ack from the phone: delete the Outbox file whose filename encodes `uuid`.
    /// This is the ONLY place Outbox files are deleted.
    func handleAck(uuid: String) {
        let outboxDir = WatchCiphertextWriter.outboxDirectoryURL
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: outboxDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for fileURL in entries where fileURL.pathExtension == "bvf" {
            guard let parsed = Self.parseOutboxFilename(fileURL.lastPathComponent), parsed.uuid == uuid else { continue }
            try? FileManager.default.removeItem(at: fileURL)
            return
        }

        // No matching file — either already removed by a prior ack, or never existed
        // locally (e.g. a stale/duplicate ack after a fresh install). Not an error.
    }

    /// Outbox filenames are `<ISO8601 with fractional seconds>-<UUID>.bvf`, written by
    /// `WatchCiphertextWriter.makeOutboxFileURL()`. Parses both fields back out.
    nonisolated static func parseOutboxFilename(_ filename: String) -> (uuid: String, isoTimestamp: String, date: Date)? {
        guard filename.hasSuffix(".bvf") else { return nil }
        let stem = String(filename.dropLast(".bvf".count))

        // UUID string is 36 chars (8-4-4-4-12 hex with dashes); the separator between the
        // timestamp and the uuid is itself a "-", so split from the right on the last 37
        // characters ("-" + 36-char UUID) rather than splitting on every "-" (the ISO8601
        // timestamp also contains "-" in the date portion).
        let uuidLength = 36
        guard stem.count > uuidLength + 1 else { return nil }

        let uuidStartIndex = stem.index(stem.endIndex, offsetBy: -uuidLength)
        let separatorIndex = stem.index(before: uuidStartIndex)
        guard stem[separatorIndex] == "-" else { return nil }

        let isoTimestamp = String(stem[stem.startIndex..<separatorIndex])
        let uuidString = String(stem[uuidStartIndex...])

        guard UUID(uuidString: uuidString) != nil else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: isoTimestamp)
        if date == nil {
            // Fall back to without-fractional-seconds in case the formatter that wrote
            // the name didn't include them for some timestamps.
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: isoTimestamp)
        }
        guard let date else { return nil }

        return (uuid: uuidString, isoTimestamp: isoTimestamp, date: date)
    }
}
