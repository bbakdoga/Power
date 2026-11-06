import SwiftUI
import SwiftData

struct ActiveWorkoutView: View {
    @Bindable var workout: Workout
    @Environment(\.modelContext) private var context
    @Environment(RestTimer.self) private var restTimer
    @State private var showingPicker = false
    @State private var confirmingFinish = false
    @State private var confirmingDiscard = false

    var body: some View {
        List {
            Section {
                TextField("Workout name", text: $workout.name)
                    .font(.title3.bold())
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    Label(timeline.date.timeIntervalSince(workout.startDate).clockString, systemImage: "timer")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(workout.sortedExercises) { entry in
                WorkoutExerciseSection(entry: entry)
            }

            Section {
                Button {
                    showingPicker = true
                } label: {
                    Label("Add exercises", systemImage: "plus")
                }
                Button("Discard workout", role: .destructive) {
                    confirmingDiscard = true
                }
            }
        }
        .navigationTitle("Workout")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Finish") { confirmingFinish = true }
                    .bold()
            }
        }
        .safeAreaInset(edge: .bottom) {
            RestTimerBar()
        }
        .sheet(isPresented: $showingPicker) {
            ExercisePickerView { selected in
                var order = (workout.sortedExercises.last?.order ?? -1) + 1
                for exercise in selected {
                    WorkoutStarter.addExercise(exercise, to: workout, order: order, in: context)
                    order += 1
                }
            }
        }
        .confirmationDialog("Finish this workout?", isPresented: $confirmingFinish, titleVisibility: .visible) {
            Button("Finish workout") { finish() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sets you haven't checked off will be removed.")
        }
        .confirmationDialog("Discard this workout?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard workout", role: .destructive) { discard() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func finish() {
        var anyDone = false
        for entry in workout.sortedExercises {
            let sets = entry.sortedSets
            let hasDoneSet = sets.contains { $0.isDone }
            anyDone = anyDone || hasDoneSet
            if hasDoneSet {
                for set in sets where !set.isDone {
                    context.delete(set)
                }
            } else {
                context.delete(entry)
            }
        }
        restTimer.stop()
        if anyDone {
            workout.endDate = .now
        } else {
            context.delete(workout)
        }
        try? context.save()
    }

    private func discard() {
        restTimer.stop()
        context.delete(workout)
        try? context.save()
    }
}

struct WorkoutExerciseSection: View {
    @Bindable var entry: WorkoutExercise
    @Environment(\.modelContext) private var context
    @Environment(RestTimer.self) private var restTimer
    @AppStorage(WeightUnit.storageKey) private var unit: WeightUnit = .kg

    var body: some View {
        let sets = entry.sortedSets
        let labels = Self.labels(for: sets)
        let previousSets = entry.exercise?.completedEntries.first?.completedSets ?? []

        Section {
            SetHeaderRow(unit: unit)
            ForEach(Array(sets.enumerated()), id: \.element.id) { index, set in
                SetRowView(workoutSet: set,
                           label: labels[index],
                           previous: index < previousSets.count ? previousSets[index] : nil,
                           unit: unit) {
                    restTimer.start(seconds: entry.exercise?.restSeconds ?? 90)
                }
            }
            .onDelete { offsets in
                for index in offsets {
                    context.delete(sets[index])
                }
            }
            Button {
                addSet()
            } label: {
                Label("Add set", systemImage: "plus")
                    .font(.subheadline)
            }
        } header: {
            HStack {
                Text(entry.exercise?.name ?? "Exercise")
                    .font(.headline)
                    .foregroundStyle(.tint)
                    .textCase(nil)
                Spacer()
                Menu {
                    Button("Remove exercise", role: .destructive) {
                        context.delete(entry)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .imageScale(.large)
                }
            }
        }
    }

    private func addSet() {
        let last = entry.sortedSets.last
        let set = WorkoutSet(order: (last?.order ?? -1) + 1,
                             weightKg: last?.weightKg ?? 0,
                             reps: last?.reps ?? 0)
        context.insert(set)
        set.workoutExercise = entry
    }

    /// Working sets are numbered 1, 2, 3; other set types show a letter.
    static func labels(for sets: [WorkoutSet]) -> [String] {
        var number = 0
        return sets.map { set in
            if set.setType == .normal || set.setType == .failure {
                number += 1
                return set.setType == .failure ? "\(number)F" : "\(number)"
            }
            return set.setType.shortLabel
        }
    }
}

struct SetHeaderRow: View {
    let unit: WeightUnit

    var body: some View {
        HStack(spacing: 8) {
            Text("Set").frame(width: 32)
            Text("Previous").frame(maxWidth: .infinity)
            Text(unit.rawValue).frame(width: 64)
            Text("Reps").frame(width: 48)
            Image(systemName: "checkmark").frame(width: 32)
        }
        .font(.caption.bold())
        .foregroundStyle(.secondary)
    }
}

struct SetRowView: View {
    @Bindable var workoutSet: WorkoutSet
    let label: String
    let previous: WorkoutSet?
    let unit: WeightUnit
    let onComplete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Set type", selection: $workoutSet.setType) {
                    ForEach(SetType.allCases) { type in
                        Text(type.title).tag(type)
                    }
                }
            } label: {
                Text(label)
                    .font(.subheadline.bold())
                    .foregroundStyle(workoutSet.setType == .warmup ? Color.orange : Color.primary)
                    .frame(width: 32)
            }
            .buttonStyle(.borderless)

            Button {
                if let previous {
                    workoutSet.weightKg = previous.weightKg
                    workoutSet.reps = previous.reps
                }
            } label: {
                Text(previousText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)

            TextField("0", value: weightBinding, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)

            TextField("0", value: $workoutSet.reps, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .frame(width: 48)

            Button {
                toggleDone()
            } label: {
                Image(systemName: workoutSet.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(workoutSet.isDone ? Color.green : Color.secondary)
            }
            .buttonStyle(.borderless)
            .frame(width: 32)
        }
        .listRowBackground(workoutSet.isDone ? Color.green.opacity(0.12) : nil)
    }

    private var previousText: String {
        guard let previous else { return "–" }
        return "\(unit.format(kg: previous.weightKg)) × \(previous.reps)"
    }

    private var weightBinding: Binding<Double> {
        Binding(
            get: { (unit.fromKg(workoutSet.weightKg) * 100).rounded() / 100 },
            set: { workoutSet.weightKg = unit.toKg($0) }
        )
    }

    private func toggleDone() {
        workoutSet.isDone.toggle()
        if workoutSet.isDone {
            workoutSet.completedAt = .now
            onComplete()
        } else {
            workoutSet.completedAt = nil
        }
    }
}

struct RestTimerBar: View {
    @Environment(RestTimer.self) private var timer

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            let remaining = timer.remaining(at: timeline.date)
            if remaining > 0 {
                HStack(spacing: 12) {
                    Button("−15") { timer.adjust(by: -15) }
                    VStack(spacing: 4) {
                        Text("Rest \((remaining + 0.99).clockString)")
                            .font(.headline.monospacedDigit())
                        ProgressView(value: min(remaining, Double(timer.totalSeconds)),
                                     total: Double(max(timer.totalSeconds, 1)))
                    }
                    Button("+15") { timer.adjust(by: 15) }
                    Button("Skip") { timer.stop() }
                }
                .buttonStyle(.bordered)
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.regularMaterial)
            }
        }
    }
}
