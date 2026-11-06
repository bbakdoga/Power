import Foundation
import Observation
import UserNotifications

/// The rest timer shown under the active workout. It is driven by an end date,
/// so it keeps correct time when the app is in the background, and a local
/// notification fires when rest is over.
@Observable
final class RestTimer {
    private(set) var endDate: Date?
    private(set) var totalSeconds: Int = 0

    private let notificationID = "rest-timer"

    func remaining(at date: Date) -> TimeInterval {
        guard let endDate else { return 0 }
        return max(0, endDate.timeIntervalSince(date))
    }

    func start(seconds: Int) {
        guard seconds > 0 else { return }
        totalSeconds = seconds
        endDate = Date.now.addingTimeInterval(TimeInterval(seconds))
        scheduleNotification()
    }

    func adjust(by seconds: Int) {
        guard let current = endDate, current > .now else { return }
        let newEnd = current.addingTimeInterval(TimeInterval(seconds))
        guard newEnd > .now else {
            stop()
            return
        }
        endDate = newEnd
        totalSeconds = max(1, totalSeconds + seconds)
        scheduleNotification()
    }

    func stop() {
        endDate = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationID])
    }

    private func scheduleNotification() {
        guard let endDate else { return }
        let interval = endDate.timeIntervalSinceNow
        guard interval > 0 else { return }

        let center = UNUserNotificationCenter.current()
        let identifier = notificationID
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Rest is over"
            content.body = "Time for your next set."
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
        }
    }
}
