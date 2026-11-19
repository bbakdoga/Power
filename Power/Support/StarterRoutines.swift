import Foundation
import SwiftData

/// Ready-made programs new users can add, built from the built-in exercise library.
enum StarterProgram: String, CaseIterable, Identifiable {
    case pushPullLegs, fullBody, upperLower

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pushPullLegs: return "Push / Pull / Legs"
        case .fullBody: return "Full Body"
        case .upperLower: return "Upper / Lower"
        }
    }

    var detail: String {
        switch self {
        case .pushPullLegs: return "3 routines · train 3–6 days a week"
        case .fullBody: return "1 routine · great for beginners, 2–3 days a week"
        case .upperLower: return "2 routines · train 4 days a week"
        }
    }

    var systemImage: String {
        switch self {
        case .pushPullLegs: return "rectangle.split.3x1"
        case .fullBody: return "figure.strengthtraining.traditional"
        case .upperLower: return "rectangle.split.1x2"
        }
    }

    /// Routine name → exercises as (name, sets, reps).
    var routines: [(name: String, exercises: [(String, Int, Int)])] {
        switch self {
        case .pushPullLegs:
            return [
                ("Push", [("Bench Press", 4, 8), ("Incline Dumbbell Press", 3, 10), ("Overhead Press", 3, 8),
                          ("Chest Fly Machine", 3, 12), ("Lateral Raise", 3, 12), ("Triceps Pushdown", 3, 12)]),
                ("Pull", [("Lat Pulldown", 4, 10), ("Barbell Row", 4, 8), ("Seated Cable Row", 3, 10),
                          ("Face Pull", 3, 15), ("Barbell Curl", 3, 10), ("Hammer Curl", 3, 12)]),
                ("Legs", [("Squat", 4, 6), ("Romanian Deadlift", 3, 8), ("Leg Press", 3, 10),
                          ("Lying Leg Curl", 3, 12), ("Leg Extension", 3, 12), ("Standing Calf Raise", 4, 12)]),
            ]
        case .fullBody:
            return [
                ("Full Body", [("Squat", 3, 8), ("Bench Press", 3, 8), ("Barbell Row", 3, 8),
                               ("Overhead Press", 3, 10), ("Romanian Deadlift", 3, 10), ("Plank", 3, 1)]),
            ]
        case .upperLower:
            return [
                ("Upper", [("Bench Press", 4, 6), ("Barbell Row", 4, 8), ("Dumbbell Shoulder Press", 3, 10),
                           ("Lat Pulldown", 3, 10), ("Dumbbell Curl", 3, 12), ("Triceps Pushdown", 3, 12)]),
                ("Lower", [("Squat", 4, 6), ("Romanian Deadlift", 3, 8), ("Bulgarian Split Squat", 3, 10),
                           ("Lying Leg Curl", 3, 12), ("Standing Calf Raise", 4, 12), ("Hanging Leg Raise", 3, 12)]),
            ]
        }
    }

    /// Adds this program's routines, skipping any whose name is already taken.
    /// Returns how many routines were created.
    @discardableResult
    func add(to context: ModelContext) -> Int {
        let exercises = (try? context.fetch(FetchDescriptor<Exercise>(predicate: #Predicate { !$0.isCustom }))) ?? []
        let byName = Dictionary(exercises.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let existing = Set(((try? context.fetch(FetchDescriptor<Routine>())) ?? []).map(\.name))

        var created = 0
        for plan in routines where !existing.contains(plan.name) {
            let routine = Routine(name: plan.name)
            context.insert(routine)
            for (index, item) in plan.exercises.enumerated() {
                guard let exercise = byName[item.0] else { continue }
                let entry = RoutineExercise(order: index, targetSets: item.1, targetReps: item.2)
                context.insert(entry)
                entry.routine = routine
                entry.exercise = exercise
            }
            created += 1
        }
        try? context.save()
        return created
    }
}
