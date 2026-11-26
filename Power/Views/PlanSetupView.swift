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
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .system
    @State private var profile = TrainingProfile.load() ?? TrainingProfile()
    @State private var step = Step.goal
    @State private var plan: TrainingPlan?
    @FocusState private var notesFocused: Bool
    @State private var choosingProProgram = false
    @State private var makeMain = true
    @Query(filter: #Predicate<TrainingProgram> { $0.isMain }) private var mainPrograms: [TrainingProgram]

    private enum Step: Int, CaseIterable {
        case goal, schedule, gym, notes, building, preview
    }

    var body: some View {
        VStack(spacing: 0) {
            if step.rawValue < Step.building.rawValue {
                ProgressView(value: Double(step.rawValue + 1), total: Double(Step.notes.rawValue + 1))
                    .tint(theme.accent)
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
            Button {
                choosingProProgram = true
            } label: {
                Label("Train like a pro instead", systemImage: "trophy.fill")
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            if let alternative {
                Button(alternative.title, action: alternative.action)
                    .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $choosingProProgram) {
            // Adding a pro program finishes the setup too.
            ProProgramsView(onFinish: {
                choosingProProgram = false
                onFinish()
            })
            .presentationDragIndicator(.visible)
        }
    }

    private var scheduleStep: some View {
        page(title: "How often can you train?", primary: "Continue", back: .goal, next: .gym) {
            sectionTitle("Days per week")
            Picker("Days per week", selection: $profile.daysPerWeek) {
                ForEach(2...6, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.segmented)

            sectionTitle("How do you like to train?")
            SplitCarousel(profile: $profile, autoDescription: splitDescription)

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
                    mainProgramToggle
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
                HStack(spacing: 10) {
                    if let exercise = exercises.first(where: { $0.name == item.exerciseName }) {
                        ExerciseThumbnail(exercise: exercise)
                            .frame(width: 42, height: 42)
                            .accessibilityHidden(true)
                    }
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
        // A main program also sets the weekly goal.
        plan.add(to: context, daysPerWeek: profile.daysPerWeek, makeMain: makeMain || mainPrograms.isEmpty)
        onFinish()
    }

    /// Only asked when there's already a main program; the first one always becomes main.
    private var mainProgramToggle: some View {
        Group {
            if mainPrograms.isEmpty == false {
                Toggle("Make this my main program", isOn: $makeMain)
                    .font(.subheadline)
                    .tint(theme.accent)
            }
        }
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
                        .foregroundStyle(theme.accent)
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
                    .foregroundStyle(isOn ? theme.accent : Color.secondary)
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
                        .background(Capsule().fill(isOn ? AnyShapeStyle(theme.accent) : AnyShapeStyle(.quaternary)))
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
        .tint(theme.accent)
    }
}

// MARK: - Split carousel

/// Swipeable cards for the weekly split. The centered card is the choice, and each card
/// previews the routines that split would create for the chosen number of days.
private struct SplitCarousel: View {
    @Binding var profile: TrainingProfile
    /// What "Let Power choose" would pick, e.g. "Push, pull and legs."
    let autoDescription: String
    @State private var centered: TrainingProfile.SplitStyle?
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .system

    init(profile: Binding<TrainingProfile>, autoDescription: String) {
        _profile = profile
        self.autoDescription = autoDescription
        _centered = State(initialValue: profile.wrappedValue.splitStyle)
    }

    var body: some View {
        VStack(spacing: 14) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(TrainingProfile.SplitStyle.allCases) { style in
                        card(style)
                            .containerRelativeFrame(.horizontal)
                            // Cards beside the center shrink, fade and turn away.
                            .scrollTransition(axis: .horizontal) { content, phase in
                                content
                                    .scaleEffect(phase.isIdentity ? 1 : 0.92)
                                    .opacity(phase.isIdentity ? 1 : 0.5)
                                    .rotation3DEffect(.degrees(phase.value * -14), axis: (x: 0, y: 1, z: 0))
                            }
                            .id(style)
                            .onTapGesture { withAnimation(.snappy) { centered = style } }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $centered)
            // Wide side margins so the neighboring cards peek in and invite a swipe.
            .safeAreaPadding(.horizontal, 56)
            .scrollClipDisabled()
            .frame(height: 250)

            pageDots
        }
        // Run edge to edge, past the page's side padding, so neighbors peek in.
        .padding(.horizontal, -24)
        .onChange(of: centered) { _, style in
            if let style { profile.splitStyle = style }
        }
        .sensoryFeedback(.selection, trigger: profile.splitStyle)
    }

    private func card(_ style: TrainingProfile.SplitStyle) -> some View {
        var preview = profile
        preview.splitStyle = style
        let routines = PlanBuilder.split(preview).map(\.name)
        let isOn = profile.splitStyle == style

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(style.title)
                    .font(.title2.bold())
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .opacity(isOn ? 1 : 0.6)
            }
            Text(style == .auto ? autoDescription : style.detail)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2, reservesSpace: true)
            Spacer(minLength: 12)
            // The routines this split would create, in training order.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6, alignment: .leading)],
                      alignment: .leading, spacing: 6) {
                ForEach(Array(routines.enumerated()), id: \.offset) { index, name in
                    routinePill(number: index + 1, name: name)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(height: 250)
        .background { cardBackground(style) }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: (style.colors.first ?? .orange).opacity(isOn ? 0.45 : 0), radius: 18, y: 10)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    private func routinePill(number: Int, name: String) -> some View {
        HStack(spacing: 5) {
            Text(verbatim: "\(number)")
                .font(.caption2.bold())
                .frame(width: 16, height: 16)
                .background(Circle().fill(.white.opacity(0.3)))
            Text(name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.vertical, 5)
        .padding(.leading, 5)
        .padding(.trailing, 9)
        .background(Capsule().fill(.white.opacity(0.18)))
    }

    /// The style's gradient with its symbol large and faded in the corner.
    private func cardBackground(_ style: TrainingProfile.SplitStyle) -> some View {
        ZStack(alignment: .bottomTrailing) {
            LinearGradient(colors: style.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: style.symbol)
                .font(.system(size: 130, weight: .bold))
                .foregroundStyle(.white.opacity(0.13))
                .offset(x: 24, y: 20)
        }
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(TrainingProfile.SplitStyle.allCases) { style in
                Capsule()
                    .fill(profile.splitStyle == style ? AnyShapeStyle(theme.accent) : AnyShapeStyle(.quaternary))
                    .frame(width: profile.splitStyle == style ? 20 : 7, height: 7)
            }
        }
        .animation(.snappy, value: profile.splitStyle)
        .accessibilityHidden(true)
    }
}

private extension TrainingProfile.SplitStyle {
    var symbol: String {
        switch self {
        case .auto: return "sparkles"
        case .fullBody: return "figure.strengthtraining.functional"
        case .upperLower: return "arrow.up.arrow.down"
        case .pushPullLegs: return "arrow.left.arrow.right"
        case .bodyPart: return "scope"
        }
    }

    var colors: [Color] {
        switch self {
        case .auto: return [.orange, .pink]
        case .fullBody: return [Color(red: 1, green: 0.5, blue: 0.1), .red]
        case .upperLower: return [.teal, .blue]
        case .pushPullLegs: return [.purple, .indigo]
        case .bodyPart: return [.pink, .purple]
        }
    }
}

#Preview {
    PlanSetupView(onFinish: {})
        .modelContainer(for: [Exercise.self, Routine.self, RoutineExercise.self], inMemory: true)
}

#Preview("Split carousel") {
    @Previewable @State var profile = TrainingProfile()
    VStack(alignment: .leading) {
        Text("How do you like to train?").font(.headline)
        SplitCarousel(profile: $profile, autoDescription: "Three full-body workouts.")
        Spacer()
    }
    .padding(24)
}
