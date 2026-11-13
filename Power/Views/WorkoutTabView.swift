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
        .onChange(of: activeWorkouts.isEmpty) {
            // Starting from a routine's page: pop back so the running workout is visible.
            path = []
        }
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
