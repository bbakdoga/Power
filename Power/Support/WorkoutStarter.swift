import Foundation
import SwiftData

/// Creates workouts and fills in sets from what was lifted last time.
enum WorkoutStarter {
    @discardableResult
    static func startEmpty(in context: ModelContext) -> Workout {
        let workout = Workout(name: defaultName())
        context.insert(workout)
        return workout
    }

    @discardableResult
    static func start(routine: Routine, in context: ModelContext) -> Workout {
        let workout = Workout(name: routine.name)
        context.insert(workout)
        for (index, item) in routine.sortedExercises.enumerated() {
            guard let exercise = item.exercise else { continue }
            addExercise(exercise, to: workout, order: index, in: context,
                        setCount: item.targetSets, targetReps: item.targetReps)
        }
        return workout
    }

    @discardableResult
    static func addExercise(_ exercise: Exercise, to workout: Workout, order: Int, in context: ModelContext,
                            setCount: Int = 1, targetReps: Int? = nil) -> WorkoutExercise {
        let entry = WorkoutExercise(order: order)
        context.insert(entry)
        entry.workout = workout
        entry.exercise = exercise

        let previous = exercise.completedEntries.first?.completedSets.filter { $0.setType != .warmup } ?? []
        for index in 0..<max(setCount, 1) {
            let prior = index < previous.count ? previous[index] : previous.last
            let set = WorkoutSet(order: index,
                                 weightKg: prior?.weightKg ?? 0,
                                 reps: targetReps ?? prior?.reps ?? 0)
            context.insert(set)
            set.workoutExercise = entry
        }
        return entry
    }

    /// Makes a routine with the same exercises as a finished workout.
    @discardableResult
    static func saveAsRoutine(_ workout: Workout, in context: ModelContext) -> Routine {
        let routine = Routine(name: workout.name)
        context.insert(routine)
        for (index, entry) in workout.sortedExercises.enumerated() {
            guard let exercise = entry.exercise else { continue }
            let working = entry.completedSets.filter { $0.setType != .warmup }
            let item = RoutineExercise(order: index,
                                       targetSets: max(working.count, 1),
                                       targetReps: working.last?.reps ?? 10)
            context.insert(item)
            item.routine = routine
            item.exercise = exercise
        }
        return routine
    }

    static func defaultName(for date: Date = .now) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: return "Morning Workout"
        case 12..<17: return "Afternoon Workout"
        case 17..<22: return "Evening Workout"
        default: return "Night Workout"
        }
    }
}
