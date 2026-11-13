import SwiftUI
import SwiftData
import Charts

/// The user's profile: lifetime training statistics, favorite exercises and body stats.
struct ProfileView: View {
    @Query(filter: #Predicate<Workout> { $0.endDate != nil }, sort: \Workout.startDate, order: .reverse)
    private var workouts: [Workout]
    @Query(sort: \BodyMeasurement.date, order: .reverse) private var measurements: [BodyMeasurement]
    @AppStorage(WeightUnit.storageKey) private var unit: WeightUnit = .kg
    @AppStorage(Profile.nameKey) private var name = ""
    @State private var editing = false

    private struct WeekCount: Identifiable {
        let week: Date
        let workouts: Int
        var id: Date { week }
    }

    private struct ExerciseCount: Identifiable {
        let name: String
        let sessions: Int
        var id: String { name }
    }

    /// Exercises done in the most workouts.
    private var topExercises: [ExerciseCount] {
        let names = workouts.flatMap { $0.sortedExercises.compactMap { $0.exercise?.name } }
        return Dictionary(grouping: names, by: { $0 })
            .map { ExerciseCount(name: $0.key, sessions: $0.value.count) }
            .sorted { $0.sessions == $1.sessions ? $0.name < $1.name : $0.sessions > $1.sessions }
            .prefix(5)
            .map { $0 }
    }

    var body: some View {
        let totalVolume = workouts.reduce(0) { $0 + $1.totalVolumeKg }
        let totalTime = workouts.reduce(0) { $0 + $1.duration }
        let totalSets = workouts.reduce(0) { $0 + $1.completedSetCount }
        let weeks = WorkoutStats.workoutsPerWeek(workouts, count: 12).map { WeekCount(week: $0.week, workouts: $0.workouts) }
        let latestWeight = measurements.first { $0.kind == .bodyweight }

        NavigationStack {
            List {
                Section {
                    header
                }

                Section("Lifetime") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        StatTile(title: "Workouts", value: "\(workouts.count)",
                                 systemImage: "figure.strengthtraining.traditional", tint: .accentColor)
                        StatTile(title: "Week streak", value: "\(WorkoutStats.weekStreak(workouts))",
                                 systemImage: "flame.fill", tint: .orange)
                        StatTile(title: "Total volume", value: compactWeight(totalVolume),
                                 systemImage: "scalemass", tint: .purple)
                        StatTile(title: "Time trained", value: hoursText(totalTime),
                                 systemImage: "clock", tint: .teal)
                        StatTile(title: "Sets", value: "\(totalSets)",
                                 systemImage: "checkmark.circle", tint: .green)
                        StatTile(title: "Best streak", value: "\(WorkoutStats.longestWeekStreak(workouts)) wk",
                                 systemImage: "trophy.fill", tint: .yellow)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                Section("Workouts per week") {
                    if workouts.isEmpty {
                        Text("Finish a workout to see your training here.")
                            .foregroundStyle(.secondary)
                    } else {
                        Chart(weeks) { item in
                            BarMark(x: .value("Week", item.week, unit: .weekOfYear),
                                    y: .value("Workouts", item.workouts))
                        }
                        .chartYAxis {
                            AxisMarks(values: .automatic(desiredCount: 3))
                        }
                        .frame(height: 160)
                        .padding(.vertical, 8)
                        .accessibilityLabel("Workouts per week for the last 12 weeks")
                    }
                    NavigationLink {
                        WeeklySummaryView()
                    } label: {
                        Label("Weekly summary", systemImage: "chart.bar.xaxis")
                    }
                }

                Section("Favorite exercises") {
                    if topExercises.isEmpty {
                        Text("Your most-done exercises will show up here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(topExercises) { item in
                        LabeledContent(item.name, value: item.sessions == 1 ? "1 workout" : "\(item.sessions) workouts")
                    }
                }

                Section("Body") {
                    NavigationLink {
                        BodyMeasurementsView()
                    } label: {
                        LabeledContent {
                            Text(latestWeight.map { BodyMeasurementKind.bodyweight.format($0.value, unit: unit) } ?? "Add")
                        } label: {
                            Label("Body measurements", systemImage: "figure")
                        }
                    }
                }
            }
            .navigationTitle("Profile")
            .toolbar {
                Button("Edit") { editing = true }
            }
            .sheet(isPresented: $editing) {
                EditProfileView()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Text(initials)
                .font(.title.bold())
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(Circle().fill(Color.accentColor.gradient))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(name.isEmpty ? "Your Profile" : name)
                    .font(.title2.bold())
                if let first = workouts.last?.startDate {
                    Text("Training since \(first.formatted(.dateTime.month(.wide).year()))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Tap Edit to add your name")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var initials: String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "💪" : String(letters).uppercased()
    }

    /// "12.4k kg" style for big lifetime totals.
    private func compactWeight(_ kilograms: Double) -> String {
        let value = unit.fromKg(kilograms)
        let text = value >= 1000
            ? "\((value / 1000).formatted(.number.precision(.fractionLength(0...1))))k"
            : value.formatted(.number.precision(.fractionLength(0)))
        return "\(text) \(unit.rawValue)"
    }

    private func hoursText(_ seconds: TimeInterval) -> String {
        let hours = seconds / 3600
        return hours < 1 ? "\(Int(seconds / 60)) min" : "\(hours.formatted(.number.precision(.fractionLength(0...1)))) h"
    }
}

enum Profile {
    static let nameKey = "profileName"
}

struct EditProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Profile.nameKey) private var name = ""
    @AppStorage(BodyType.storageKey) private var bodyType: BodyType = .man

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                    .textContentType(.name)
                Section {
                    Picker("Body type", selection: $bodyType) {
                        ForEach(BodyType.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("Used for the exercise illustrations.")
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
