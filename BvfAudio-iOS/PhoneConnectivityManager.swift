import Foundation
import WatchConnectivity
import BvfAppKit

/// Publishes the recipient public key to the paired watch app via
/// `WCSession.updateApplicationContext`.
///
/// `applicationContext` is the right primitive here: it is latest-value-wins,
/// persisted across relaunches, and delivered to the watch even while backgrounded —
/// exactly the semantics needed for "the watch should always have the current
/// recipient pubkey," as opposed to a one-shot message.
///
/// Also receives watch-delivered `.bvf` files (`didReceive file:`) and commits
/// them into the shared iCloud folder via `BvfStore.commit`, then acks. See that method
/// for the full dedup/commit/ack contract.
@MainActor
final class PhoneConnectivityManager: NSObject {
    static let shared = PhoneConnectivityManager()

    private var lastPublishedPublicKey: String?

    private var session: WCSession?

    /// Set when `publishRecipientPublicKey` reads a key but WCSession isn't
    /// `.activated` yet (activation is async — on-device this window is real and
    /// `updateApplicationContext` throws `sessionNotActivated` in it), or when a push
    /// throws for any other reason. Flushed once activation completes successfully.
    private var pendingPublicKey: String?

    /// Set via `configure(cloudManager:)` from the app's launch `.task`. Needed by
    /// `didReceive file:` to resolve the commit destination — that delegate callback
    /// can fire from a WCSession-triggered background launch, so this must be wired up
    /// as early as possible (before any file delivery can realistically occur).
    private var cloudManager: iCloudManager?

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        self.session = session
    }

    /// Wires up the iCloud folder reference `didReceive file:` needs to commit
    /// incoming watch files. Call once at app launch, alongside `RecordingModel.configure`.
    func configure(cloudManager: iCloudManager) {
        self.cloudManager = cloudManager
    }

    /// Reads the current recipient public key (if the iCloud container and key file
    /// are available) and republishes it to the watch. Safe to call repeatedly —
    /// e.g. on cloud availability changes, or whenever the key might have changed.
    /// No-ops if iCloud/the key aren't ready yet, or WCSession isn't supported.
    ///
    /// The read itself does not depend on WCSession activation state, so it always
    /// happens; only the actual `updateApplicationContext` push is gated on
    /// `.activated` — otherwise the key is stashed in `pendingPublicKey` and flushed
    /// from `activationDidCompleteWith` once activation finishes.
    func publishRecipientPublicKey(cloudManager: iCloudManager) {
        guard let session = session,
              cloudManager.isAvailable,
              let publicKeyURL = cloudManager.sharedPublicKeyURL,
              FileManager.default.fileExists(atPath: publicKeyURL.path) else {
            return
        }

        // Exact same read path BvfAppKit's CryptoService uses before handing the
        // string to `Encrypter(recipientPublicKey:)` — trimmed UTF-8 contents of
        // the key file. Sending anything else would not round-trip.
        guard let publicKey = try? readKeyFile(at: publicKeyURL) else { return }
        send(publicKey, via: session)
    }

    /// Pushes `publicKey` via `updateApplicationContext` if the session is activated;
    /// otherwise (or on throw) stashes it in `pendingPublicKey` for activation to flush.
    private func send(_ publicKey: String, via session: WCSession) {
        guard session.activationState == .activated else {
            pendingPublicKey = publicKey
            return
        }

        guard publicKey != lastPublishedPublicKey || session.applicationContext["recipientPublicKey"] as? String != publicKey else {
            // Unchanged and already reflected in the current application context.
            return
        }

        do {
            // `updateApplicationContext` silently drops a payload byte-identical to the
            // last one *sent* — the system dedups on value, not on the receiving install.
            // So a freshly reinstalled watch (whose received-context/UserDefaults cache
            // was wiped) never gets a re-sent identical key: the phone still holds it in
            // its persisted outgoing context, so every relaunch re-sends the same dict and
            // the OS discards it. A rotating nonce keeps each push distinct so delivery
            // always fires. The watch reads only "recipientPublicKey" and ignores this;
            // its `adopt(_:)` no-ops when the key is unchanged, so repeat deliveries are
            // harmless. The in-session guard above still prevents redundant pushes.
            try session.updateApplicationContext([
                "recipientPublicKey": publicKey,
                "nonce": UUID().uuidString,
            ])
            lastPublishedPublicKey = publicKey
            pendingPublicKey = nil
        } catch {
            pendingPublicKey = publicKey
        }
    }

    /// Flushes a key stashed by `send(_:via:)` while WCSession wasn't activated yet.
    /// Called from `activationDidCompleteWith` on the success path.
    private func flushPendingPublicKeyAfterActivation() {
        guard let pending = pendingPublicKey, let session = session else { return }
        send(pending, via: session)
    }
}

extension PhoneConnectivityManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        guard error == nil, activationState == .activated else { return }
        Task { @MainActor in
            self.flushPendingPublicKeyAfterActivation()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate to support switching between paired watches.
        session.activate()
    }

    /// Receives a `.bvf` file transferred from the watch, commits it into the
    /// shared iCloud folder (unless already committed), and ALWAYS acks — even on a
    /// dedup skip — so a resend whose earlier ack was lost still gets cleaned up on
    /// the watch side. This is the reliability core: the watch's outbox is the ledger,
    /// and the only way an entry leaves it is a positive ack from here.
    ///
    /// `file.fileURL` points at a temp location the system deletes once this method
    /// returns, so the copy-out must happen synchronously before returning (or before
    /// any `await`, if this were async — it deliberately isn't, to keep that guarantee
    /// simple and obvious).
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let uuid = file.metadata?["uuid"] as? String, !uuid.isEmpty else { return }

        // Copy out of the delivered temp location synchronously, before it's deleted.
        let holdingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchIncomingHolding", isDirectory: true)
        let localCopyURL = holdingDirectory.appendingPathComponent("\(uuid).bvf")
        do {
            try FileManager.default.createDirectory(at: holdingDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: localCopyURL.path) {
                try FileManager.default.removeItem(at: localCopyURL)
            }
            try FileManager.default.copyItem(at: file.fileURL, to: localCopyURL)
        } catch {
            // Couldn't even copy the file out — do NOT ack. Let the watch retry on the
            // next reconcile/redelivery; there's nothing to dedup or commit yet.
            return
        }

        let timestampString = file.metadata?["timestamp"] as? String
        let suffix = (file.metadata?["suffix"] as? String) ?? "aac"

        Task { @MainActor in
            self.commitAndAck(uuid: uuid, localCopyURL: localCopyURL, timestampString: timestampString, suffix: suffix)
        }
    }
}

extension PhoneConnectivityManager {
    /// Commits `localCopyURL` into the shared iCloud folder via `BvfStore.commit`
    /// (unless `uuid` was already committed), then sends the ack unconditionally.
    ///
    /// The `.bvf` file is already a complete bvf-v1 stream (header + ciphertext) written
    /// by the watch's `WatchCiphertextWriter` — this never re-encrypts, only moves it
    /// into place, exactly like `PushEncryptionContext.finish()` does for locally
    /// recorded files.
    private func commitAndAck(uuid: String, localCopyURL: URL, timestampString: String?, suffix: String) {
        defer {
            // Best-effort local cleanup of the holding copy regardless of outcome —
            // the ack (or lack thereof) is what governs the watch's ledger, not this.
            try? FileManager.default.removeItem(at: localCopyURL)
        }

        if CommittedUUIDStore.shared.isCommitted(uuid) {
            ack(uuid: uuid)
            return
        }

        guard let cloudManager, let destinationFolderURL = cloudManager.appFolderURL else {
            // No destination available (iCloud not set up / configure() never called,
            // e.g. a background WCSession launch that raced app init). Do NOT ack —
            // there is nowhere to commit to yet, so the watch must keep retrying.
            return
        }

        let date = timestampString.flatMap { string -> Date? in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = formatter.date(from: string) { return parsed }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: string)
        } ?? Date()

        // Mirrors PushEncryptionContext.finish()'s security-scoped-resource wrap
        // around the destination folder; BvfStore.commit also wraps internally and is
        // documented idempotent when callers additionally wrap.
        let didStartAccess = destinationFolderURL.startAccessingSecurityScopedResource()
        defer { if didStartAccess { destinationFolderURL.stopAccessingSecurityScopedResource() } }

        guard (try? BvfStore.commit(staged: localCopyURL, date: date, suffix: suffix, in: destinationFolderURL)) != nil else {
            // Commit failed — do NOT mark committed, do NOT ack. Watch keeps the
            // outbox entry and this will be retried on the next delivery attempt.
            return
        }
        CommittedUUIDStore.shared.markCommitted(uuid)
        ack(uuid: uuid)
    }

    /// Sends `{"ackedUUID": uuid}` via `transferUserInfo`, which — like `transferFile`
    /// — is durable across app suspension and retried by the system.
    private func ack(uuid: String) {
        guard let session else { return }
        _ = session.transferUserInfo(["ackedUUID": uuid])
    }
}
