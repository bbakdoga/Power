import ActivityKit
import AppIntents
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

// MARK: - Lock Screen buttons

// Declared in both targets with the same names. LiveActivityIntents run in the app's
// process, so only the app's copy does the work; the widget's copy just builds buttons.

struct AdjustRestIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Adjust Rest Timer"
    static let isDiscoverable = false

    @Parameter(title: "Seconds") var seconds: Int

    init() {}
    init(seconds: Int) { self.seconds = seconds }

    func perform() async throws -> some IntentResult {
        .result()
    }
}

struct SkipRestIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Skip Rest"
    static let isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult {
        .result()
    }
}
