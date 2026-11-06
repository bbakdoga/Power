import Foundation
import SwiftData

/// Built-in exercise library, inserted on first launch.
enum SeedData {
    static func seedIfNeeded(_ context: ModelContext) {
        let count = (try? context.fetchCount(FetchDescriptor<Exercise>())) ?? 0
        guard count == 0 else { return }
        for item in library {
            context.insert(Exercise(name: item.0, muscleGroup: item.1, equipment: item.2, restSeconds: item.3))
        }
        try? context.save()
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
    ]
}
