import ActivityKit
import Foundation

// Keep in sync with Power/Support/RestTimerAttributes.swift: the app and the widget
// extension each compile their own copy, and ActivityKit matches them by name and shape.
struct RestTimerAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var endDate: Date
        var totalSeconds: Int
        var exerciseName: String
    }
}
