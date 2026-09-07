import SwiftUI

@main
struct BvfAudio_watchOSApp: App {
    init() {
        // Crash/kill recovery sweep: must run exactly once per process launch, here,
        // before any recording can possibly be active — see
        // WatchOutboxReconciler.recoverOrphanedParts() for why this is the only safe
        // place to call it (never from reconcile() or a scenePhase/reachability
        // trigger, which could fire mid-recording).
        WatchOutboxReconciler.shared.recoverOrphanedParts()
        // Deliberately NO reconcile() here: at App.init() the WCSession isn't activated
        // yet (WatchConnectivityManager.shared, which sets the delegate and activates,
        // isn't touched until the first view build), and transferFile on a non-activated
        // session is unreliable at best. Delivery of any just-promoted .bvf files happens
        // on the activation-triggered reconcile() in
        // WatchConnectivityManager.activationDidCompleteWith, which fires moments later.
    }

    var body: some Scene {
        WindowGroup {
            WatchRecordingView()
        }
    }
}
