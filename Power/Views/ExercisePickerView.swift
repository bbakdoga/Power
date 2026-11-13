import SwiftUI
import SwiftData

/// Multi-select list of exercises. Exercises are added in the order tapped.
struct ExercisePickerView: View {
    /// Tapping an exercise picks it right away (used for "Replace Exercise").
    var singleSelection = false
    let onAdd: ([Exercise]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @State private var search = ""
    @State private var selected: [Exercise] = []
    @State private var showingNew = false
    @State private var muscleFilter: MuscleGroup?
    @State private var equipmentFilter: Equipment?
    @State private var sort: ExerciseSort = .name
    @State private var sortAscending = true
    @State private var infoExercise: Exercise?

    private var filtered: [Exercise] {
        let matches = exercises.filter { exercise in
            (search.isEmpty || exercise.name.localizedCaseInsensitiveContains(search))
                && (muscleFilter == nil || exercise.muscleGroup == muscleFilter)
                && (equipmentFilter == nil || exercise.equipment == equipmentFilter)
        }

        // `matches` is already in name order, so ties fall back to A→Z.
        switch sort {
        case .name:
            return sortAscending ? matches : matches.reversed()
        case .frequency:
            return matches
                .map { ($0, $0.completedEntries.count) }
                .enumerated()
                .sorted { lhs, rhs in
                    let (a, b) = (lhs.element.1, rhs.element.1)
                    if a == b { return lhs.offset < rhs.offset }
                    return sortAscending ? a < b : a > b
                }
                .map(\.element.0)
        case .lastPerformed:
            return matches
                .map { ($0, $0.lastPerformedDate) }
                .enumerated()
                .sorted { lhs, rhs in
                    switch (lhs.element.1, rhs.element.1) {
                    case let (a?, b?) where a != b:
                        return sortAscending ? a < b : a > b
                    case (.some, nil):
                        return true  // Never-performed exercises always go last.
                    case (nil, .some):
                        return false
                    default:
                        return lhs.offset < rhs.offset
                    }
                }
                .map(\.element.0)
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { exercise in
                // Tap selects the exercise; press and hold opens its info pop-up.
                HStack(spacing: 12) {
                    ExerciseThumbnail(exercise: exercise)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(exercise.name)
                            .foregroundStyle(.primary)
                        Text(exercise.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    sortDetail(for: exercise)
                    if let index = selected.firstIndex(of: exercise) {
                        Text("\(index + 1)")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(.tint))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { toggle(exercise) }
                .onLongPressGesture { infoExercise = exercise }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: "Show details") { infoExercise = exercise }
            }
            .sensoryFeedback(.impact, trigger: infoExercise)
            .sheet(item: $infoExercise) { exercise in
                ExerciseInfoView(exercise: exercise)
            }
            .overlay {
                if filtered.isEmpty {
                    ContentUnavailableView("No matching exercises",
                                           systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text("Try a different search or filter."))
                }
            }
            .safeAreaInset(edge: .top) {
                filterBar
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle(singleSelection ? "Replace Exercise" : "Add Exercises")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if !singleSelection {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(selected.isEmpty ? "Add" : "Add (\(selected.count))") {
                            onAdd(selected)
                            dismiss()
                        }
                        .disabled(selected.isEmpty)
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        showingNew = true
                    } label: {
                        Label("New exercise", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingNew) {
                ExerciseEditorView(exercise: nil)
            }
        }
    }

    private var sortArrow: String { sortAscending ? "arrow.up" : "arrow.down" }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Body Part", selection: $muscleFilter) {
                        Text("All Body Parts").tag(MuscleGroup?.none)
                        ForEach(MuscleGroup.allCases) { group in
                            Text(group.title).tag(Optional(group))
                        }
                    }
                } label: {
                    FilterChip(title: muscleFilter?.title ?? "Body Part", isActive: muscleFilter != nil)
                }

                Menu {
                    Picker("Equipment", selection: $equipmentFilter) {
                        Text("All Equipment").tag(Equipment?.none)
                        ForEach(Equipment.allCases) { equipment in
                            Text(equipment.title).tag(Optional(equipment))
                        }
                    }
                } label: {
                    FilterChip(title: equipmentFilter?.title ?? "Equipment", isActive: equipmentFilter != nil)
                }

                Menu {
                    ForEach(ExerciseSort.allCases) { option in
                        Button {
                            selectSort(option)
                        } label: {
                            if option == sort {
                                Label(option.title, systemImage: sortArrow)
                            } else {
                                Text(option.title)
                            }
                        }
                    }
                } label: {
                    FilterChip(title: sort.title, systemImage: sortArrow, isActive: false)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    /// Picking the current sort again flips its direction; a new sort starts in its natural direction.
    private func selectSort(_ option: ExerciseSort) {
        if option == sort {
            sortAscending.toggle()
        } else {
            sort = option
            sortAscending = option.defaultAscending
        }
    }

    @ViewBuilder
    private func sortDetail(for exercise: Exercise) -> some View {
        switch sort {
        case .name:
            EmptyView()
        case .frequency:
            Text("\(exercise.completedEntries.count)×")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .lastPerformed:
            Group {
                if let date = exercise.lastPerformedDate {
                    Text(date, format: .relative(presentation: .named))
                } else {
                    Text("Never")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func toggle(_ exercise: Exercise) {
        if singleSelection {
            onAdd([exercise])
            dismiss()
            return
        }
        if let index = selected.firstIndex(of: exercise) {
            selected.remove(at: index)
        } else {
            selected.append(exercise)
        }
    }
}

enum ExerciseSort: String, CaseIterable, Identifiable {
    case name, frequency, lastPerformed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "Name"
        case .frequency: return "Frequency"
        case .lastPerformed: return "Last Performed"
        }
    }

    /// Names start A→Z; frequency and recency start with the highest first.
    var defaultAscending: Bool { self == .name }
}

private struct FilterChip: View {
    let title: String
    var systemImage: String = "chevron.down"
    let isActive: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            Image(systemName: systemImage)
                .imageScale(.small)
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .foregroundStyle(isActive ? Color.white : Color.primary)
        .background(Capsule().fill(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary)))
    }
}

private extension Exercise {
    var lastPerformedDate: Date? {
        completedEntries.first?.workout?.startDate
    }
}
