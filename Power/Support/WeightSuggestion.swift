import Foundation

/// "Last time 80 kg × 10, try 82.5 kg today": simple double progression. If every set at
/// last session's top weight reached the target reps, add one small step; otherwise stay
/// at that weight and aim to hit the reps on every set.
struct WeightSuggestion {
    let lastWeightKg: Double
    let lastReps: Int
    let suggestedWeightKg: Double
    let targetReps: Int
    let isIncrease: Bool

    static func make(for entry: WorkoutExercise, unit: WeightUnit) -> WeightSuggestion? {
        guard let exercise = entry.exercise, let last = exercise.completedEntries.first else { return nil }
        let working = last.completedSets.filter { $0.setType != .warmup && $0.setType != .drop }
        guard let top = working.map(\.weightKg).max(), top > 0 else { return nil }
        let topSets = working.filter { $0.weightKg == top }

        // Today's planned reps (from the routine or pre-filled from last time) are the target.
        let planned = entry.sortedSets.filter { $0.setType != .warmup }.map(\.reps).max() ?? 0
        let target = planned > 0 ? planned : (topSets.map(\.reps).max() ?? 0)
        guard target > 0 else { return nil }

        let hitEverySet = topSets.allSatisfy { $0.reps >= target }
        return WeightSuggestion(lastWeightKg: top,
                                lastReps: topSets.map(\.reps).min() ?? 0,
                                suggestedWeightKg: hitEverySet ? top + step(for: exercise, unit: unit) : top,
                                targetReps: target,
                                isIncrease: hitEverySet)
    }

    /// Smallest sensible jump, in kilograms: bigger for heavy lower-body barbell lifts.
    private static func step(for exercise: Exercise, unit: WeightUnit) -> Double {
        let lowerBody = [.legs, .glutes].contains(exercise.muscleGroup) || exercise.name.contains("Deadlift")
        switch (unit, exercise.equipment) {
        case (.kg, .barbell): return lowerBody ? 5 : 2.5
        case (.kg, .dumbbell), (.kg, .kettlebell): return 2
        case (.kg, _): return 2.5
        case (.lb, .barbell): return unit.toKg(lowerBody ? 10 : 5)
        case (.lb, _): return unit.toKg(5)
        }
    }
}
