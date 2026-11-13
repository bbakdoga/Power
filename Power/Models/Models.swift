import Foundation
import SwiftData

// All properties have defaults and every relationship is optional so the
// store can later be synced with iCloud (CloudKit) without a migration.

enum AppSchema {
    static let models: [any PersistentModel.Type] = [
        Exercise.self,
        Workout.self,
        WorkoutExercise.self,
        WorkoutSet.self,
        Routine.self,
        RoutineExercise.self,
        BodyMeasurement.self,
    ]
}

@Model
final class Exercise {
    var name: String = ""
    var muscleGroupRaw: String = MuscleGroup.other.rawValue
    var equipmentRaw: String = Equipment.other.rawValue
    var isCustom: Bool = false
    /// Rest timer length started after each completed set. 0 turns it off.
    var restSeconds: Int = 90
    var notes: String = ""
    /// Weight unit for this exercise only (e.g. lb for a machine labeled in pounds);
    /// nil follows the app setting. Weights are still stored in kilograms.
    var unitRaw: String?

    @Relationship(deleteRule: .nullify, inverse: \WorkoutExercise.exercise)
    var workoutEntries: [WorkoutExercise]? = []

    @Relationship(deleteRule: .nullify, inverse: \RoutineExercise.exercise)
    var routineEntries: [RoutineExercise]? = []

    init(name: String, muscleGroup: MuscleGroup, equipment: Equipment, isCustom: Bool = false, restSeconds: Int = 90) {
        self.name = name
        self.muscleGroupRaw = muscleGroup.rawValue
        self.equipmentRaw = equipment.rawValue
        self.isCustom = isCustom
        self.restSeconds = restSeconds
    }

    var muscleGroup: MuscleGroup {
        get { MuscleGroup(rawValue: muscleGroupRaw) ?? .other }
        set { muscleGroupRaw = newValue.rawValue }
    }

    var equipment: Equipment {
        get { Equipment(rawValue: equipmentRaw) ?? .other }
        set { equipmentRaw = newValue.rawValue }
    }

    var subtitle: String { "\(muscleGroup.title) · \(equipment.title)" }

    /// The unit to show this exercise's weights in.
    func unit(default appUnit: WeightUnit) -> WeightUnit {
        unitRaw.flatMap(WeightUnit.init(rawValue:)) ?? appUnit
    }

    /// Entries of this exercise in finished workouts, newest first.
    var completedEntries: [WorkoutExercise] {
        (workoutEntries ?? [])
            .filter { $0.workout?.endDate != nil }
            .sorted { ($0.workout?.startDate ?? .distantPast) > ($1.workout?.startDate ?? .distantPast) }
    }

    /// Every completed working set (warm-ups excluded) across all finished workouts.
    var completedWorkingSets: [WorkoutSet] {
        completedEntries.flatMap(\.completedSets).filter { $0.setType != .warmup }
    }
}

@Model
final class Workout {
    var name: String = "Workout"
    var startDate: Date = Date.now
    /// nil while the workout is in progress.
    var endDate: Date?
    var notes: String = ""

    @Relationship(deleteRule: .cascade, inverse: \WorkoutExercise.workout)
    var exercises: [WorkoutExercise]? = []

    init(name: String, startDate: Date = .now) {
        self.name = name
        self.startDate = startDate
    }

    var sortedExercises: [WorkoutExercise] {
        (exercises ?? []).sorted { $0.order < $1.order }
    }

    /// Letter for each superset in this workout ("A", "B", …), in exercise order.
    var supersetLetters: [String: String] {
        var letters: [String: String] = [:]
        for id in sortedExercises.compactMap(\.supersetID) where letters[id] == nil {
            letters[id] = String(UnicodeScalar(UInt8(65 + letters.count % 26)))
        }
        return letters
    }

    var duration: TimeInterval {
        (endDate ?? .now).timeIntervalSince(startDate)
    }

    var totalVolumeKg: Double {
        sortedExercises.reduce(0) { $0 + $1.volumeKg }
    }

    var completedSetCount: Int {
        sortedExercises.reduce(0) { $0 + $1.completedSets.count }
    }
}

@Model
final class WorkoutExercise {
    var order: Int = 0
    var notes: String = ""
    /// Exercises sharing an ID are done back to back as a superset; nil when standalone.
    var supersetID: String?
    var exercise: Exercise?
    var workout: Workout?

    @Relationship(deleteRule: .cascade, inverse: \WorkoutSet.workoutExercise)
    var sets: [WorkoutSet]? = []

    init(order: Int) {
        self.order = order
    }

    var sortedSets: [WorkoutSet] {
        (sets ?? []).sorted { $0.order < $1.order }
    }

    var completedSets: [WorkoutSet] {
        sortedSets.filter(\.isDone)
    }

    /// Weight × reps of completed working sets, in kilograms.
    var volumeKg: Double {
        completedSets
            .filter { $0.setType != .warmup }
            .reduce(0) { $0 + $1.weightKg * Double($1.reps) }
    }

    var bestEstimatedOneRepMaxKg: Double {
        completedSets
            .filter { $0.setType != .warmup }
            .map(\.estimatedOneRepMaxKg)
            .max() ?? 0
    }
}

@Model
final class WorkoutSet {
    var order: Int = 0
    /// Always stored in kilograms; converted for display.
    var weightKg: Double = 0
    var reps: Int = 0
    var setTypeRaw: String = SetType.normal.rawValue
    var isDone: Bool = false
    var completedAt: Date?
    var workoutExercise: WorkoutExercise?

    init(order: Int, weightKg: Double = 0, reps: Int = 0) {
        self.order = order
        self.weightKg = weightKg
        self.reps = reps
    }

    var setType: SetType {
        get { SetType(rawValue: setTypeRaw) ?? .normal }
        set { setTypeRaw = newValue.rawValue }
    }

    var estimatedOneRepMaxKg: Double {
        OneRepMax.epley(weight: weightKg, reps: reps)
    }
}

@Model
final class Routine {
    var name: String = "New Routine"
    var notes: String = ""
    var createdAt: Date = Date.now

    @Relationship(deleteRule: .cascade, inverse: \RoutineExercise.routine)
    var exercises: [RoutineExercise]? = []

    init(name: String) {
        self.name = name
    }

    var sortedExercises: [RoutineExercise] {
        (exercises ?? []).sorted { $0.order < $1.order }
    }

    var summary: String {
        let names = sortedExercises.compactMap { $0.exercise?.name }
        return names.isEmpty ? "No exercises yet" : names.joined(separator: ", ")
    }
}

@Model
final class RoutineExercise {
    var order: Int = 0
    var targetSets: Int = 3
    var targetReps: Int = 10
    /// Same meaning as `WorkoutExercise.supersetID`; copied when a workout starts.
    var supersetID: String?
    var exercise: Exercise?
    var routine: Routine?

    init(order: Int, targetSets: Int = 3, targetReps: Int = 10) {
        self.order = order
        self.targetSets = targetSets
        self.targetReps = targetReps
    }
}

@Model
final class BodyMeasurement {
    var date: Date = Date.now
    var kindRaw: String = BodyMeasurementKind.bodyweight.rawValue
    /// Kilograms for bodyweight, percent for body fat, centimetres otherwise.
    var value: Double = 0

    init(date: Date = .now, kind: BodyMeasurementKind, value: Double) {
        self.date = date
        self.kindRaw = kind.rawValue
        self.value = value
    }

    var kind: BodyMeasurementKind {
        get { BodyMeasurementKind(rawValue: kindRaw) ?? .bodyweight }
        set { kindRaw = newValue.rawValue }
    }
}
