import Foundation

/// Detects when a completed set beats the lifter's previous best for that exercise.
enum PersonalRecords {
    enum Kind: CaseIterable {
        case heaviestWeight, oneRepMax, mostReps

        var title: String {
            switch self {
            case .heaviestWeight: return "Heaviest weight"
            case .oneRepMax: return "Best est. 1RM"
            case .mostReps: return "Most reps"
            }
        }
    }

    /// Records this set breaks, compared with finished workouts plus the checked-off
    /// sets before it in the current workout. Warm-ups never count, and an exercise's
    /// first-ever session sets no records (there's nothing to beat yet).
    static func newRecords(for set: WorkoutSet) -> [Kind] {
        guard set.isDone, set.setType != .warmup, set.reps > 0,
              let entry = set.workoutExercise, let exercise = entry.exercise else { return [] }

        let history = exercise.completedWorkingSets
        guard !history.isEmpty else { return [] }

        let earlierToday = entry.completedSets.filter {
            $0.setType != .warmup && $0.order < set.order
        }
        let baseline = history + earlierToday

        var records: [Kind] = []
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
