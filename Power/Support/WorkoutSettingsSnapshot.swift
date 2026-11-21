import Foundation
import SwiftData

/// Remembers exercise settings as they were when a workout started, so cancelling the
/// workout can put them back: rest time, sticky note, per-exercise unit and the
/// weight-suggestion switch. Saving a workout keeps the changes.
///
/// Stored in UserDefaults (not the database) so it survives the app being closed
/// mid-workout without needing a new iCloud field.
enum WorkoutSettingsSnapshot {
    private struct ExerciseSettings: Codable {
        var restSeconds: Int
        var notes: String
        var unitRaw: String?
    }

    private struct Snapshot: Codable {
        var workoutStart: Date
        var exercises: [String: ExerciseSettings] = [:]
        var showSuggestions: Bool?
    }

    private static let storageKey = "workoutSettingsSnapshot"
    static let showSuggestionsKey = "showWeightSuggestions"

    /// Records the exercise's current settings, unless they were already recorded for
    /// this workout. Call before anything in the workout can change them.
    static func remember(_ exercise: Exercise, in workout: Workout) {
        var snapshot = load(for: workout)
        if snapshot.showSuggestions == nil {
            let defaults = UserDefaults.standard
            snapshot.showSuggestions = defaults.object(forKey: showSuggestionsKey) as? Bool ?? true
        }
        guard let key = key(for: exercise), snapshot.exercises[key] == nil else {
            save(snapshot)
            return
        }
        snapshot.exercises[key] = ExerciseSettings(restSeconds: exercise.restSeconds,
                                                   notes: exercise.notes,
                                                   unitRaw: exercise.unitRaw)
        save(snapshot)
    }

    /// Puts back every recorded setting (when the workout is cancelled).
    static func restore(for workout: Workout, in context: ModelContext) {
        let snapshot = load(for: workout)
        for (key, settings) in snapshot.exercises {
            guard let data = key.data(using: .utf8),
                  let id = try? JSONDecoder().decode(PersistentIdentifier.self, from: data),
                  let exercise = context.model(for: id) as? Exercise else { continue }
            exercise.restSeconds = settings.restSeconds
            exercise.notes = settings.notes
            exercise.unitRaw = settings.unitRaw
        }
        if let showSuggestions = snapshot.showSuggestions {
            UserDefaults.standard.set(showSuggestions, forKey: showSuggestionsKey)
        }
        clear()
    }

    /// Forgets the recorded settings (when the workout is saved).
    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    private static func key(for exercise: Exercise) -> String? {
        guard let data = try? JSONEncoder().encode(exercise.persistentModelID) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The snapshot for this workout; a leftover one from another workout is dropped.
    private static func load(for workout: Workout) -> Snapshot {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
           snapshot.workoutStart == workout.startDate {
            return snapshot
        }
        return Snapshot(workoutStart: workout.startDate)
    }

    private static func save(_ snapshot: Snapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
