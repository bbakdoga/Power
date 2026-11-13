import SwiftUI
import SwiftData

struct ActiveWorkoutView: View {
    @Bindable var workout: Workout
    @Environment(\.modelContext) private var context
    @Environment(RestTimer.self) private var restTimer
    @State private var showingPicker = false
    @State private var confirmingFinish = false
    @State private var confirmingDiscard = false
    @State private var showingNothingToSave = false
    @State private var recordBanner: RecordBanner?
    @AppStorage(HealthSync.enabledKey) private var healthEnabled = false

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
                WorkoutExerciseSection(entry: entry) { banner in
                    withAnimation(.spring(duration: 0.4)) { recordBanner = banner }
                }
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
                Button("Finish") {
                    if hasCheckedSets || hasUncheckedLoggedSets {
                        withAnimation(.spring(duration: 0.3)) { confirmingFinish = true }
                    } else {
                        showingNothingToSave = true
                    }
                }
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
        .overlay(alignment: .top) {
            if let recordBanner, !confirmingFinish {
                RecordBannerView(banner: recordBanner)
                    .onTapGesture { dismissRecordBanner() }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: recordBanner.id) {
                        try? await Task.sleep(for: .seconds(3.5))
                        dismissRecordBanner()
                    }
            }
        }
        .sensoryFeedback(.success, trigger: recordBanner?.id) { _, new in new != nil }
        .overlay(alignment: .top) {
            if confirmingFinish {
                finishPrompt
            }
        }
        .alert("Nothing to save yet", isPresented: $showingNothingToSave) {
            Button("Keep training", role: .cancel) {}
            Button("Discard workout", role: .destructive) { discard() }
        } message: {
            Text("Enter reps for at least one set, or tap the circle to check it off.")
        }
        .confirmationDialog("Discard this workout?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard workout", role: .destructive) { discard() }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Custom box at the top of the screen; system dialogs can't use green or gray buttons.
    private var finishPrompt: some View {
        let hasUnfinished = workout.sortedExercises.contains { entry in
            entry.sortedSets.contains { !$0.isDone }
        }

        return ZStack(alignment: .top) {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { dismissFinishPrompt() }
                .transition(.opacity)

            VStack(spacing: 12) {
                Text(hasUnfinished ? "You have unfinished sets" : "Finish workout?")
                    .font(.headline)
                Text(!hasUnfinished ? "It will appear in your History."
                     : hasCheckedSets ? "Sets without reps are always removed."
                     : "No sets are checked off, so ignoring them discards this workout.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if hasUncheckedLoggedSets || !hasUnfinished {
                    promptButton(hasUnfinished ? "Complete Unfinished Sets" : "Save Workout", tint: .green) {
                        finish(includeUnchecked: true)
                    }
                }
                if hasUnfinished {
                    promptButton("Ignore Unfinished Sets", tint: .red) {
                        finish(includeUnchecked: false)
                    }
                }
                promptButton("Cancel", tint: .gray) {
                    dismissFinishPrompt()
                }
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
            .shadow(radius: 20)
            .padding(.horizontal)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func promptButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
    }

    private func dismissRecordBanner() {
        withAnimation(.easeOut(duration: 0.3)) { recordBanner = nil }
    }

    private func dismissFinishPrompt() {
        withAnimation(.spring(duration: 0.3)) { confirmingFinish = false }
    }

    private var hasCheckedSets: Bool {
        workout.sortedExercises.contains { entry in entry.sortedSets.contains(where: \.isDone) }
    }

    /// Sets with reps entered that the user didn't tap the checkmark on.
    private var hasUncheckedLoggedSets: Bool {
        workout.sortedExercises.contains { entry in
            entry.sortedSets.contains { !$0.isDone && $0.reps > 0 }
        }
    }

    private func finish(includeUnchecked: Bool) {
        confirmingFinish = false
        var anyDone = false
        for entry in workout.sortedExercises {
            if includeUnchecked {
                for set in entry.sortedSets where !set.isDone && set.reps > 0 {
                    set.isDone = true
                    set.completedAt = .now
                }
            }
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
            let end = Date.now
            workout.endDate = end
            if healthEnabled {
                HealthSync.shared.saveWorkout(start: workout.startDate, end: end)
            }
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

struct RecordBanner: Identifiable {
    let id = UUID()
    let exerciseName: String
    let details: [String]
}

/// Celebration shown at the top of the workout when a set beats a personal record.
struct RecordBannerView: View {
    let banner: RecordBanner

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "trophy.fill")
                .font(.title)
                .foregroundStyle(.yellow)
                .symbolEffect(.bounce, value: banner.id)
            VStack(alignment: .leading, spacing: 2) {
                Text("New record!")
                    .font(.headline)
                Text(banner.exerciseName)
                    .font(.subheadline.bold())
                    .foregroundStyle(.tint)
                ForEach(banner.details, id: \.self) { detail in
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.yellow.opacity(0.6), lineWidth: 1.5))
        .shadow(radius: 12)
        .padding(.horizontal)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }
}

struct WorkoutExerciseSection: View {
    @Bindable var entry: WorkoutExercise
    var onRecord: (RecordBanner) -> Void = { _ in }
    @Environment(\.modelContext) private var context
    @Environment(RestTimer.self) private var restTimer
    @AppStorage(WeightUnit.storageKey) private var appUnit: WeightUnit = .kg
    @AppStorage("showWeightSuggestions") private var showSuggestions = true
    @State private var showingNote = false
    @State private var showingStickyNote = false
    @State private var editingRest = false
    @State private var replacing = false
    @State private var showingMetrics = false
    @FocusState private var focusedNote: NoteKind?

    private enum NoteKind { case workout, sticky }

    var body: some View {
        let sets = entry.sortedSets
        let labels = Self.labels(for: sets)
        let previousSets = entry.exercise?.completedEntries.first?.completedSets ?? []
        let restSeconds = entry.exercise?.restSeconds ?? 0
        let showsRest = restSeconds > 0 && WorkoutStarter.shouldRest(after: entry)

        Section {
            if let exercise = entry.exercise, showingStickyNote || !exercise.notes.isEmpty {
                noteRow(text: Binding(get: { exercise.notes }, set: { exercise.notes = $0 }),
                        prompt: "Sticky note (shown every time)", systemImage: "pin.fill", tint: .yellow, kind: .sticky)
            }
            if showingNote || !entry.notes.isEmpty {
                noteRow(text: $entry.notes, prompt: "Note for this workout",
                        systemImage: "note.text", tint: .secondary, kind: .workout)
            }
            if showSuggestions, let suggestion = WeightSuggestion.make(for: entry, unit: unit) {
                suggestionRow(suggestion)
            }
            SetHeaderRow(unit: unit)
            ForEach(Array(sets.enumerated()), id: \.element.id) { index, set in
                VStack(spacing: 8) {
                    SetRowView(workoutSet: set,
                               label: labels[index],
                               previous: index < previousSets.count ? previousSets[index] : nil,
                               unit: unit,
                               isRecord: !PersonalRecords.newRecords(for: set).isEmpty) {
                        if WorkoutStarter.shouldRest(after: entry) {
                            restTimer.start(seconds: restSeconds, exerciseName: entry.exercise?.name ?? "")
                        }
                        celebrateRecords(for: set)
                    }
                    if showsRest {
                        RestDivider(seconds: restSeconds) { editingRest = true }
                    }
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
                Label(showsRest ? "Add set (\(restSeconds.restLabel))" : "Add set", systemImage: "plus")
                    .font(.subheadline)
            }
        } header: {
            HStack {
                if let id = entry.supersetID, let letter = entry.workout?.supersetLetters[id] {
                    Text("Superset \(letter)")
                        .font(.caption.bold())
                        .textCase(nil)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.purple))
                }
                Text(entry.exercise?.name ?? "Exercise")
                    .font(.headline)
                    .foregroundStyle(.tint)
                    .textCase(nil)
                Spacer()
                Button {
                    showingMetrics = true
                } label: {
                    Image(systemName: "chart.line.uptrend.xyaxis.circle")
                        .imageScale(.large)
                }
                .accessibilityLabel("Focus metrics")
                .popover(isPresented: $showingMetrics) {
                    FocusMetricsView(entry: entry, unit: unit)
                        .presentationCompactAdaptation(.popover)
                }
                exerciseMenu
            }
            .sheet(isPresented: $editingRest) {
                if let exercise = entry.exercise {
                    RestTimePicker(exercise: exercise)
                }
            }
            .sheet(isPresented: $replacing) {
                ExercisePickerView(singleSelection: true) { selected in
                    if let replacement = selected.first { entry.exercise = replacement }
                }
            }
        }
    }

    /// This exercise's own unit if it has one, otherwise the app setting.
    private var unit: WeightUnit {
        entry.exercise?.unit(default: appUnit) ?? appUnit
    }

    private var exerciseMenu: some View {
        Menu {
            Button {
                showingNote = true
                focusedNote = .workout
            } label: {
                Label("Add Note", systemImage: "note.text")
            }
            Button {
                showingStickyNote = true
                focusedNote = .sticky
            } label: {
                Label("Add Sticky Note", systemImage: "pin")
            }
            Button {
                addWarmUpSets()
            } label: {
                Label("Add Warm-up Sets", systemImage: "plusminus")
            }
            .disabled(!canAddWarmUps)
            Button {
                editingRest = true
            } label: {
                Label("Update Rest Timer", systemImage: "timer")
            }
            Button {
                replacing = true
            } label: {
                Label("Replace Exercise", systemImage: "arrow.uturn.backward")
            }
            if !isLastExercise {
                Button {
                    WorkoutStarter.supersetWithNext(entry)
                } label: {
                    Label(entry.supersetID == nil ? "Create Superset" : "Add Next to Superset", systemImage: "link")
                }
            }
            if entry.supersetID != nil {
                Button {
                    WorkoutStarter.removeFromSuperset(entry)
                } label: {
                    Label("Remove from Superset", systemImage: "xmark")
                }
            }
            Menu {
                if let exercise = entry.exercise {
                    Picker(selection: Binding(
                        get: { exercise.unitRaw },
                        set: { exercise.unitRaw = $0 })) {
                        Text("App Default (\(appUnit.rawValue))").tag(String?.none)
                        ForEach(WeightUnit.allCases) { option in
                            Text(option.rawValue).tag(Optional(option.rawValue))
                        }
                    } label: {
                        Label("Weight Unit: \(unit.rawValue)", systemImage: "scalemass")
                    }
                    .pickerStyle(.menu)
                    Toggle("Auto Rest Timer", isOn: Binding(
                        get: { exercise.restSeconds > 0 },
                        set: { exercise.restSeconds = $0 ? 90 : 0 }))
                }
                Toggle("Weight Suggestions", isOn: $showSuggestions)
            } label: {
                Label("Preferences", systemImage: "slider.horizontal.3")
            }
            Divider()
            Button(role: .destructive) {
                WorkoutStarter.removeFromSuperset(entry)
                context.delete(entry)
            } label: {
                Label("Delete Exercise", systemImage: "xmark")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .imageScale(.large)
        }
        .accessibilityLabel("Exercise options")
    }

    private func noteRow(text: Binding<String>, prompt: String, systemImage: String,
                         tint: Color, kind: NoteKind) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            TextField(prompt, text: text, axis: .vertical)
                .font(.subheadline)
                .focused($focusedNote, equals: kind)
        }
        .listRowBackground(kind == .sticky ? Color.yellow.opacity(0.12) : nil)
    }

    /// Warm-ups ramp up to the first working set: 40% × 8, 60% × 5, 80% × 3.
    private var canAddWarmUps: Bool {
        let sets = entry.sortedSets
        return !sets.contains { $0.setType == .warmup }
            && (sets.first { $0.setType != .warmup }?.weightKg ?? 0) > 0
    }

    private func addWarmUpSets() {
        let sets = entry.sortedSets
        guard let workingWeight = sets.first(where: { $0.setType != .warmup })?.weightKg, workingWeight > 0 else { return }
        let step = unit.toKg(unit == .kg ? 2.5 : 5)
        var warmUps: [(Double, Int)] = []
        for (percent, reps) in [(0.4, 8), (0.6, 5), (0.8, 3)] {
            let weight = ((workingWeight * percent) / step).rounded() * step
            if weight > 0, weight < workingWeight, warmUps.last?.0 != weight {
                warmUps.append((weight, reps))
            }
        }
        for set in sets { set.order += warmUps.count }
        for (index, warmUp) in warmUps.enumerated() {
            let set = WorkoutSet(order: index, weightKg: warmUp.0, reps: warmUp.1)
            set.setType = .warmup
            context.insert(set)
            set.workoutExercise = entry
        }
    }

    private var isLastExercise: Bool {
        entry.workout?.sortedExercises.last == entry
    }

    private func suggestionRow(_ suggestion: WeightSuggestion) -> some View {
        let pending = entry.sortedSets.filter { !$0.isDone && $0.setType != .warmup }
        let alreadyApplied = pending.allSatisfy { $0.weightKg == suggestion.suggestedWeightKg }

        return HStack(spacing: 10) {
            Image(systemName: suggestion.isIncrease ? "arrow.up.circle.fill" : "equal.circle.fill")
                .font(.title3)
                .foregroundStyle(suggestion.isIncrease ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Last time \(unit.format(kg: suggestion.lastWeightKg)) \(unit.rawValue) × \(suggestion.lastReps)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(suggestion.isIncrease
                     ? "Try \(unit.format(kg: suggestion.suggestedWeightKg)) \(unit.rawValue) today"
                     : "Stay at \(unit.format(kg: suggestion.suggestedWeightKg)) \(unit.rawValue), aim for \(suggestion.targetReps) reps on every set")
                    .font(.subheadline.weight(.medium))
            }
            Spacer(minLength: 0)
            if !pending.isEmpty && !alreadyApplied {
                Button("Use") {
                    for set in pending {
                        set.weightKg = suggestion.suggestedWeightKg
                        if set.reps == 0 { set.reps = suggestion.targetReps }
                    }
                }
                .buttonStyle(.bordered)
                .font(.subheadline)
            }
        }
    }

    private func celebrateRecords(for set: WorkoutSet) {
        let records = PersonalRecords.newRecords(for: set)
        guard !records.isEmpty else { return }
        let details = records.map { kind -> String in
            switch kind {
            case .heaviestWeight: return "\(kind.title): \(unit.format(kg: set.weightKg)) \(unit.rawValue)"
            case .oneRepMax: return "\(kind.title): \(unit.format(kg: set.estimatedOneRepMaxKg)) \(unit.rawValue)"
            case .mostReps: return "\(kind.title): \(set.reps)"
            }
        }
        onRecord(RecordBanner(exerciseName: entry.exercise?.name ?? "Exercise", details: details))
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

/// Thin line with the rest time between sets; tap to change it.
struct RestDivider: View {
    let seconds: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Capsule().fill(Color.accentColor.opacity(0.35)).frame(height: 3)
                Text(seconds.restLabel)
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(.tint)
                Capsule().fill(Color.accentColor.opacity(0.35)).frame(height: 3)
            }
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Rest \(seconds.restLabel). Change rest time")
    }
}

struct RestTimePicker: View {
    @Bindable var exercise: Exercise
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Picker("Rest time", selection: $exercise.restSeconds) {
                ForEach(Array(stride(from: 0, through: 600, by: 15)), id: \.self) { seconds in
                    Text(seconds.restLabel).tag(seconds)
                }
            }
            .pickerStyle(.wheel)
            .navigationTitle("Rest Timer · \(exercise.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(300)])
    }
}

/// Live stats for this exercise in the current workout, compared with last time.
struct FocusMetricsView: View {
    let entry: WorkoutExercise
    let unit: WeightUnit

    var body: some View {
        let working = entry.completedSets.filter { $0.setType != .warmup }
        let volume = entry.volumeKg
        let reps = working.reduce(0) { $0 + $1.reps }
        let lastVolume = entry.exercise?.completedEntries.first?.volumeKg ?? 0

        VStack(alignment: .leading, spacing: 14) {
            Text("Focus Metrics")
                .font(.headline)
            metric("Total Volume", volume > 0 ? weightText(volume) : "N/A")
            metric("Volume vs. Last Time", volume > 0 && lastVolume > 0
                   ? ((volume - lastVolume) / lastVolume).formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always()))
                   : "N/A")
            metric("Total Reps", reps > 0 ? "\(reps)" : "N/A")
            metric("Weight per Rep", reps > 0 && volume > 0 ? weightText(volume / Double(reps)) : "N/A")
            Text("Counts checked-off working sets.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 280)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.bold())
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func weightText(_ kilograms: Double) -> String {
        "\(unit.format(kg: kilograms)) \(unit.rawValue)"
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
    var isRecord = false
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
                    .overlay(alignment: .topTrailing) {
                        if isRecord {
                            Image(systemName: "trophy.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.yellow)
                                .offset(x: 2, y: -6)
                                .accessibilityLabel("Personal record")
                        }
                    }
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
