import SwiftUI
import SwiftData
import Charts

struct ExercisesView: View {
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @AppStorage(AppLanguage.storageKey) private var language: AppLanguage = .system
    @State private var showingNew = false

    private var availableGroups: [MuscleGroup] {
        MuscleGroup.allCases.filter { !exercises(for: $0).isEmpty }
    }

    private func exercises(for group: MuscleGroup) -> [Exercise] {
        guard group == .fullBody else {
            return exercises.filter { $0.muscleGroup == group }
        }

        return exercises.filter { exercise in
            guard exercise.muscleGroup != .cardio else { return false }
            if exercise.muscleGroup == .fullBody { return true }
            guard let guide = ExerciseGuide.guide(for: exercise) else { return false }
            return Set(guide.primary + guide.secondary).count > 1
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 16) {
                    ForEach(availableGroups) { group in
                        NavigationLink(value: group) {
                            BodyPartCard(
                                title: group.localizedTitle(language: language),
                                assetName: group.assetName,
                                systemImage: group.systemImage
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle("Exercises")
            .themedScreen()
            .navigationDestination(for: MuscleGroup.self) { group in
                ExerciseGroupView(
                    group: group,
                    exercises: exercises(for: group)
                )
            }
            .navigationDestination(for: Exercise.self) { exercise in
                ExerciseDetailView(exercise: exercise)
            }
            .toolbar {
                Button {
                    showingNew = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New exercise")
            }
            .sheet(isPresented: $showingNew) {
                ExerciseEditorView(exercise: nil)
            }
        }
    }
}

private struct BodyPartCard: View {
    let title: String
    let assetName: String?
    let systemImage: String

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if let assetName {
                    Image(assetName)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(height: 88)

            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 150)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ExerciseGroupView: View {
    let group: MuscleGroup
    let exercises: [Exercise]

    @AppStorage(AppLanguage.storageKey) private var language: AppLanguage = .system
    @State private var search = ""

    private var filteredExercises: [Exercise] {
        search.isEmpty
            ? exercises
            : exercises.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List(filteredExercises) { exercise in
            NavigationLink(value: exercise) {
                ExerciseListRow(exercise: exercise)
            }
        }
        .searchable(text: $search)
        .navigationTitle(group.localizedTitle(language: language))
        .themedScreen()
    }
}

private struct ExerciseListRow: View {
    let exercise: Exercise

    var body: some View {
        HStack(spacing: 12) {
            ExerciseThumbnail(exercise: exercise)
            VStack(alignment: .leading, spacing: 2) {
                Text(exercise.name)
                Text(exercise.equipment.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ExerciseDetailView: View {
    @Bindable var exercise: Exercise
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(WeightUnit.storageKey) private var appUnit: WeightUnit = .kg
    @State private var editing = false

    private var unit: WeightUnit { exercise.unit(default: appUnit) }
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
            Section {
                ExerciseGraphicView(exercise: exercise)
            }
            .themedRows()

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
            .themedRows()

            Section("Personal records") {
                LabeledContent("Heaviest weight", value: weightText(sets.map(\.weightKg).max()))
                LabeledContent("Best estimated 1RM", value: weightText(sets.map(\.estimatedOneRepMaxKg).max()))
                LabeledContent("Most reps in one set", value: sets.map(\.reps).max().map { "\($0)" } ?? "–")
                LabeledContent("Best session volume", value: weightText(entries.map(\.volumeKg).max()))
            }
            .themedRows()

            Section("History") {
                if entries.isEmpty {
                    Text("No sets logged yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.workout?.startDate.formatted(date: .abbreviated, time: .omitted) ?? "")
                            .font(.subheadline.bold())
                        Text(entry.completedSets.map { $0.summary(exercise.tracking, unit: unit) }.joined(separator: "   "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .themedRows()

            if exercise.isCustom {
                Section {
                    Button("Delete exercise", role: .destructive) { confirmingDelete = true }
                }
                .themedRows()
            }
        }
        .navigationTitle(exercise.name)
        .themedScreen()
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
    @State private var tracking: TrackingType = .weightReps

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
                Picker("Tracks", selection: $tracking) {
                    ForEach(TrackingType.allCases) { Text($0.title).tag($0) }
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
                    tracking = exercise.tracking
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
            exercise.tracking = tracking
        } else {
            let new = Exercise(name: trimmed, muscleGroup: muscleGroup, equipment: equipment,
                               isCustom: true, restSeconds: restSeconds)
            new.tracking = tracking
            context.insert(new)
        }
        dismiss()
    }
}
