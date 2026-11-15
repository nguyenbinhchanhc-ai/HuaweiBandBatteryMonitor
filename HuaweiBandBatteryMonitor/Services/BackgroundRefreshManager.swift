import BackgroundTasks
import Foundation

/// Registers and schedules iOS background app refresh tasks to poll Band 11 battery level periodically.
enum BackgroundRefreshManager {
    static func register(bleManager: BLEBatteryManager, store: BatteryStore) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: AppConstants.backgroundTaskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refreshTask: refreshTask, bleManager: bleManager, store: store)
        }
    }

    static func scheduleNextRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: AppConstants.backgroundTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(refreshTask: BGAppRefreshTask, bleManager: BLEBatteryManager, store: BatteryStore) {
        scheduleNextRefresh()

        let workTask = Task { @MainActor in
            if let level = await bleManager.performBackgroundPoll() {
                store.recordReading(
                    level: level,
                    source: .bleRead,
                    deviceName: bleManager.connectedDeviceName,
                    isConnected: true
                )
            }
            refreshTask.setTaskCompleted(success: true)
        }

        refreshTask.expirationHandler = {
            workTask.cancel()
            refreshTask.setTaskCompleted(success: false)
        }
    }
}
