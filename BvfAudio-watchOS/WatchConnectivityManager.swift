import Foundation
import WatchConnectivity

/// Receives the recipient public key published by `BvfAudio-iOS` via
/// `WCSession.updateApplicationContext` and caches it in `UserDefaults.standard`, so it
/// survives relaunch (application context delivery itself is also persisted/replayed by
/// the system, but a local cache means the recorder has a key available even before
/// WCSession finishes activating).
///
/// Also owns the WCSessionDelegate callbacks that drive outbox delivery —
/// triggers `WatchOutboxReconciler.reconcile()` on activation and reachability
/// changes, and routes `didReceiveUserInfo` acks to it. See `WatchOutboxReconciler`
/// for the actual ledger/dedup logic and rationale.
@Observable
@MainActor
final class WatchConnectivityManager: NSObject {
    static let shared = WatchConnectivityManager()

    /// `bvf-pub:` recipient public key, or nil if none has been provisioned yet.
    /// Watch UI/recorder should gate recording on this being non-nil.
    private(set) var recipientPublicKey: String?

    /// Delivery badge for the latest recording. `.sent` is driven by the phone's ack
    /// (`didReceiveUserInfo` -> `ackedUUID`) — the same signal that removes the file
    /// from the Outbox ledger — so it means confirmed-delivered, not just enqueued.
    /// In-memory and single-slot: older files redeliver silently via the reconciler.
    enum DeliveryState: Equatable {
        case sending
        case sent
    }
    private(set) var deliveryState: DeliveryState?
    private var latestRecordingUUID: String?

    func markSending(uuid: String) {
        latestRecordingUUID = uuid
        deliveryState = .sending
    }

    /// Guarded so a late ack for a superseded recording can't overwrite the badge.
    func markSent(uuid: String) {
        guard uuid == latestRecordingUUID else { return }
        deliveryState = .sent
    }

    @ObservationIgnored private var session: WCSession?

    private static let cacheDefaultsKey = "cachedRecipientPublicKey"

    private override init() {
        super.init()

        // Load any previously cached key immediately so the UI doesn't show the
        // empty state on every relaunch while waiting for WCSession to activate.
        recipientPublicKey = Self.readCachedKey()

        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        self.session = session

        // A context delivered before this manager existed (e.g. app was relaunched)
        // is available synchronously as `receivedApplicationContext` — don't wait
        // for another `didReceiveApplicationContext` callback that may never come.
        if let pending = session.receivedApplicationContext["recipientPublicKey"] as? String,
           !pending.isEmpty {
            adopt(publicKey: pending)
        }
    }

    private func adopt(publicKey: String) {
        guard publicKey != recipientPublicKey else { return }
        recipientPublicKey = publicKey
        Self.writeCachedKey(publicKey)
    }

    private static func readCachedKey() -> String? {
        guard let key = UserDefaults.standard.string(forKey: cacheDefaultsKey), !key.isEmpty else {
            return nil
        }
        return key
    }

    private static func writeCachedKey(_ key: String) {
        UserDefaults.standard.set(key, forKey: cacheDefaultsKey)
    }
}

extension WatchConnectivityManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        guard error == nil else { return }

        // Pick up a context that arrived/changed between init and activation completing.
        if let key = session.receivedApplicationContext["recipientPublicKey"] as? String, !key.isEmpty {
            Task { @MainActor in
                self.adopt(publicKey: key)
            }
        }

        guard activationState == .activated else { return }
        Task { @MainActor in
            WatchOutboxReconciler.shared.reconcile()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let key = applicationContext["recipientPublicKey"] as? String, !key.isEmpty else { return }
        Task { @MainActor in
            self.adopt(publicKey: key)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        Task { @MainActor in
            WatchOutboxReconciler.shared.reconcile()
        }
    }

    /// Ack from the phone: `{"ackedUUID": <uuid>}`. This is the ONLY trigger that
    /// deletes an outbox file — see `WatchOutboxReconciler`.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let ackedUUID = userInfo["ackedUUID"] as? String, !ackedUUID.isEmpty else { return }
        Task { @MainActor in
            WatchOutboxReconciler.shared.handleAck(uuid: ackedUUID)
            self.markSent(uuid: ackedUUID)
        }
    }
}
