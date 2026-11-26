import SwiftUI
import SwiftData

/// Asks about goals, schedule and gym, then builds a weekly plan: with Apple
/// Intelligence on supported iPhones, with Power's training rules everywhere else.
/// Used on first launch and from the Workout tab.
struct PlanSetupView: View {
    /// Called after the routines were added (or the person skipped).
    let onFinish: () -> Void
    /// Shown as a secondary choice on the first screen, e.g. "Pick a ready-made program".
    var alternative: (title: String, action: () -> Void)?

    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Exercise> { !$0.isCustom }) private var exercises: [Exercise]
    @AppStorage(Profile.weeklyGoalKey) private var weeklyGoal = 3
    @State private var profile = TrainingProfile.load() ?? TrainingProfile()
    @State private var step = Step.goal
    @State private var plan: TrainingPlan?
    @FocusState private var notesFocused: Bool

    private enum Step: Int, CaseIterable {
        case goal, schedule, gym, notes, building, preview
    }

    var body: some View {
        VStack(spacing: 0) {
            if step.rawValue < Step.building.rawValue {
                ProgressView(value: Double(step.rawValue + 1), total: Double(Step.notes.rawValue + 1))
                    .tint(.orange)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .accessibilityLabel(String(localized: "Step \(step.rawValue + 1) of \(Step.notes.rawValue + 1)"))
            }
            Group {
                switch step {
                case .goal: goalStep
                case .schedule: scheduleStep
                case .gym: gymStep
                case .notes: notesStep
                case .building: buildingStep
                case .preview: previewStep
                }
            }
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .opacity))
        }
        .animation(.easeInOut(duration: 0.25), value: step)
    }

    // MARK: - Questions

    private var goalStep: some View {
        page(title: "What's your goal?", primary: "Continue", next: .schedule) {
            ForEach(TrainingProfile.Goal.allCases) { goal in
                choiceCard(goal.title, systemImage: goal.systemImage, isOn: profile.goal == goal) {
                    profile.goal = goal
                }
            }
            sectionTitle("Experience")
            ForEach(TrainingProfile.Experience.allCases) { level in
                choiceCard(level.title, detail: level.detail, isOn: profile.experience == level) {
                    profile.experience = level
                }
            }
            if let alternative {
                Button(alternative.title, action: alternative.action)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
        }
    }

    private var scheduleStep: some View {
        page(title: "How often can you train?", primary: "Continue", back: .goal, next: .gym) {
            sectionTitle("Days per week")
            Picker("Days per week", selection: $profile.daysPerWeek) {
                ForEach(2...6, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            Text(splitDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)

            sectionTitle("Time per workout")
            Picker("Time per workout", selection: $profile.minutesPerWorkout) {
                ForEach([30, 45, 60, 75], id: \.self) { minutes in
                    Text(minutes == 75 ? "75+ min" : "\(minutes) min").tag(minutes)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var gymStep: some View {
        page(title: "Where do you train?", primary: "Continue", back: .schedule, next: .notes) {
            ForEach(TrainingProfile.Gym.allCases) { gym in
                choiceCard(gym.title, detail: gym.detail, systemImage: gym.systemImage, isOn: profile.gym == gym) {
                    profile.gym = gym
                }
            }
            sectionTitle("Focus on (optional)")
            chips(TrainingProfile.focusOptions, title: \.title, selection: $profile.focus)
            sectionTitle("Go easy on (optional)")
            chips(TrainingProfile.Limitation.allCases, title: \.title, selection: $profile.limitations)
        }
    }

    private var notesStep: some View {
        page(title: "Anything else?", primary: "Build My Plan", back: .gym, next: .building) {
            Text(PlanCoach.isAvailable
                 ? "Apple Intelligence reads this to personalize your plan, e.g. \"I love deadlifts\" or \"no lunges\". It stays on your iPhone."
                 : "Optional notes for your plan, e.g. \"I love deadlifts\". You can edit every exercise later.")
                .foregroundStyle(.secondary)
            TextField("Notes (optional)", text: $profile.notes, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .focused($notesFocused)
            Label(PlanCoach.isAvailable
                  ? String(localized: "Your plan is made with Apple Intelligence, on your iPhone and free.")
                  : String(localized: "Your plan is made with Power's training rules."),
                  systemImage: PlanCoach.isAvailable ? "sparkles" : "checklist")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    // MARK: - Building and preview

    private var buildingStep: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Building your plan…")
                .font(.title3.bold())
            Text(PlanCoach.isAvailable
                 ? "Apple Intelligence is choosing exercises for you. This happens on your iPhone."
                 : "Choosing exercises for your goal, schedule and gym.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await build() }
    }

    @ViewBuilder
    private var previewStep: some View {
        if let plan {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(plan.name)
                                .font(.largeTitle.bold())
                            Text(plan.summary)
                                .foregroundStyle(.secondary)
                            Label(plan.personalizedWithAI
                                  ? String(localized: "Personalized with Apple Intelligence")
                                  : String(localized: "Made with Power's training rules"),
                                  systemImage: plan.personalizedWithAI ? "sparkles" : "checklist")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 24)

                        ForEach(plan.days, id: \.self) { day in
                            dayCard(day)
                        }
                        Text("Train the routines in order and start over when you've done them all. You can edit every routine later.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }
                VStack(spacing: 10) {
                    primaryButton(String(localized: "Add \(plan.days.count) routines")) { add(plan) }
                    HStack {
                        Button("Change answers") { step = .goal }
                        Spacer()
                        // The rules always give the same plan; only the model can vary it.
                        if plan.personalizedWithAI {
                            Button("Try again") { step = .building }
                        }
                    }
                    .font(.subheadline)
                }
                .padding(24)
                .background(.bar)
            }
        }
    }

    private func dayCard(_ day: TrainingPlan.Day) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(day.name)
                .font(.headline)
            ForEach(Array(day.items.enumerated()), id: \.offset) { _, item in
                HStack {
                    Text(item.exerciseName)
                    Spacer()
                    Text(verbatim: item.exerciseName.contains("Plank") ? "\(item.sets) ×" : "\(item.sets) × \(item.reps)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
            if !day.tip.isEmpty {
                Label(day.tip, systemImage: "lightbulb")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(.quaternary.opacity(0.6)))
    }

    private func build() async {
        profile.save()
        let library = exercises.map { (name: $0.name, equipment: $0.equipment) }
        let drafts = PlanBuilder.draft(for: profile, library: library)
        var result = await PlanCoach.personalize(drafts, profile: profile)
        if result == nil {
            result = PlanBuilder.plan(for: profile, library: library)
        }
        plan = result
        step = .preview
    }

    private func add(_ plan: TrainingPlan) {
        plan.add(to: context)
        weeklyGoal = profile.daysPerWeek
        onFinish()
    }

    // MARK: - Building blocks

    private var splitDescription: String {
        switch profile.daysPerWeek {
        case ...2: return String(localized: "Two full-body workouts.")
        case 3: return profile.experience == .beginner
            ? String(localized: "Three full-body workouts.")
            : String(localized: "Push, pull and legs.")
        case 4: return String(localized: "Upper and lower body, twice each.")
        case 5: return String(localized: "Push, pull, legs, then upper and lower body.")
        default: return String(localized: "Push, pull and legs, twice each.")
        }
    }

    private func page<Content: View>(title: LocalizedStringKey, primary: LocalizedStringResource,
                                     back: Step? = nil, next: Step,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(title)
                        .font(.largeTitle.bold())
                        .padding(.top, 24)
                        .padding(.bottom, 4)
                    content()
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            VStack(spacing: 10) {
                primaryButton(String(localized: primary)) {
                    notesFocused = false
                    step = next
                }
                if let back {
                    Button("Back") { step = back }
                        .font(.subheadline)
                }
            }
            .padding(24)
        }
    }

    private func sectionTitle(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.headline)
            .padding(.top, 12)
    }

    private func choiceCard(_ title: String, detail: String? = nil, systemImage: String? = nil,
                            isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.title3)
                        .frame(width: 32)
                        .foregroundStyle(.orange)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isOn ? Color.orange : Color.secondary)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(.quaternary.opacity(isOn ? 1 : 0.5)))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// Toggle chips for a multi-choice question.
    private func chips<Item: Hashable>(_ items: [Item], title: KeyPath<Item, String>,
                                       selection: Binding<Set<Item>>) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                let isOn = selection.wrappedValue.contains(item)
                Button {
                    if isOn { selection.wrappedValue.remove(item) } else { selection.wrappedValue.insert(item) }
                } label: {
                    Text(item[keyPath: title])
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(isOn ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.quaternary)))
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
    }
}

#Preview {
    PlanSetupView(onFinish: {})
        .modelContainer(for: [Exercise.self, Routine.self, RoutineExercise.self], inMemory: true)
}
