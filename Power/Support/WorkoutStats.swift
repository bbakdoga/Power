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

    /// Consecutive weeks in which at least `goal` workouts were done, counting back from
    /// this week. The current week only counts once the goal is reached, and doesn't
    /// break the streak while it's still in progress.
    static func goalStreak(_ workouts: [Workout], goal: Int, calendar: Calendar = .current) -> Int {
        let counts = Dictionary(grouping: workouts) {
            calendar.dateInterval(of: .weekOfYear, for: $0.startDate)?.start ?? $0.startDate
        }.mapValues(\.count)
        guard var week = calendar.dateInterval(of: .weekOfYear, for: .now)?.start else { return 0 }
        var streak = 0
        if (counts[week] ?? 0) >= goal { streak += 1 }
        week = calendar.date(byAdding: .weekOfYear, value: -1, to: week) ?? week
        while (counts[week] ?? 0) >= goal {
            streak += 1
            week = calendar.date(byAdding: .weekOfYear, value: -1, to: week) ?? week
        }
        return streak
    }

    /// Completed working sets per muscle group for workouts since `start`.
    static func setsPerGroup(_ workouts: [Workout], since start: Date) -> [MuscleGroup: Int] {
        var counts: [MuscleGroup: Int] = [:]
        for workout in workouts where workout.startDate >= start {
            for entry in workout.sortedExercises {
                guard let group = entry.exercise?.muscleGroup else { continue }
                counts[group, default: 0] += entry.completedSets.filter { $0.setType != .warmup }.count
            }
        }
        return counts
    }

    /// Training per calendar day, for the year heatmap: the day's volume in kilograms,
    /// or a small value for days with only cardio/timed work so they still show up.
    static func dailyLoad(_ workouts: [Workout], calendar: Calendar = .current) -> [Date: Double] {
        var load: [Date: Double] = [:]
        for workout in workouts {
            let day = calendar.startOfDay(for: workout.startDate)
            load[day, default: 0] += max(workout.totalVolumeKg, 1)
        }
        return load
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
