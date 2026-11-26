import SwiftUI
import SwiftData

/// Start a workout and manage routines in one place. While a workout is running,
/// this tab shows it instead.
struct WorkoutTabView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Workout> { $0.endDate == nil }, sort: \Workout.startDate, order: .reverse)
    private var activeWorkouts: [Workout]
    @Query(sort: \Routine.name) private var routines: [Routine]
    @Query(sort: \TrainingProgram.createdAt, order: .reverse) private var programs: [TrainingProgram]
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .system
    @State private var showingMainRoutines = false
    @State private var programToDelete: TrainingProgram?
    @State private var path: [Routine] = []
    @State private var summary: FinishedWorkout?
    @State private var addingStarters = false
    @State private var buildingPlan = false
    @State private var choosingProProgram = false

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
        .sheet(isPresented: $addingStarters) {
            StarterRoutinesPicker(buttonTitle: String(localized: "Add Routines")) { addingStarters = false }
                .presentationDetents([.large])
        }
        .sheet(isPresented: $buildingPlan) {
            PlanSetupView(onFinish: { buildingPlan = false })
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $choosingProProgram) {
            ProProgramsView(onFinish: { choosingProProgram = false })
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            String(localized: "Delete \(programToDelete?.name ?? "")?"),
            isPresented: Binding(get: { programToDelete != nil }, set: { if !$0 { programToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Program and Routines", role: .destructive) {
                if let programToDelete { context.delete(programToDelete) }
            }
        } message: {
            Text("Its routines are deleted too. Finished workouts stay in History.")
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
            .themedRows()

            if let main = mainProgram {
                mainProgramSection(main)
            }

            if !otherPrograms.isEmpty {
                otherProgramsSection
            }

            Section {
                if routines.isEmpty {
                    Text("Tap + to plan a workout you do often, or save a finished workout as a routine.")
                        .foregroundStyle(.secondary)
                    Button {
                        addingStarters = true
                    } label: {
                        Label("Add starter routines", systemImage: "square.stack")
                    }
                }
                Button {
                    buildingPlan = true
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "sparkles")
                            .font(.title2.bold())
                            .frame(width: 52, height: 52)
                            .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(PlanCoach.isAvailable ? "Build a plan with Apple Intelligence" : "Build a plan for me")
                                .font(.headline)
                            Text("A training plan tailored to your goals and schedule.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.footnote.bold())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                Button {
                    choosingProProgram = true
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "trophy.fill")
                            .font(.title2.bold())
                            .frame(width: 52, height: 52)
                            .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Train like a pro")
                                .font(.headline)
                            Text("Programs inspired by famous bodybuilders, powerlifters and fitness creators.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.footnote.bold())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                ForEach(looseRoutines) { routine in
                    routineRow(routine)
                }
                .onDelete { offsets in
                    let loose = looseRoutines
                    for index in offsets {
                        context.delete(loose[index])
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
            .themedRows()
        }
        .navigationTitle("Workout")
        .themedScreen()
    }

    // MARK: - Programs

    private var mainProgram: TrainingProgram? { programs.first { $0.isMain } }
    private var otherPrograms: [TrainingProgram] { programs.filter { !$0.isMain } }
    /// Routines made by hand or saved from a workout, not part of a program.
    private var looseRoutines: [Routine] { routines.filter { $0.program == nil } }

    private func mainProgramSection(_ program: TrainingProgram) -> some View {
        Section {
            MainProgramCard(program: program,
                            showingRoutines: $showingMainRoutines,
                            onDelete: { programToDelete = program }) { routine in
                WorkoutStarter.start(routine: routine, in: context)
            }
            if showingMainRoutines {
                ForEach(program.sortedRoutines) { routine in
                    routineRow(routine, isNext: routine == program.nextRoutine)
                }
            }
        }
        .themedRows()
    }

    private var otherProgramsSection: some View {
        Section("Other programs") {
            ForEach(otherPrograms) { program in
                DisclosureGroup {
                    ForEach(program.sortedRoutines) { routine in
                        routineRow(routine)
                    }
                    Button {
                        withAnimation { program.makeMain(in: context) }
                    } label: {
                        Label("Make main program", systemImage: "star")
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(program.name)
                            .font(.headline)
                        Text("\(program.sortedRoutines.count) routines · \(program.daysPerWeek) days a week")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        programToDelete = program
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        withAnimation { program.makeMain(in: context) }
                    } label: {
                        Label("Make main", systemImage: "star")
                    }
                    .tint(theme.accent)
                }
            }
        }
        .themedRows()
    }

    private func routineRow(_ routine: Routine, isNext: Bool = false) -> some View {
        HStack(spacing: 12) {
            NavigationLink(value: routine) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(routine.name)
                            .font(.headline)
                        if isNext {
                            Text("Up next")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(theme.accent.opacity(0.18)))
                                .foregroundStyle(theme.accent)
                        }
                    }
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

    private func newRoutine() {
        let routine = Routine(name: "New Routine")
        context.insert(routine)
        path.append(routine)
    }
}

// MARK: - Main program card

/// The main program at the top of the Workout tab: what's up next, a start button and
/// this week's progress.
private struct MainProgramCard: View {
    let program: TrainingProgram
    @Binding var showingRoutines: Bool
    let onDelete: () -> Void
    let onStart: (Routine) -> Void
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .system

    var body: some View {
        let routines = program.sortedRoutines
        let next = program.nextRoutine
        let done = program.workoutsThisWeek

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Main program")
                        .font(.caption.bold())
                        .textCase(.uppercase)
                        .foregroundStyle(theme.accent)
                    Text(program.name)
                        .font(.title2.bold())
                }
                Spacer()
                Menu {
                    Button(showingRoutines ? "Hide Routines" : "Show All Routines",
                           systemImage: "list.bullet") {
                        withAnimation { showingRoutines.toggle() }
                    }
                    Button("Delete Program", systemImage: "trash", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
                .accessibilityLabel("Program options")
            }

            if let next, let position = routines.firstIndex(of: next) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Up next · routine \(position + 1) of \(routines.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(next.name)
                        .font(.title3.bold())
                    Text(next.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Button {
                    onStart(next)
                } label: {
                    Label("Start \(next.name)", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
                .disabled(next.sortedExercises.isEmpty)
            }

            // One bar per planned workout this week.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    ForEach(0..<max(program.daysPerWeek, 1), id: \.self) { index in
                        Capsule()
                            .fill(index < done ? AnyShapeStyle(theme.accent) : AnyShapeStyle(.quaternary))
                            .frame(height: 6)
                    }
                }
                Text("\(min(done, program.daysPerWeek)) of \(program.daysPerWeek) workouts this week")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(.vertical, 8)
    }
}
