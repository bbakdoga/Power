import SwiftUI
import SwiftData

// Routines are listed and started from the Workout tab (WorkoutTabView).

struct RoutineEditorView: View {
    @Bindable var routine: Routine
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Workout> { $0.endDate == nil }) private var activeWorkouts: [Workout]
    @State private var showingPicker = false

    var body: some View {
        List {
            Section {
                TextField("Routine name", text: $routine.name)
                    .font(.headline)
                TextField("Notes", text: $routine.notes, axis: .vertical)
            }

            Section("Exercises") {
                ForEach(routine.sortedExercises) { item in
                    RoutineExerciseRow(item: item)
                }
                .onDelete { offsets in
                    let items = routine.sortedExercises
                    for index in offsets {
                        context.delete(items[index])
                    }
                }
                .onMove { source, destination in
                    var items = routine.sortedExercises
                    items.move(fromOffsets: source, toOffset: destination)
                    for (index, item) in items.enumerated() {
                        item.order = index
                    }
                }
                Button {
                    showingPicker = true
                } label: {
                    Label("Add exercises", systemImage: "plus")
                }
            }

            Section {
                Button {
                    WorkoutStarter.start(routine: routine, in: context)
                } label: {
                    Label("Start workout", systemImage: "play.fill")
                        .font(.headline)
                }
                .disabled(!activeWorkouts.isEmpty || routine.sortedExercises.isEmpty)
            } footer: {
                if !activeWorkouts.isEmpty {
                    Text("Finish your current workout before starting another.")
                }
            }
        }
        .navigationTitle(routine.name.isEmpty ? "Routine" : routine.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .sheet(isPresented: $showingPicker) {
            ExercisePickerView { selected in
                var order = (routine.sortedExercises.last?.order ?? -1) + 1
                for exercise in selected {
                    let item = RoutineExercise(order: order)
                    context.insert(item)
                    item.routine = routine
                    item.exercise = exercise
                    order += 1
                }
            }
        }
    }
}

struct RoutineExerciseRow: View {
    @Bindable var item: RoutineExercise

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.exercise?.name ?? "Exercise")
                .font(.headline)
            Stepper("\(item.targetSets) sets", value: $item.targetSets, in: 1...20)
            Stepper("\(item.targetReps) reps", value: $item.targetReps, in: 1...100)
        }
        .padding(.vertical, 2)
    }
}
