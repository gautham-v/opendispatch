import Foundation
import OpenDispatchCore
#if os(iOS)
import BackgroundTasks
import UIKit
#endif

/// iOS background app refresh (BGAppRefreshTask "com.gauthamv.openfeed.refresh"). The SwiftUI scene
/// handles the task with `.backgroundTask(.appRefresh(BackgroundRefresh.identifier))` in OpenDispatchApp;
/// RootView calls `schedule()` when the app moves to the background. macOS refreshes on foreground only.
enum BackgroundRefresh {
    // Must match BGTaskSchedulerPermittedIdentifiers in project.yml; keeps the bundle id's original name.
    static let identifier = "com.gauthamv.openfeed.refresh"
    /// Ask to run no sooner than this (feeds are stale after 15 min).
    static let interval: TimeInterval = 30 * 60

    static func schedule() {
        #if os(iOS)
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }

    /// Runs `work` so that leaving the app doesn't freeze it halfway: iOS gives it about 30 more seconds, and cancels it if
    /// that runs out. Being cancelled itself (the view that asked went away) doesn't stop it. Elsewhere it just runs.
    @MainActor
    static func finishing<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task { try await work() }
        #if os(iOS)
        let grant = BackgroundGrant { task.cancel() }
        defer { grant.end() }
        #endif
        return try await task.value
    }

    /// Body of the background task: schedule the next one, then a non-forced refresh and its notifications.
    static func run(_ services: OpenDispatchServices) async {
        schedule()
        if let r = try? await services.refresh.refreshAll(force: false), r.ran {
            await PostNotifications.deliver(services.database)
        }
    }
}

#if os(iOS)
/// iOS's extra time after the app leaves the foreground; `expired` runs when it's up.
@MainActor
private final class BackgroundGrant {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(expired: @escaping @MainActor @Sendable () -> Void) {
        id = UIApplication.shared.beginBackgroundTask(withName: "Refresh") { [weak self] in
            expired()
            self?.end()
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
#endif
