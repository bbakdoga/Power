import SwiftUI
import SwiftData

/// "Train like a pro": swipe through programs inspired by famous bodybuilders,
/// powerlifters and fitness creators, then add one as routines.
struct ProProgramsView: View {
    /// Called after the routines were added.
    let onFinish: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Profile.weeklyGoalKey) private var weeklyGoal = 3
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .system
    @State private var category = ProProgram.Category.bodybuilders
    @State private var centeredID: String? = ProProgram.programs(in: .bodybuilders).first?.id

    private var programs: [ProProgram] { ProProgram.programs(in: category) }

    private var selected: ProProgram? {
        programs.first { $0.id == centeredID } ?? programs.first
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Train like a pro")
                            .font(.largeTitle.bold())
                        Text("Programs inspired by how famous athletes and coaches train.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 24)

                    Picker("Category", selection: $category) {
                        ForEach(ProProgram.Category.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    carousel

                    if let selected {
                        Text("\(selected.days.count) routines")
                            .font(.headline)
                            .padding(.top, 4)
                        ForEach(selected.days, id: \.self) { day in
                            ProRoutineCard(day: day)
                        }
                        Text("Inspired by publicly shared training of \(selected.person). Not an official program; \(selected.person) isn't affiliated with Power. You can edit every routine later.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
            if let selected {
                VStack(spacing: 10) {
                    Button {
                        add(selected)
                    } label: {
                        Text("Add \(selected.days.count) routines")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent)
                    Button("Cancel") { dismiss() }
                        .font(.subheadline)
                }
                .padding(24)
                .background(.bar)
            }
        }
        .onChange(of: category) { _, newCategory in
            centeredID = ProProgram.programs(in: newCategory).first?.id
        }
        .sensoryFeedback(.selection, trigger: centeredID)
    }

    private var carousel: some View {
        VStack(spacing: 14) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(programs) { program in
                        ProCard(program: program, isSelected: program.id == selected?.id)
                            .containerRelativeFrame(.horizontal)
                            // Cards beside the center shrink, fade and turn away.
                            .scrollTransition(axis: .horizontal) { content, phase in
                                content
                                    .scaleEffect(phase.isIdentity ? 1 : 0.92)
                                    .opacity(phase.isIdentity ? 1 : 0.5)
                                    .rotation3DEffect(.degrees(phase.value * -14), axis: (x: 0, y: 1, z: 0))
                            }
                            .id(program.id)
                            .onTapGesture { withAnimation(.snappy) { centeredID = program.id } }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $centeredID)
            // Wide side margins so the neighboring cards peek in and invite a swipe.
            .safeAreaPadding(.horizontal, 56)
            .scrollClipDisabled()
            // A new category starts with a fresh row of cards.
            .id(category)

            HStack(spacing: 6) {
                ForEach(programs) { program in
                    Capsule()
                        .fill(program.id == selected?.id ? AnyShapeStyle(theme.accent) : AnyShapeStyle(.quaternary))
                        .frame(width: program.id == selected?.id ? 20 : 7, height: 7)
                }
            }
            .animation(.snappy, value: centeredID)
            .accessibilityHidden(true)
        }
        // Run edge to edge, past the page's side padding, so neighbors peek in.
        .padding(.horizontal, -24)
    }

    private func add(_ program: ProProgram) {
        program.plan.add(to: context)
        weeklyGoal = program.daysPerWeek
        onFinish()
    }
}

// MARK: - Cards

/// A pro's card: their photo (or signature lift) on top, then name, credential and
/// what the program is about.
private struct ProCard: View {
    let program: ProProgram
    let isSelected: Bool
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .system

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            photo
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: program.person)
                    .font(.title3.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(program.credential)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(program.programName)
                    .font(.headline)
                    .padding(.top, 6)
                Text(program.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(4, reservesSpace: true)
                HStack(spacing: 6) {
                    tag(String(localized: "\(program.daysPerWeek) days a week"), systemImage: "calendar")
                    tag(String(localized: "\(program.exerciseCount) exercises"), systemImage: "dumbbell.fill")
                }
                .padding(.top, 6)
            }
            .padding(16)
        }
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.background.secondary))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(theme.accent.opacity(isSelected ? 0.8 : 0), lineWidth: 2)
        }
        .shadow(color: .black.opacity(isSelected ? 0.15 : 0), radius: 14, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// A licensed photo if one is in the asset catalog, otherwise the illustration of
    /// the lift the person is known for, with their initials.
    private var photo: some View {
        ZStack(alignment: .bottomLeading) {
            Color.white
            if let image = UIImage(named: program.photoName) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let image = UIImage(named: illustrationName) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
            }
            Text(verbatim: program.initials)
                .font(.headline.bold())
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(theme.accent.gradient))
                .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                .padding(12)
        }
        .frame(height: 170)
        .clipped()
        .accessibilityHidden(true)
    }

    private var illustrationName: String {
        "exercise-\(ExerciseGuide.slug(program.signatureExercise))-\(program.bodyType.rawValue)"
    }

    private func tag(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(.quaternary))
    }
}

/// One routine of the selected program with its exercises.
private struct ProRoutineCard: View {
    let day: TrainingPlan.Day

    var body: some View {
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
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(.quaternary.opacity(0.6)))
    }
}

#Preview {
    ProProgramsView(onFinish: {})
        .modelContainer(for: [Exercise.self, Routine.self, RoutineExercise.self], inMemory: true)
}
