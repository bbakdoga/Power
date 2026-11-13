import SwiftUI
import SwiftData

struct HistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Workout> { $0.endDate != nil }, sort: \Workout.startDate, order: .reverse)
    private var workouts: [Workout]
    @AppStorage(WeightUnit.storageKey) private var unit: WeightUnit = .kg

    /// Workouts grouped by calendar month, newest month first.
    private var months: [(key: Date, value: [Workout])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: workouts) { workout in
            calendar.dateInterval(of: .month, for: workout.startDate)?.start ?? workout.startDate
        }
        return groups.sorted { $0.key > $1.key }
    }

    var body: some View {
        NavigationStack {
            Group {
                if workouts.isEmpty {
                    ContentUnavailableView("No workouts yet",
                                           systemImage: "clock",
                                           description: Text("Finished workouts show up here."))
                } else {
                    List {
                        ForEach(months, id: \.key) { month in
                            Section(month.key.formatted(.dateTime.month(.wide).year())) {
                                ForEach(month.value) { workout in
                                    NavigationLink(value: workout) {
                                        WorkoutRow(workout: workout, unit: unit)
                                    }
                                }
                                .onDelete { offsets in
                                    for index in offsets {
                                        context.delete(month.value[index])
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("History")
            .navigationDestination(for: Workout.self) { workout in
                WorkoutDetailView(workout: workout)
            }
        }
    }
}

struct WorkoutRow: View {
    let workout: Workout
    let unit: WeightUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(workout.name).font(.headline)
                Spacer()
                Text(workout.startDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Label(workout.duration.clockString, systemImage: "timer")
                Label("\(unit.format(kg: workout.totalVolumeKg)) \(unit.rawValue)", systemImage: "scalemass")
                Label("\(workout.completedSetCount) sets", systemImage: "checkmark.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(workout.sortedExercises.compactMap { $0.exercise?.name }.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

struct WorkoutDetailView: View {
    @Bindable var workout: Workout
    @Environment(\.modelContext) private var context
    @AppStorage(WeightUnit.storageKey) private var unit: WeightUnit = .kg
    @State private var savedRoutine = false

    var body: some View {
        List {
            Section {
                LabeledContent("Date", value: workout.startDate.formatted(date: .complete, time: .shortened))
                LabeledContent("Duration", value: workout.duration.clockString)
                LabeledContent("Volume", value: "\(unit.format(kg: workout.totalVolumeKg)) \(unit.rawValue)")
                TextField("Notes", text: $workout.notes, axis: .vertical)
            }

            ForEach(workout.sortedExercises) { entry in
                Section(entry.exercise?.name ?? "Exercise") {
                    let labels = WorkoutExerciseSection.labels(for: entry.sortedSets)
                    let entryUnit = entry.exercise?.unit(default: unit) ?? unit
                    ForEach(Array(entry.sortedSets.enumerated()), id: \.element.id) { index, set in
                        HStack {
                            Text(labels[index])
                                .font(.subheadline.bold())
                                .frame(width: 32, alignment: .leading)
                            Text("\(entryUnit.format(kg: set.weightKg)) \(entryUnit.rawValue) × \(set.reps)")
                            Spacer()
                            Text("e1RM \(entryUnit.format(kg: set.estimatedOneRepMaxKg))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                Button {
                    WorkoutStarter.saveAsRoutine(workout, in: context)
                    savedRoutine = true
                } label: {
                    Label("Save as routine", systemImage: "square.and.arrow.down")
                }
            }
        }
        .navigationTitle(workout.name)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Routine saved", isPresented: $savedRoutine) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You can find it in the Routines tab.")
        }
    }
}
