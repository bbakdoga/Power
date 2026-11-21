import ActivityKit
import Foundation
import Observation
import SwiftData
import UserNotifications

/// The rest timer shown under the active workout. It is driven by an end date,
/// so it keeps correct time when the app is in the background, and a local
/// notification fires when rest is over. While resting, a Live Activity shows the
/// countdown on the Lock Screen and in the Dynamic Island.
@Observable
final class RestTimer {
    /// One timer for the whole app, so Lock Screen buttons (RestTimerIntents) can reach it.
    @MainActor static let shared = RestTimer()

    private(set) var endDate: Date?
    private(set) var totalSeconds: Int = 0
    /// The set whose checkmark started this rest, so its divider can show the countdown.
    private(set) var setID: PersistentIdentifier?
    private var exerciseName = ""

    private let notificationID = "rest-timer"
    @ObservationIgnored private var activity: Activity<RestTimerAttributes>?

    init() {
        // If iOS relaunched the app (e.g. for a Lock Screen button), pick up the running
        // countdown from its Live Activity. Anything finished or duplicated is cleared.
        let running = Activity<RestTimerAttributes>.activities.filter { $0.activityState == .active }
        if let current = running.first, current.content.state.endDate > .now {
            let state = current.content.state
            endDate = state.endDate
            totalSeconds = state.totalSeconds
            exerciseName = state.exerciseName
            activity = current
            let extras = running.dropFirst()
            Task { for extra in extras { await extra.end(nil, dismissalPolicy: .immediate) } }
        } else {
            endAllLiveActivities()
        }
    }

    func remaining(at date: Date) -> TimeInterval {
        guard let endDate else { return 0 }
        return max(0, endDate.timeIntervalSince(date))
    }

    func start(seconds: Int, exerciseName: String = "", setID: PersistentIdentifier? = nil) {
        guard seconds > 0 else { return }
        totalSeconds = seconds
        self.setID = setID
        self.exerciseName = exerciseName
        endDate = Date.now.addingTimeInterval(TimeInterval(seconds))
        scheduleNotification()
        updateLiveActivity()
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
        updateLiveActivity()
    }

    func stop() {
        endDate = nil
        setID = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationID])
        endAllLiveActivities()
    }

    /// Call when the app comes back to the foreground: a finished rest no longer
    /// needs to sit on the Lock Screen.
    func clearIfFinished() {
        if let endDate, endDate <= .now {
            stop()
        }
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
            content.title = String(localized: "Rest is over")
            content.body = String(localized: "Time for your next set.")
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
        }
    }

    // MARK: - Live Activity

    private func updateLiveActivity() {
        guard let endDate else { return }
        let name = exerciseName
        let labels = RestTimerAttributes.Labels(
            rest: String(localized: "Rest"),
            resting: String(localized: "Resting"),
            restIsOver: String(localized: "Rest is over"),
            go: String(localized: "Go!"),
            skip: String(localized: "Skip"),
            next: name.isEmpty ? "" : String(localized: "Next: \(name)"),
            nextSet: name.isEmpty ? "" : String(localized: "Time for your next set of \(name)"))
        let state = RestTimerAttributes.ContentState(endDate: endDate, totalSeconds: totalSeconds,
                                                     exerciseName: name, labels: labels)
        // Going stale at the end date switches the activity to its "rest is over" look.
        let content = ActivityContent(state: state, staleDate: endDate)

        if let activity, activity.activityState == .active {
            Task { await activity.update(content) }
        } else {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            activity = try? Activity.request(attributes: RestTimerAttributes(), content: content)
        }
    }

    private func endAllLiveActivities() {
        activity = nil
        // Capture the list now so a countdown started right after this isn't ended too.
        let running = Activity<RestTimerAttributes>.activities
        Task {
            for activity in running {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
