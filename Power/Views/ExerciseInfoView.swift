import SwiftUI
import SwiftData
import Charts

/// Pop-up shown when an exercise is held down: About, Trend, Charts and Records tabs.
struct ExerciseInfoView: View {
    let exercise: Exercise

    @Environment(\.dismiss) private var dismiss
    @AppStorage(WeightUnit.storageKey) private var appUnit: WeightUnit = .kg
    @State private var tab: Tab = .about

    private var unit: WeightUnit { exercise.unit(default: appUnit) }

    enum Tab: String, CaseIterable, Identifiable {
        case about = "About", trend = "Trend", charts = "Charts", records = "Records"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch tab {
                case .about: ExerciseAboutTab(exercise: exercise)
                case .trend: ExerciseTrendTab(exercise: exercise)
                case .charts: ExerciseChartsTab(exercise: exercise, unit: unit)
                case .records: ExerciseRecordsTab(exercise: exercise, unit: unit)
                }
            }
            .safeAreaInset(edge: .top) {
                Picker("Section", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
                .background(.bar)
            }
            .navigationTitle(exercise.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - About

private struct ExerciseAboutTab: View {
    let exercise: Exercise

    var body: some View {
        let guide = ExerciseGuide.guide(for: exercise)

        List {
            Section {
                ExerciseGraphicView(exercise: exercise)
                LabeledContent("Body part", value: exercise.muscleGroup.title)
                LabeledContent("Equipment", value: exercise.equipment.title)
            }

            if let guide {
                Section("Muscles worked") {
                    MuscleRow(title: "Primary", muscles: guide.primary, highlighted: true)
                    if !guide.secondary.isEmpty {
                        MuscleRow(title: "Secondary", muscles: guide.secondary, highlighted: false)
                    }
                }

                Section("How to perform") {
                    ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("\(index + 1)")
                                .font(.subheadline.bold())
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(.tint))
                            Text(step)
                        }
                    }
                }
            } else {
                Section("How to perform") {
                    Text("No instructions for this exercise yet.")
                        .foregroundStyle(.secondary)
                }
            }

            if !exercise.notes.isEmpty {
                Section("Notes") {
                    Text(exercise.notes)
                }
            }
        }
    }
}

private struct MuscleRow: View {
    let title: String
    let muscles: [String]
    let highlighted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(muscles, id: \.self) { muscle in
                        Text(muscle)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .foregroundStyle(highlighted ? Color.white : Color.primary)
                            .background(Capsule().fill(highlighted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary)))
                    }
                }
            }
        }
    }
}

// MARK: - Trend

private struct ExerciseTrendTab: View {
    let exercise: Exercise

    var body: some View {
        let entries = exercise.completedEntries
        let routineItems = (exercise.routineEntries ?? [])
            .filter { $0.routine != nil }
            .sorted { ($0.routine?.name ?? "") < ($1.routine?.name ?? "") }

        List {
            Section {
                LabeledContent("Workouts", value: "\(entries.count)")
                LabeledContent("Last performed") {
                    if let date = entries.first?.workout?.startDate {
                        Text(date, format: .relative(presentation: .named))
                    } else {
                        Text("Never")
                    }
                }
                LabeledContent("In routines", value: "\(routineItems.count)")
            }

            Section("Routines with this exercise") {
                if routineItems.isEmpty {
                    Text("This exercise isn't in any routine yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(routineItems) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.routine?.name ?? "Routine")
                            Text(item.routine?.summary ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text("\(item.targetSets) × \(item.targetReps)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Charts

private struct ExerciseChartsTab: View {
    let exercise: Exercise
    let unit: WeightUnit
    @State private var metric: Metric = .oneRepMax

    enum Metric: String, CaseIterable, Identifiable {
        case oneRepMax = "Est. 1RM", heaviest = "Heaviest", volume = "Volume"
        var id: String { rawValue }
    }

    private struct Point: Identifiable {
        let id: PersistentIdentifier
        let date: Date
        let value: Double
    }

    private var points: [Point] {
        exercise.completedEntries.reversed().compactMap { entry -> Point? in
            guard let date = entry.workout?.startDate else { return nil }
            let working = entry.completedSets.filter { $0.setType != .warmup }
            let kilograms: Double
            switch metric {
            case .oneRepMax: kilograms = entry.bestEstimatedOneRepMaxKg
            case .heaviest: kilograms = working.map(\.weightKg).max() ?? 0
            case .volume: kilograms = entry.volumeKg
            }
            guard kilograms > 0 else { return nil }
            return Point(id: entry.persistentModelID, date: date, value: unit.fromKg(kilograms))
        }
    }

    var body: some View {
        let sets = exercise.completedWorkingSets
        let data = points

        List {
            Section {
                Picker("Metric", selection: $metric) {
                    ForEach(Metric.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if data.count < 2 {
                    Text("Log this exercise in two workouts to see a chart here.")
                        .foregroundStyle(.secondary)
                } else {
                    Chart(data) { point in
                        LineMark(x: .value("Date", point.date), y: .value(metric.rawValue, point.value))
                        PointMark(x: .value("Date", point.date), y: .value(metric.rawValue, point.value))
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartYAxisLabel(unit.rawValue)
                    .frame(height: 220)
                    .padding(.vertical, 8)
                }
            }

            Section("Statistics") {
                LabeledContent("Sessions", value: "\(exercise.completedEntries.count)")
                LabeledContent("Working sets", value: "\(sets.count)")
                LabeledContent("Total reps", value: "\(sets.reduce(0) { $0 + $1.reps })")
                LabeledContent("Total volume",
                               value: "\(unit.format(kg: sets.reduce(0) { $0 + $1.weightKg * Double($1.reps) })) \(unit.rawValue)")
                if !sets.isEmpty {
                    LabeledContent("Average reps per set",
                                   value: (Double(sets.reduce(0) { $0 + $1.reps }) / Double(sets.count))
                                    .formatted(.number.precision(.fractionLength(0...1))))
                }
            }
        }
    }
}

// MARK: - Records

private struct ExerciseRecordsTab: View {
    let exercise: Exercise
    let unit: WeightUnit

    private struct RepRecord: Identifiable {
        let reps: Int
        let set: WorkoutSet
        var id: Int { reps }
    }

    /// Heaviest set for each rep count that has been logged.
    private func repRecords(_ sets: [WorkoutSet]) -> [RepRecord] {
        Dictionary(grouping: sets.filter { $0.reps > 0 && $0.weightKg > 0 }, by: \.reps)
            .compactMap { reps, group in
                group.max { $0.weightKg < $1.weightKg }.map { RepRecord(reps: reps, set: $0) }
            }
            .sorted { $0.reps < $1.reps }
    }

    /// The working weight used most often; ties go to the heavier weight.
    private func usualWeight(_ sets: [WorkoutSet]) -> Double? {
        let counts = Dictionary(grouping: sets.filter { $0.weightKg > 0 }) { ($0.weightKg * 100).rounded() / 100 }
            .mapValues(\.count)
        return counts.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value < rhs.value
        }?.key
    }

    var body: some View {
        let sets = exercise.completedWorkingSets
        let records = repRecords(sets)
        let bestSet = sets.max { $0.estimatedOneRepMaxKg < $1.estimatedOneRepMaxKg }

        List {
            Section {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    RecordTile(title: "Est. 1-Rep Max", value: weightText(bestSet?.estimatedOneRepMaxKg))
                    RecordTile(title: "Usual Weight", value: weightText(usualWeight(sets)))
                    RecordTile(title: "Max Volume", value: weightText(exercise.completedEntries.map(\.volumeKg).max()))
                    RecordTile(title: "Heaviest Weight", value: weightText(sets.map(\.weightKg).max()))
                }
                .padding(.vertical, 4)
                if let bestSet {
                    LabeledContent("Best set", value: "\(unit.format(kg: bestSet.weightKg)) \(unit.rawValue) × \(bestSet.reps)")
                }
                LabeledContent("Most reps in one set", value: sets.map(\.reps).max().map { "\($0)" } ?? "–")
            }

            Section("Rep records") {
                if records.isEmpty {
                    Text("Finish a workout with this exercise to set your first records.")
                        .foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            Text("Reps")
                            Text("Best weight")
                            Text("Est. 1RM")
                            Text("Date")
                        }
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        Divider()
                        ForEach(records) { record in
                            GridRow {
                                Text("\(record.reps)")
                                    .bold()
                                Text("\(unit.format(kg: record.set.weightKg)) \(unit.rawValue)")
                                Text(unit.format(kg: record.set.estimatedOneRepMaxKg))
                                    .foregroundStyle(.secondary)
                                Text(record.set.workoutExercise?.workout?.startDate
                                        .formatted(.dateTime.day().month(.abbreviated)) ?? "")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.subheadline.monospacedDigit())
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func weightText(_ kilograms: Double?) -> String {
        guard let kilograms, kilograms > 0 else { return "–" }
        return "\(unit.format(kg: kilograms)) \(unit.rawValue)"
    }
}

private struct RecordTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.bold().monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary))
    }
}
