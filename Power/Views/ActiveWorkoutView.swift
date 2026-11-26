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
            .themedRows()

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
            }
            .themedRows()
        }
        .navigationTitle("Workout")
        .themedScreen()
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .destructive) {
                    confirmingDiscard = true
                }
                .tint(.red)
                .accessibilityHint("Discard workout")
                // Attached to the button so the popover points at Cancel, not the screen.
                .confirmationDialog("Discard this workout?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                    Button("Discard workout", role: .destructive) { discard() }
                    Button("Cancel", role: .cancel) {}
                }
            }
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
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
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
                Text("Save this workout?")
                    .font(.headline)
                Text(summaryText)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                if hasUnfinished {
                    Text("Some sets aren't checked off. Sets without reps are always removed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if !hasUnfinished {
                    promptButton("Save Workout", tint: .green) {
                        finish(includeUnchecked: true, saveToHistory: true)
                    }
                } else {
                    if hasUncheckedLoggedSets {
                        promptButton("Save & Complete Unfinished Sets", tint: .green) {
                            finish(includeUnchecked: true, saveToHistory: true)
                        }
                    }
                    if hasCheckedSets {
                        promptButton("Save Only Checked Sets", tint: .blue) {
                            finish(includeUnchecked: false, saveToHistory: true)
                        }
                    }
                }
                promptButton("Don't Save", tint: .red) {
                    finish(includeUnchecked: true, saveToHistory: false)
                }
                promptButton("Keep Training", tint: .gray) {
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

    private func promptButton(_ title: LocalizedStringKey, tint: Color, action: @escaping () -> Void) -> some View {
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

    /// "48:12 · 5 exercises · 17 sets" for the save prompt.
    private var summaryText: String {
        let entries = workout.sortedExercises
        let sets = entries.reduce(0) { total, entry in
            total + entry.sortedSets.filter { $0.isDone || $0.hasData }.count
        }
        let elapsed = Date.now.timeIntervalSince(workout.startDate).clockString
        return "\(elapsed) · \(entries.count == 1 ? "1 exercise" : "\(entries.count) exercises") · \(sets == 1 ? "1 set" : "\(sets) sets")"
    }

    private var hasCheckedSets: Bool {
        workout.sortedExercises.contains { entry in entry.sortedSets.contains(where: \.isDone) }
    }

    /// Sets with reps entered that the user didn't tap the checkmark on.
    private var hasUncheckedLoggedSets: Bool {
        workout.sortedExercises.contains { entry in
            entry.sortedSets.contains { !$0.isDone && $0.hasData }
        }
    }

    private func finish(includeUnchecked: Bool, saveToHistory: Bool) {
        confirmingFinish = false
        workout.isSavedToHistory = saveToHistory
        var anyDone = false
        for entry in workout.sortedExercises {
            if includeUnchecked {
                for set in entry.sortedSets where !set.isDone && set.hasData {
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
            WorkoutSettingsSnapshot.clear()
            if healthEnabled {
                HealthSync.shared.saveWorkout(start: workout.startDate, end: end)
            }
        } else {
            // Nothing to save, so treat it like a cancel.
            WorkoutSettingsSnapshot.restore(for: workout, in: context)
            context.delete(workout)
        }
        try? context.save()
    }

    /// Cancel: delete the workout and undo exercise setting changes made during it.
    private func discard() {
        restTimer.stop()
        WorkoutSettingsSnapshot.restore(for: workout, in: context)
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
    @AppStorage(WorkoutSettingsSnapshot.showSuggestionsKey) private var showSuggestions = true
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
            if showSuggestions, tracking == .weightReps, let suggestion = WeightSuggestion.make(for: entry, unit: unit) {
                suggestionRow(suggestion)
            }
            SetHeaderRow(unit: unit, tracking: tracking)
            ForEach(Array(sets.enumerated()), id: \.element.id) { index, set in
                VStack(spacing: 8) {
                    SetRowView(workoutSet: set,
                               label: labels[index],
                               previous: index < previousSets.count ? previousSets[index] : nil,
                               unit: unit,
                               tracking: tracking,
                               isRecord: !PersonalRecords.newRecords(for: set).isEmpty) {
                        if WorkoutStarter.shouldRest(after: entry) {
                            restTimer.start(seconds: restSeconds, exerciseName: entry.exercise?.name ?? "",
                                            setID: set.persistentModelID)
                        }
                        celebrateRecords(for: set)
                    }
                    if showsRest {
                        RestDivider(seconds: restSeconds, setID: set.persistentModelID) { editingRest = true }
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
                Text(entry.exercise?.name ?? String(localized: "Exercise"))
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
                    if let replacement = selected.first {
                        rememberSettings(of: replacement)
                        entry.exercise = replacement
                    }
                }
            }
        }
        .themedRows()
        .onAppear {
            if let exercise = entry.exercise { rememberSettings(of: exercise) }
        }
    }

    /// Lets Cancel undo setting changes made during this workout.
    private func rememberSettings(of exercise: Exercise) {
        if let workout = entry.workout {
            WorkoutSettingsSnapshot.remember(exercise, in: workout)
        }
    }

    private var tracking: TrackingType { entry.exercise?.tracking ?? .weightReps }

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
        return tracking == .weightReps
            && !sets.contains { $0.setType == .warmup }
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
                     ? String(localized: "Try \(unit.format(kg: suggestion.suggestedWeightKg)) \(unit.rawValue) today")
                     : String(localized: "Stay at \(unit.format(kg: suggestion.suggestedWeightKg)) \(unit.rawValue), aim for \(suggestion.targetReps) reps on every set"))
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
            case .longestTime: return "\(kind.title): \(set.durationSeconds.clockString)"
            case .longestDistance:
                return "\(kind.title): \(Distance.format(meters: set.distanceMeters, scale: tracking == .weightDistance ? .short : .long, unit: unit))"
            }
        }
        onRecord(RecordBanner(exerciseName: entry.exercise?.name ?? "Exercise", details: details))
    }

    private func addSet() {
        let last = entry.sortedSets.last
        let set = WorkoutSet(order: (last?.order ?? -1) + 1)
        if let last { set.copyValues(from: last) }
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
/// Thin line with the rest time between sets; tap to change it. Under the set that
/// started the current rest, it counts down and the line shrinks toward the time.
struct RestDivider: View {
    let seconds: Int
    let setID: PersistentIdentifier
    let onTap: () -> Void
    @Environment(RestTimer.self) private var timer

    var body: some View {
        Button(action: onTap) {
            if timer.setID == setID {
                TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
                    let remaining = timer.remaining(at: timeline.date)
                    if remaining > 0 {
                        line(label: (remaining + 0.99).clockString,
                             fraction: min(remaining / Double(max(timer.totalSeconds, 1)), 1))
                    } else {
                        line(label: seconds.restLabel, fraction: 1)
                    }
                }
            } else {
                line(label: seconds.restLabel, fraction: 1)
            }
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Rest \(seconds.restLabel). Change rest time")
    }

    /// Two halves around the label; each fills from the label outward by `fraction`.
    private func line(label: String, fraction: Double) -> some View {
        let counting = fraction < 1
        return HStack(spacing: 8) {
            bar(fraction: fraction, alignment: .trailing, counting: counting)
            Text(label)
                .font(.caption.bold().monospacedDigit())
                .foregroundStyle(.tint)
                .contentTransition(.numericText(countsDown: true))
            bar(fraction: fraction, alignment: .leading, counting: counting)
        }
    }

    private func bar(fraction: Double, alignment: Alignment, counting: Bool) -> some View {
        Capsule()
            .fill(.tint.opacity(counting ? 0.15 : 0.35))
            .overlay(alignment: alignment) {
                if counting {
                    GeometryReader { geometry in
                        Capsule()
                            .fill(.tint)
                            .frame(width: geometry.size.width * fraction)
                            .frame(maxWidth: .infinity, alignment: alignment)
                    }
                }
            }
            .frame(height: 3)
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
        let tracking = entry.exercise?.tracking ?? .weightReps
        if tracking == .weightReps {
            strengthMetrics
        } else {
            enduranceMetrics(tracking)
        }
    }

    /// Time and distance totals for timed or distance exercises.
    private func enduranceMetrics(_ tracking: TrackingType) -> some View {
        let working = entry.completedSets.filter { $0.setType != .warmup }
        let time = working.reduce(0) { $0 + $1.durationSeconds }
        let distance = working.reduce(0) { $0 + $1.distanceMeters }
        let scale: Distance.Scale = tracking == .weightDistance ? .short : .long
        return VStack(alignment: .leading, spacing: 14) {
            Text("Focus Metrics")
                .font(.headline)
            metric("Sets", working.isEmpty ? String(localized: "N/A") : "\(working.count)")
            if tracking != .weightDistance {
                metric("Total Time", time > 0 ? time.clockString : String(localized: "N/A"))
            }
            if tracking != .duration {
                metric("Total Distance", distance > 0 ? Distance.format(meters: distance, scale: scale, unit: unit) : String(localized: "N/A"))
            }
            if tracking == .distanceDuration, time > 0, distance > 0 {
                let perUnit = time / Distance.value(meters: distance, scale: .long, unit: unit)
                metric("Pace", "\(perUnit.clockString) /\(Distance.symbol(.long, unit: unit))")
            }
            Text("Counts checked-off sets.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 280)
    }

    private var strengthMetrics: some View {
        let working = entry.completedSets.filter { $0.setType != .warmup }
        let volume = entry.volumeKg
        let reps = working.reduce(0) { $0 + $1.reps }
        let lastVolume = entry.exercise?.completedEntries.first?.volumeKg ?? 0

        return VStack(alignment: .leading, spacing: 14) {
            Text("Focus Metrics")
                .font(.headline)
            metric("Total Volume", volume > 0 ? weightText(volume) : String(localized: "N/A"))
            metric("Volume vs. Last Time", volume > 0 && lastVolume > 0
                   ? ((volume - lastVolume) / lastVolume).formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always()))
                   : String(localized: "N/A"))
            metric("Total Reps", reps > 0 ? "\(reps)" : String(localized: "N/A"))
            metric("Weight per Rep", reps > 0 && volume > 0 ? weightText(volume / Double(reps)) : String(localized: "N/A"))
            Text("Counts checked-off working sets.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 280)
    }

    private func metric(_ title: LocalizedStringKey, _ value: String) -> some View {
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
    var tracking: TrackingType = .weightReps

    var body: some View {
        HStack(spacing: 8) {
            Text("Set").frame(width: 32)
            Text("Previous").frame(maxWidth: .infinity)
            switch tracking {
            case .weightReps:
                Text(unit.rawValue).frame(width: 64)
                Text("Reps").frame(width: 48)
            case .duration:
                Text("Time").frame(width: 120)
            case .distanceDuration:
                Text(Distance.symbol(.long, unit: unit)).frame(width: 56)
                Text("Time").frame(width: 56)
            case .weightDistance:
                Text(unit.rawValue).frame(width: 56)
                Text(Distance.symbol(.short, unit: unit)).frame(width: 56)
            }
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
    var tracking: TrackingType = .weightReps
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
                    workoutSet.copyValues(from: previous)
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

            switch tracking {
            case .weightReps:
                NumberField(value: weightBinding, allowsDecimals: true)
                    .frame(width: 64)
                    .accessibilityLabel("Weight, \(unit.rawValue)")
                NumberField(value: repsBinding, allowsDecimals: false)
                    .frame(width: 48)
                    .accessibilityLabel("Repetitions")
            case .duration:
                DurationField(seconds: $workoutSet.durationSeconds)
                    .frame(width: 120)
                    .accessibilityLabel("Time")
            case .distanceDuration:
                NumberField(value: distanceBinding(.long), allowsDecimals: true)
                    .frame(width: 56)
                    .accessibilityLabel("Distance, \(Distance.symbol(.long, unit: unit))")
                DurationField(seconds: $workoutSet.durationSeconds)
                    .frame(width: 56)
                    .accessibilityLabel("Time")
            case .weightDistance:
                NumberField(value: weightBinding, allowsDecimals: true)
                    .frame(width: 56)
                    .accessibilityLabel("Weight, \(unit.rawValue)")
                NumberField(value: distanceBinding(.short), allowsDecimals: false)
                    .frame(width: 56)
                    .accessibilityLabel("Distance, \(Distance.symbol(.short, unit: unit))")
            }

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
        return tracking == .weightReps
            ? "\(unit.format(kg: previous.weightKg)) × \(previous.reps)"
            : previous.summary(tracking, unit: unit)
    }

    private var weightBinding: Binding<Double> {
        Binding(
            get: { (unit.fromKg(workoutSet.weightKg) * 100).rounded() / 100 },
            set: { workoutSet.weightKg = unit.toKg($0) }
        )
    }

    private func distanceBinding(_ scale: Distance.Scale) -> Binding<Double> {
        Binding(
            get: { (Distance.value(meters: workoutSet.distanceMeters, scale: scale, unit: unit) * 100).rounded() / 100 },
            set: { workoutSet.distanceMeters = $0 * Distance.metersPerUnit(scale, unit: unit) }
        )
    }

    private var repsBinding: Binding<Double> {
        Binding(
            get: { Double(workoutSet.reps) },
            set: { workoutSet.reps = max(Int($0), 0) }
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

/// Number box that saves on every keystroke. `TextField(value:format:)` only commits
/// when editing ends, and the number pad has no return key, so typed values were lost
/// when the user tapped the checkmark or scrolled with the keyboard still up.
struct NumberField: View {
    @Binding var value: Double
    let allowsDecimals: Bool
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("0", text: $text)
            .keyboardType(allowsDecimals ? .decimalPad : .numberPad)
            .multilineTextAlignment(.center)
            .textFieldStyle(.roundedBorder)
            .monospacedDigit()
            .focused($focused)
            .onAppear { text = Self.display(value) }
            .onChange(of: text) { _, newText in
                let parsed = Self.parse(newText) ?? 0
                if parsed != value { value = parsed }
            }
            .onChange(of: value) { _, newValue in
                // Changed elsewhere (e.g. tapping "Previous"); don't fight the user's typing.
                if (Self.parse(text) ?? 0) != newValue { text = Self.display(newValue) }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { text = Self.display(value) }
            }
    }

    /// Accepts both "62.5" and "62,5", whatever the keyboard's decimal separator is.
    static func parse(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    /// Empty for 0 so there's nothing to delete before typing.
    static func display(_ value: Double) -> String {
        value == 0 ? "" : value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
    }
}

/// Time box with digit-shift entry like a microwave: typing 1, 3, 0 shows 1:30.
struct DurationField: View {
    @Binding var seconds: Double
    @State private var digits = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("0:00", text: Binding(get: { Self.display(digits) }, set: { newText in
            digits = String(newText.filter(\.isNumber).drop { $0 == "0" }.suffix(6))
        }))
        .keyboardType(.numberPad)
        .multilineTextAlignment(.center)
        .textFieldStyle(.roundedBorder)
        .monospacedDigit()
        .focused($focused)
        .onAppear { digits = Self.digits(for: seconds) }
        .onChange(of: digits) { _, newDigits in
            let parsed = Self.seconds(from: newDigits)
            if parsed != seconds { seconds = parsed }
        }
        .onChange(of: seconds) { _, newValue in
            if Self.seconds(from: digits) != newValue { digits = Self.digits(for: newValue) }
        }
        .onChange(of: focused) { _, isFocused in
            // "0:90" becomes "1:30" once you're done typing.
            if !isFocused { digits = Self.digits(for: seconds) }
        }
    }

    /// Digits read from the right: seconds, minutes, hours ("130" → 90 s, "10000" → 1 h).
    static func seconds(from digits: String) -> Double {
        let values = digits.compactMap(\.wholeNumberValue)
        var total = 0
        for (position, multiplier) in [1, 10, 60, 600, 3600, 36000].enumerated() where position < values.count {
            total += values[values.count - 1 - position] * multiplier
        }
        return Double(total)
    }

    static func digits(for seconds: Double) -> String {
        guard seconds > 0 else { return "" }
        let total = Int(seconds)
        let text = String(format: "%d%02d%02d", total / 3600, (total % 3600) / 60, total % 60)
        return String(text.drop { $0 == "0" })
    }

    /// "130" → "1:30", "5" → "0:05", "10000" → "1:00:00".
    static func display(_ digits: String) -> String {
        guard !digits.isEmpty else { return "" }
        let padded = String(repeating: "0", count: max(0, 3 - digits.count)) + digits
        var parts: [String] = []
        var rest = Substring(padded)
        while rest.count > 2 {
            parts.insert(String(rest.suffix(2)), at: 0)
            rest = rest.dropLast(2)
        }
        parts.insert(String(rest), at: 0)
        return parts.joined(separator: ":")
    }
}

struct RestTimerBar: View {
    @Environment(RestTimer.self) private var timer

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            let remaining = timer.remaining(at: timeline.date)
            if remaining > 0 {
                HStack(spacing: 12) {
                    Button("−10") { timer.adjust(by: -10) }
                    VStack(spacing: 4) {
                        Text("Rest \((remaining + 0.99).clockString)")
                            .font(.headline.monospacedDigit())
                        ProgressView(value: min(remaining, Double(timer.totalSeconds)),
                                     total: Double(max(timer.totalSeconds, 1)))
                    }
                    Button("+10") { timer.adjust(by: 10) }
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
