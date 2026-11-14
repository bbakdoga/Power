import Foundation
import SwiftData

/// Built-in exercise library, inserted on first launch.
enum SeedData {
    /// Bump when exercises are added to `library` so existing installs get them.
    private static let libraryVersion = 2
    private static let versionKey = "seedLibraryVersion"

    /// Inserts built-in exercises that aren't in the store yet (by name). Runs once per
    /// library version, so an exercise the user deleted doesn't keep coming back.
    static func seedIfNeeded(_ context: ModelContext) {
        guard UserDefaults.standard.integer(forKey: versionKey) < libraryVersion else { return }
        let existing = Set(((try? context.fetch(FetchDescriptor<Exercise>())) ?? []).map(\.name))
        for item in library where !existing.contains(item.0) {
            context.insert(Exercise(name: item.0, muscleGroup: item.1, equipment: item.2, restSeconds: item.3))
        }
        try? context.save()
        UserDefaults.standard.set(libraryVersion, forKey: versionKey)
    }

    /// With iCloud sync, a second device (or a reinstall) seeds the library before the
    /// synced copy arrives, leaving two of each built-in exercise. Merge them into one,
    /// moving workout and routine history onto the copy that's used most.
    static func mergeDuplicates(_ context: ModelContext) {
        let descriptor = FetchDescriptor<Exercise>(predicate: #Predicate { !$0.isCustom })
        guard let builtIns = try? context.fetch(descriptor) else { return }

        var changed = false
        for (_, copies) in Dictionary(grouping: builtIns, by: \.name) where copies.count > 1 {
            let usage: (Exercise) -> Int = { ($0.workoutEntries?.count ?? 0) + ($0.routineEntries?.count ?? 0) }
            guard let keeper = copies.max(by: { usage($0) < usage($1) }) else { continue }
            for duplicate in copies where duplicate !== keeper {
                for entry in duplicate.workoutEntries ?? [] { entry.exercise = keeper }
                for entry in duplicate.routineEntries ?? [] { entry.exercise = keeper }
                context.delete(duplicate)
                changed = true
            }
        }
        if changed { try? context.save() }
    }

    private static let library: [(String, MuscleGroup, Equipment, Int)] = [
        // Chest
        ("Bench Press", .chest, .barbell, 150),
        ("Incline Bench Press", .chest, .barbell, 150),
        ("Dumbbell Bench Press", .chest, .dumbbell, 120),
        ("Incline Dumbbell Press", .chest, .dumbbell, 120),
        ("Dumbbell Fly", .chest, .dumbbell, 90),
        ("Cable Crossover", .chest, .cable, 90),
        ("Chest Press Machine", .chest, .machine, 90),
        ("Push-up", .chest, .bodyweight, 60),
        ("Dip", .chest, .bodyweight, 90),
        // Back
        ("Deadlift", .back, .barbell, 180),
        ("Barbell Row", .back, .barbell, 120),
        ("Pull-up", .back, .bodyweight, 120),
        ("Chin-up", .back, .bodyweight, 120),
        ("Lat Pulldown", .back, .cable, 90),
        ("Seated Cable Row", .back, .cable, 90),
        ("Dumbbell Row", .back, .dumbbell, 90),
        ("T-Bar Row", .back, .machine, 120),
        ("Back Extension", .back, .bodyweight, 60),
        // Shoulders
        ("Overhead Press", .shoulders, .barbell, 150),
        ("Dumbbell Shoulder Press", .shoulders, .dumbbell, 120),
        ("Lateral Raise", .shoulders, .dumbbell, 60),
        ("Cable Lateral Raise", .shoulders, .cable, 60),
        ("Rear Delt Fly", .shoulders, .dumbbell, 60),
        ("Face Pull", .shoulders, .cable, 60),
        ("Shrug", .shoulders, .dumbbell, 60),
        // Arms
        ("Barbell Curl", .biceps, .barbell, 60),
        ("Dumbbell Curl", .biceps, .dumbbell, 60),
        ("Hammer Curl", .biceps, .dumbbell, 60),
        ("Preacher Curl", .biceps, .machine, 60),
        ("Cable Curl", .biceps, .cable, 60),
        ("Triceps Pushdown", .triceps, .cable, 60),
        ("Overhead Triceps Extension", .triceps, .dumbbell, 60),
        ("Skull Crusher", .triceps, .barbell, 60),
        ("Close-Grip Bench Press", .triceps, .barbell, 120),
        // Legs
        ("Squat", .legs, .barbell, 180),
        ("Front Squat", .legs, .barbell, 180),
        ("Leg Press", .legs, .machine, 120),
        ("Romanian Deadlift", .legs, .barbell, 150),
        ("Bulgarian Split Squat", .legs, .dumbbell, 90),
        ("Walking Lunge", .legs, .dumbbell, 90),
        ("Leg Extension", .legs, .machine, 60),
        ("Lying Leg Curl", .legs, .machine, 60),
        ("Standing Calf Raise", .legs, .machine, 60),
        ("Goblet Squat", .legs, .kettlebell, 90),
        // Glutes
        ("Hip Thrust", .glutes, .barbell, 120),
        ("Glute Bridge", .glutes, .bodyweight, 60),
        ("Cable Kickback", .glutes, .cable, 60),
        // Core
        ("Plank", .core, .bodyweight, 60),
        ("Hanging Leg Raise", .core, .bodyweight, 60),
        ("Cable Crunch", .core, .cable, 60),
        ("Ab Wheel Rollout", .core, .other, 60),
        // Full body and cardio
        ("Kettlebell Swing", .fullBody, .kettlebell, 90),
        ("Power Clean", .fullBody, .barbell, 150),
        ("Farmer's Carry", .fullBody, .dumbbell, 90),
        ("Rowing Machine", .cardio, .machine, 60),
        ("Running", .cardio, .other, 60),

        // Library version 2
        ("Chest Fly Machine", .chest, .machine, 60),
        ("Decline Bench Press", .chest, .barbell, 150),
        ("Smith Machine Bench Press", .chest, .machine, 120),
        ("Incline Chest Press Machine", .chest, .machine, 90),
        ("Incline Dumbbell Fly", .chest, .dumbbell, 90),
        ("Low-to-High Cable Fly", .chest, .cable, 60),

        ("Assisted Pull-up", .back, .machine, 90),
        ("Seated Row Machine", .back, .machine, 90),
        ("Close-Grip Lat Pulldown", .back, .cable, 90),
        ("Straight-Arm Pulldown", .back, .cable, 60),
        ("Chest-Supported Dumbbell Row", .back, .dumbbell, 90),
        ("Inverted Row", .back, .bodyweight, 90),
        ("Rack Pull", .back, .barbell, 150),

        ("Shoulder Press Machine", .shoulders, .machine, 90),
        ("Arnold Press", .shoulders, .dumbbell, 90),
        ("Front Raise", .shoulders, .dumbbell, 60),
        ("Lateral Raise Machine", .shoulders, .machine, 60),
        ("Reverse Pec Deck", .shoulders, .machine, 60),
        ("Upright Row", .shoulders, .barbell, 60),
        ("Band Pull-Apart", .shoulders, .band, 45),

        ("EZ-Bar Curl", .biceps, .barbell, 60),
        ("Incline Dumbbell Curl", .biceps, .dumbbell, 60),
        ("Concentration Curl", .biceps, .dumbbell, 60),
        ("Biceps Curl Machine", .biceps, .machine, 60),

        ("Rope Pushdown", .triceps, .cable, 60),
        ("Triceps Kickback", .triceps, .dumbbell, 60),
        ("Triceps Dip Machine", .triceps, .machine, 60),
        ("Diamond Push-up", .triceps, .bodyweight, 60),

        ("Hack Squat", .legs, .machine, 150),
        ("Smith Machine Squat", .legs, .machine, 150),
        ("Sumo Deadlift", .legs, .barbell, 180),
        ("Seated Leg Curl", .legs, .machine, 60),
        ("Seated Calf Raise", .legs, .machine, 60),
        ("Hip Adduction Machine", .legs, .machine, 60),
        ("Reverse Lunge", .legs, .dumbbell, 90),
        ("Step-up", .legs, .dumbbell, 90),

        ("Hip Abduction Machine", .glutes, .machine, 60),
        ("Cable Pull-Through", .glutes, .cable, 60),
        ("Glute Kickback Machine", .glutes, .machine, 60),

        ("Crunch", .core, .bodyweight, 45),
        ("Ab Crunch Machine", .core, .machine, 60),
        ("Russian Twist", .core, .bodyweight, 45),
        ("Side Plank", .core, .bodyweight, 45),
        ("Dead Bug", .core, .bodyweight, 45),
        ("Pallof Press", .core, .cable, 45),

        ("Burpee", .fullBody, .bodyweight, 60),
        ("Thruster", .fullBody, .barbell, 120),
        ("Sled Push", .fullBody, .other, 120),

        ("Stationary Bike", .cardio, .machine, 60),
        ("Elliptical", .cardio, .machine, 60),
        ("Stair Climber", .cardio, .machine, 60),
        ("Jump Rope", .cardio, .other, 60),
    ]
}
