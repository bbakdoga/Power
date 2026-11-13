import Foundation

/// Statistics shared by the Profile tab and the weekly summary.
enum WorkoutStats {
    /// Consecutive weeks with at least one workout, counting back from this week.
    /// An empty current week doesn't break the streak until it's over.
    static func weekStreak(_ workouts: [Workout], calendar: Calendar = .current) -> Int {
        let trainedWeeks = Set(workouts.compactMap { calendar.dateInterval(of: .weekOfYear, for: $0.startDate)?.start })
        guard var week = calendar.dateInterval(of: .weekOfYear, for: .now)?.start else { return 0 }
        if !trainedWeeks.contains(week) {
            week = calendar.date(byAdding: .weekOfYear, value: -1, to: week) ?? week
        }
        var count = 0
        while trainedWeeks.contains(week) {
            count += 1
            week = calendar.date(byAdding: .weekOfYear, value: -1, to: week) ?? week
        }
        return count
    }

    /// Longest run of consecutive training weeks ever.
    static func longestWeekStreak(_ workouts: [Workout], calendar: Calendar = .current) -> Int {
        let weeks = Set(workouts.compactMap { calendar.dateInterval(of: .weekOfYear, for: $0.startDate)?.start }).sorted()
        var best = 0
        var current = 0
        var previous: Date?
        for week in weeks {
            if let previous, calendar.date(byAdding: .weekOfYear, value: 1, to: previous) == week {
                current += 1
            } else {
                current = 1
            }
            best = max(best, current)
            previous = week
        }
        return best
    }

    /// Number of workouts in each of the last `count` weeks, oldest first.
    static func workoutsPerWeek(_ workouts: [Workout], count: Int, calendar: Calendar = .current) -> [(week: Date, workouts: Int)] {
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: .now)?.start else { return [] }
        let counts = Dictionary(grouping: workouts) {
            calendar.dateInterval(of: .weekOfYear, for: $0.startDate)?.start ?? $0.startDate
        }.mapValues(\.count)
        return (0..<count).reversed().compactMap { offset in
            calendar.date(byAdding: .weekOfYear, value: -offset, to: thisWeek).map { ($0, counts[$0] ?? 0) }
        }
    }
}
