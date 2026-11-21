import Foundation

/// Detects when a completed set beats the lifter's previous best for that exercise.
enum PersonalRecords {
    enum Kind: CaseIterable {
        case heaviestWeight, oneRepMax, mostReps, longestTime, longestDistance

        var title: String {
            switch self {
            case .heaviestWeight: return String(localized: "Heaviest weight")
            case .oneRepMax: return String(localized: "Best est. 1RM")
            case .mostReps: return String(localized: "Most reps")
            case .longestTime: return String(localized: "Longest time")
            case .longestDistance: return String(localized: "Longest distance")
            }
        }
    }

    /// Records this set breaks, compared with finished workouts plus the checked-off
    /// sets before it in the current workout. Warm-ups never count, and an exercise's
    /// first-ever session sets no records (there's nothing to beat yet).
    static func newRecords(for set: WorkoutSet) -> [Kind] {
        guard set.isDone, set.setType != .warmup, set.hasData,
              let entry = set.workoutExercise, let exercise = entry.exercise else { return [] }

        // Only workouts before this one count, so records still show correctly after saving.
        let started = entry.workout?.startDate ?? .now
        let history = exercise.completedWorkingSets.filter {
            ($0.workoutExercise?.workout?.startDate ?? .distantFuture) < started
        }
        guard !history.isEmpty else { return [] }

        let earlierToday = entry.completedSets.filter {
            $0.setType != .warmup && $0.order < set.order
        }
        let baseline = history + earlierToday

        var records: [Kind] = []
        switch exercise.tracking {
        case .duration:
            if set.durationSeconds > (baseline.map(\.durationSeconds).max() ?? 0) { records.append(.longestTime) }
            return records
        case .distanceDuration, .weightDistance:
            if exercise.tracking == .weightDistance, set.weightKg > (baseline.map(\.weightKg).max() ?? 0) {
                records.append(.heaviestWeight)
            }
            if set.distanceMeters > (baseline.map(\.distanceMeters).max() ?? 0) { records.append(.longestDistance) }
            return records
        case .weightReps:
            break
        }
        guard set.reps > 0 else { return [] }
        if set.weightKg > 0 {
            if set.weightKg > (baseline.map(\.weightKg).max() ?? 0) {
                records.append(.heaviestWeight)
            }
            if set.estimatedOneRepMaxKg > (baseline.map(\.estimatedOneRepMaxKg).max() ?? 0) {
                records.append(.oneRepMax)
            }
        } else if set.reps > (baseline.filter { $0.weightKg == 0 }.map(\.reps).max() ?? 0) {
            // Bodyweight exercises: more reps is the record.
            records.append(.mostReps)
        }
        return records
    }
}
