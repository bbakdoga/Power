import SwiftUI
import SwiftData

struct WorkoutTabView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Workout> { $0.endDate == nil }, sort: \Workout.startDate, order: .reverse)
    private var activeWorkouts: [Workout]
    @Query(sort: \Routine.name) private var routines: [Routine]

    var body: some View {
        NavigationStack {
            if let workout = activeWorkouts.first {
                ActiveWorkoutView(workout: workout)
            } else {
                startList
            }
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

            Section("Start from a routine") {
                if routines.isEmpty {
                    Text("Create a routine in the Routines tab, or save a finished workout as one.")
                        .foregroundStyle(.secondary)
                }
                ForEach(routines) { routine in
                    Button {
                        WorkoutStarter.start(routine: routine, in: context)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(routine.name)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(routine.summary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
        .navigationTitle("Start Workout")
    }
}
