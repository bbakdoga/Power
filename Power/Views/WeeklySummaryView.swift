import SwiftUI
import SwiftData
import Charts

/// Training calendar, weekly streak, and working sets per body part for a chosen week.
struct WeeklySummaryView: View {
    @Query(filter: #Predicate<Workout> { $0.endDate != nil }, sort: \Workout.startDate, order: .reverse)
    private var workouts: [Workout]
    @AppStorage(WeightUnit.storageKey) private var unit: WeightUnit = .kg
    @State private var weekOffset = 0
    @State private var month = Date.now

    private let calendar = Calendar.current

    /// Body parts worth flagging when a week has no sets for them.
    private static let trackedGroups: [MuscleGroup] = [.chest, .back, .shoulders, .biceps, .triceps, .legs, .glutes, .core]

    private var selectedWeek: DateInterval {
        let date = calendar.date(byAdding: .weekOfYear, value: weekOffset, to: .now) ?? .now
        return calendar.dateInterval(of: .weekOfYear, for: date) ?? DateInterval(start: date, duration: 7 * 86_400)
    }

    private var weekWorkouts: [Workout] {
        workouts.filter { selectedWeek.contains($0.startDate) }
    }

    private var streak: Int { WorkoutStats.weekStreak(workouts) }

    private struct GroupSets: Identifiable {
        let group: MuscleGroup
        let sets: Int
        var id: MuscleGroup { group }
    }

    private var setsPerGroup: [GroupSets] {
        var counts: [MuscleGroup: Int] = [:]
        for workout in weekWorkouts {
            for entry in workout.sortedExercises {
                guard let group = entry.exercise?.muscleGroup else { continue }
                counts[group, default: 0] += entry.completedSets.filter { $0.setType != .warmup }.count
            }
        }
        return counts.filter { $0.value > 0 }
            .map { GroupSets(group: $0.key, sets: $0.value) }
            .sorted { $0.sets > $1.sets }
    }

    var body: some View {
        let groups = setsPerGroup
        let neglected = Self.trackedGroups.filter { group in !groups.contains { $0.group == group } }

        List {
            Section {
                HStack(spacing: 12) {
                    StatTile(title: "Week streak", value: "\(streak)", systemImage: "flame.fill", tint: .orange)
                    StatTile(title: "This week", value: "\(workouts.filter { thisWeek.contains($0.startDate) }.count)",
                             systemImage: "figure.strengthtraining.traditional", tint: .accentColor)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            Section("Training days") {
                TrainingCalendar(month: $month, trainedDays: trainedDays)
            }

            Section {
                HStack {
                    Button {
                        weekOffset -= 1
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel("Previous week")
                    Spacer()
                    Text(weekTitle)
                        .font(.headline)
                    Spacer()
                    Button {
                        weekOffset += 1
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(weekOffset >= 0)
                    .accessibilityLabel("Next week")
                }
                .buttonStyle(.borderless)

                LabeledContent("Workouts", value: "\(weekWorkouts.count)")
                LabeledContent("Volume", value: "\(unit.format(kg: weekWorkouts.reduce(0) { $0 + $1.totalVolumeKg })) \(unit.rawValue)")
                LabeledContent("Time", value: weekWorkouts.reduce(0) { $0 + $1.duration }.clockString)

                if groups.isEmpty {
                    Text("No sets logged this week.")
                        .foregroundStyle(.secondary)
                } else {
                    Chart(groups) { item in
                        BarMark(x: .value("Sets", item.sets), y: .value("Body part", item.group.title))
                            .annotation(position: .trailing) {
                                Text("\(item.sets)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                    }
                    .chartXAxisLabel("Working sets")
                    .frame(height: CGFloat(groups.count) * 32 + 40)
                    .padding(.vertical, 8)
                }
            } header: {
                Text("Weekly volume")
            }

            if !neglected.isEmpty && !weekWorkouts.isEmpty {
                Section {
                    Text(neglected.map(\.title).formatted(.list(type: .and)))
                } header: {
                    Text("Not trained this week")
                } footer: {
                    Text("Body parts with no working sets in the selected week.")
                }
            }
        }
        .navigationTitle("Summary")
    }

    private var thisWeek: DateInterval {
        calendar.dateInterval(of: .weekOfYear, for: .now) ?? DateInterval(start: .now, duration: 7 * 86_400)
    }

    private var weekTitle: String {
        if weekOffset == 0 { return "This week" }
        if weekOffset == -1 { return "Last week" }
        let end = selectedWeek.end.addingTimeInterval(-1)
        return "\(selectedWeek.start.formatted(.dateTime.day().month(.abbreviated))) – \(end.formatted(.dateTime.day().month(.abbreviated)))"
    }

    private var trainedDays: Set<Date> {
        Set(workouts.map { calendar.startOfDay(for: $0.startDate) })
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(tint)
            Text(value)
                .font(.title.bold().monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary))
        .accessibilityElement(children: .combine)
    }
}

/// Month grid with training days filled in.
private struct TrainingCalendar: View {
    @Binding var month: Date
    let trainedDays: Set<Date>

    private let calendar = Calendar.current

    var body: some View {
        let days = monthDays
        VStack(spacing: 10) {
            HStack {
                Button {
                    shiftMonth(-1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("Previous month")
                Spacer()
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(.headline)
                Spacer()
                Button {
                    shiftMonth(1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(calendar.isDate(month, equalTo: .now, toGranularity: .month))
                .accessibilityLabel("Next month")
            }
            .buttonStyle(.borderless)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 6) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let day {
                        let trained = trainedDays.contains(day)
                        let isToday = calendar.isDateInToday(day)
                        Text("\(calendar.component(.day, from: day))")
                            .font(.subheadline.monospacedDigit())
                            .frame(width: 32, height: 32)
                            .foregroundStyle(trained ? Color.white : Color.primary)
                            .background(Circle().fill(trained ? Color.accentColor : Color.clear))
                            .overlay(Circle().strokeBorder(isToday ? Color.accentColor : Color.clear, lineWidth: 1.5))
                            .accessibilityLabel(day.formatted(date: .complete, time: .omitted) + (trained ? ", trained" : ""))
                    } else {
                        Color.clear.frame(height: 32)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Weekday initials starting from the user's first weekday.
    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// The month's days, padded with nils so day 1 lands on the right weekday.
    private var monthDays: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let count = calendar.range(of: .day, in: .month, for: month)?.count else { return [] }
        let leading = (calendar.component(.weekday, from: interval.start) - calendar.firstWeekday + 7) % 7
        let days = (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: interval.start) }
        return Array(repeating: nil, count: leading) + days
    }

    private func shiftMonth(_ value: Int) {
        month = calendar.date(byAdding: .month, value: value, to: month) ?? month
    }
}
