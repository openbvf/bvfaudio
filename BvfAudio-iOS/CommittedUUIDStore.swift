import Foundation

/// Persistent dedup ledger for watch-delivered `.bvf` files.
///
/// `WCSession.transferFile` can redeliver the same file if an earlier ack was lost
/// (network drop, app killed before `transferUserInfo` flushed, etc.) — `didReceive`
/// must be safe to call twice for the same uuid: commit at most once, but ALWAYS ack,
/// so the watch's outbox eventually clears even if the first ack never arrived.
///
/// Backed by `UserDefaults.standard`, matching the app's other lightweight persisted
/// state. Survives relaunch (including the background relaunch WCSession can trigger to
/// deliver a file).
final class CommittedUUIDStore {
    static let shared = CommittedUUIDStore()

    private static let defaultsKey = "committedWatchUUIDs"
    private let defaults = UserDefaults.standard

    private init() {}

    /// True if `uuid` has already been committed (moved into the iCloud folder).
    func isCommitted(_ uuid: String) -> Bool {
        committedUUIDs.contains(uuid)
    }

    /// Records `uuid` as committed and persists immediately. Idempotent.
    func markCommitted(_ uuid: String) {
        var uuids = committedUUIDs
        guard uuids.insert(uuid).inserted else { return }
        defaults.set(Array(uuids), forKey: Self.defaultsKey)
    }

    private var committedUUIDs: Set<String> {
        Set(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }
}
