import SwiftUI
import SwiftData
import Charts

struct ExercisesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @State private var search = ""
    @State private var showingNew = false

    private var filtered: [Exercise] {
        search.isEmpty ? exercises : exercises.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(MuscleGroup.allCases) { group in
                    let items = filtered.filter { $0.muscleGroup == group }
                    if !items.isEmpty {
                        Section(group.title) {
                            ForEach(items) { exercise in
                                NavigationLink(value: exercise) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(exercise.name)
                                        Text(exercise.equipment.title)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $search)
            .navigationTitle("Exercises")
            .navigationDestination(for: Exercise.self) { exercise in
                ExerciseDetailView(exercise: exercise)
            }
            .toolbar {
                Button {
                    showingNew = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            .sheet(isPresented: $showingNew) {
                ExerciseEditorView(exercise: nil)
            }
        }
    }
}

struct ExerciseDetailView: View {
    @Bindable var exercise: Exercise
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(WeightUnit.storageKey) private var unit: WeightUnit = .kg
    @State private var editing = false
    @State private var confirmingDelete = false

    private struct ChartPoint: Identifiable {
        let id: PersistentIdentifier
        let date: Date
        let value: Double
    }

    private var chartPoints: [ChartPoint] {
        exercise.completedEntries.reversed().compactMap { entry -> ChartPoint? in
            let best = entry.bestEstimatedOneRepMaxKg
            guard best > 0, let date = entry.workout?.startDate else { return nil }
            return ChartPoint(id: entry.persistentModelID, date: date, value: unit.fromKg(best))
        }
    }

    var body: some View {
        let points = chartPoints
        let sets = exercise.completedWorkingSets
        let entries = exercise.completedEntries

        List {
            Section("Estimated 1-rep max (\(unit.rawValue))") {
                if points.count < 2 {
                    Text("Log this exercise in two workouts to see your progress here.")
                        .foregroundStyle(.secondary)
                } else {
                    Chart(points) { point in
                        LineMark(x: .value("Date", point.date), y: .value("e1RM", point.value))
                        PointMark(x: .value("Date", point.date), y: .value("e1RM", point.value))
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 200)
                    .padding(.vertical, 8)
                }
            }

            Section("Personal records") {
                LabeledContent("Heaviest weight", value: weightText(sets.map(\.weightKg).max()))
                LabeledContent("Best estimated 1RM", value: weightText(sets.map(\.estimatedOneRepMaxKg).max()))
                LabeledContent("Most reps in one set", value: sets.map(\.reps).max().map { "\($0)" } ?? "–")
                LabeledContent("Best session volume", value: weightText(entries.map(\.volumeKg).max()))
            }

            Section("History") {
                if entries.isEmpty {
                    Text("No sets logged yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.workout?.startDate.formatted(date: .abbreviated, time: .omitted) ?? "")
                            .font(.subheadline.bold())
                        Text(entry.completedSets.map { "\(unit.format(kg: $0.weightKg)) × \($0.reps)" }.joined(separator: "   "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if exercise.isCustom {
                Section {
                    Button("Delete exercise", role: .destructive) { confirmingDelete = true }
                }
            }
        }
        .navigationTitle(exercise.name)
        .toolbar {
            Button("Edit") { editing = true }
        }
        .sheet(isPresented: $editing) {
            ExerciseEditorView(exercise: exercise)
        }
        .confirmationDialog("Delete \(exercise.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                context.delete(exercise)
                dismiss()
            }
        } message: {
            Text("Past workouts keep their sets, but they will no longer show this exercise's name.")
        }
    }

    private func weightText(_ kilograms: Double?) -> String {
        guard let kilograms, kilograms > 0 else { return "–" }
        return "\(unit.format(kg: kilograms)) \(unit.rawValue)"
    }
}

struct ExerciseEditorView: View {
    let exercise: Exercise?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var name = ""
    @State private var muscleGroup: MuscleGroup = .chest
    @State private var equipment: Equipment = .barbell
    @State private var restSeconds = 90

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Picker("Muscle group", selection: $muscleGroup) {
                    ForEach(MuscleGroup.allCases) { Text($0.title).tag($0) }
                }
                Picker("Equipment", selection: $equipment) {
                    ForEach(Equipment.allCases) { Text($0.title).tag($0) }
                }
                Stepper("Rest timer: \(restSeconds.restLabel)", value: $restSeconds, in: 0...600, step: 15)
            }
            .navigationTitle(exercise == nil ? "New Exercise" : "Edit Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let exercise {
                    name = exercise.name
                    muscleGroup = exercise.muscleGroup
                    equipment = exercise.equipment
                    restSeconds = exercise.restSeconds
                }
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let exercise {
            exercise.name = trimmed
            exercise.muscleGroup = muscleGroup
            exercise.equipment = equipment
            exercise.restSeconds = restSeconds
        } else {
            context.insert(Exercise(name: trimmed, muscleGroup: muscleGroup, equipment: equipment,
                                    isCustom: true, restSeconds: restSeconds))
        }
        dismiss()
    }
}
