import SwiftUI
import SwiftData

/// Start a workout and manage routines in one place. While a workout is running,
/// this tab shows it instead.
struct WorkoutTabView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Workout> { $0.endDate == nil }, sort: \Workout.startDate, order: .reverse)
    private var activeWorkouts: [Workout]
    @Query(sort: \Routine.name) private var routines: [Routine]
    @State private var path: [Routine] = []
    @State private var summary: FinishedWorkout?

    private struct FinishedWorkout: Identifiable {
        let workout: Workout
        let canSaveRoutine: Bool
        var id: PersistentIdentifier { workout.persistentModelID }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let workout = activeWorkouts.first {
                    ActiveWorkoutView(workout: workout)
                } else {
                    startList
                }
            }
            .navigationDestination(for: Routine.self) { routine in
                RoutineEditorView(routine: routine)
            }
        }
        .onChange(of: activeWorkouts.first?.persistentModelID) { previous, current in
            // Starting from a routine's page: pop back so the running workout is visible.
            path = []
            if let previous, current == nil {
                offerRoutine(forFinished: previous)
            }
        }
        .sheet(item: $summary) { item in
            WorkoutSummaryView(workout: item.workout, canSaveRoutine: item.canSaveRoutine)
        }
    }

    /// After a workout is saved (not discarded), show its summary. "Save as Routine" is
    /// offered unless it was started from a routine with the same name.
    private func offerRoutine(forFinished id: PersistentIdentifier) {
        let descriptor = FetchDescriptor<Workout>(predicate: #Predicate { $0.persistentModelID == id })
        guard let workout = try? context.fetch(descriptor).first,
              workout.endDate != nil,
              !workout.sortedExercises.isEmpty else { return }
        summary = FinishedWorkout(workout: workout,
                                  canSaveRoutine: !routines.contains { $0.name == workout.name })
    }

    private var startList: some View {
        List {
            Section {
                Button {
                    WorkoutStarter.startEmpty(in: context)
                } label: {
                    Label("Start empty workout", systemImage: "plus.circle.fill")
                        .font(.headline)
                }
            }

            Section {
                if routines.isEmpty {
                    Text("Tap + to plan a workout you do often, or save a finished workout as a routine.")
                        .foregroundStyle(.secondary)
                }
                ForEach(routines) { routine in
                    HStack(spacing: 12) {
                        NavigationLink(value: routine) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(routine.name)
                                    .font(.headline)
                                Text(routine.summary)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Button("Start") {
                            WorkoutStarter.start(routine: routine, in: context)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(routine.sortedExercises.isEmpty)
                        .accessibilityLabel("Start \(routine.name)")
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        context.delete(routines[index])
                    }
                }
            } header: {
                HStack {
                    Text("My routines")
                    Spacer()
                    Button {
                        newRoutine()
                    } label: {
                        Label("New routine", systemImage: "plus")
                            .font(.subheadline.bold())
                            .textCase(nil)
                    }
                }
            }
        }
        .navigationTitle("Workout")
    }

    private func newRoutine() {
        let routine = Routine(name: "New Routine")
        context.insert(routine)
        path.append(routine)
    }
}
