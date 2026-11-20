import SwiftUI
import SwiftData
import Charts
import PhotosUI

/// The user's profile: weekly goal, stats, big lifts, muscle balance and training year.
struct ProfileView: View {
    @Query(filter: #Predicate<Workout> { $0.endDate != nil }, sort: \Workout.startDate, order: .reverse)
    private var workouts: [Workout]
    @Query(sort: \BodyMeasurement.date, order: .reverse) private var measurements: [BodyMeasurement]
    @Query private var exercises: [Exercise]
    @AppStorage(WeightUnit.storageKey) private var unit: WeightUnit = .kg
    @AppStorage(Profile.nameKey) private var name = ""
    @AppStorage(Profile.goalTextKey) private var goalText = ""
    @AppStorage(Profile.weeklyGoalKey) private var weeklyGoal = 3
    @AppStorage(Profile.bigLiftsKey) private var bigLiftNames = Profile.defaultBigLifts.joined(separator: "|")
    @AppStorage(Profile.photoVersionKey) private var photoVersion = 0
    @State private var photo: UIImage?
    @State private var range: StatsRange = .month
    @State private var editing = false
    @State private var openedLift: Exercise?

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
        let latestWeight = measurements.first { $0.kind == .bodyweight }

        NavigationStack {
            List {
                Section {
                    header
                }
                .themedRows()

                Section {
                    WeeklyGoalCard(workouts: workouts, goal: weeklyGoal)
                    NavigationLink {
                        WeeklySummaryView()
                    } label: {
                        Label("Weekly summary", systemImage: "chart.bar.xaxis")
                    }
                } header: {
                    Text("Weekly goal")
                }
                .themedRows()

                statsSection

                Section("Big lifts") {
                    BigLiftsGrid(names: bigLiftNames.split(separator: "|").map(String.init),
                                 exercises: exercises, appUnit: unit, opened: $openedLift)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
                .themedRows()

                Section {
                    MuscleBalanceView(workouts: workouts)
                } header: {
                    Text("Muscle balance")
                } footer: {
                    Text("Working sets in the last 30 days.")
                }
                .themedRows()

                Section("Training year") {
                    YearHeatmap(workouts: workouts)
                        .padding(.vertical, 6)
                }
                .themedRows()

                Section("Favorite exercises") {
                    if topExercises.isEmpty {
                        Text("Your most-done exercises will show up here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(topExercises) { item in
                        LabeledContent(item.name, value: String(localized: "\(item.sessions) workouts"))
                    }
                }
                .themedRows()

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
                .themedRows()
            }
            .navigationTitle("Profile")
            .themedScreen()
            .navigationDestination(item: $openedLift) { exercise in
                ExerciseDetailView(exercise: exercise)
            }
            .toolbar {
                Button("Edit") { editing = true }
            }
            .sheet(isPresented: $editing) {
                EditProfileView()
            }
            .task(id: photoVersion) {
                photo = Profile.loadPhoto()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            avatar
            VStack(alignment: .leading, spacing: 4) {
                Text(name.isEmpty ? String(localized: "Your Profile") : name)
                    .font(.title2.bold())
                if !goalText.isEmpty {
                    Text(goalText)
                        .font(.subheadline)
                }
                Group {
                    if let first = workouts.last?.startDate {
                        Text("Training since \(first.formatted(.dateTime.month(.wide).year())) · \(String(localized: "\(workouts.count) workouts"))")
                    } else {
                        Text("Tap Edit to add your name")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var avatar: some View {
        if let photo {
            Image(uiImage: photo)
                .resizable()
                .scaledToFill()
                .frame(width: 72, height: 72)
                .clipShape(Circle())
                .accessibilityHidden(true)
        } else {
            Text(initials)
                .font(.title.bold())
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(Circle().fill(.tint))
                .accessibilityHidden(true)
        }
    }

    private var initials: String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "💪" : String(letters).uppercased()
    }

    // MARK: - Stats

    private var statsSection: some View {
        let filtered = workouts.filter { $0.startDate >= range.start(firstWorkout: workouts.last?.startDate) }
        let volume = filtered.reduce(0) { $0 + $1.totalVolumeKg }
        let time = filtered.reduce(0) { $0 + $1.duration }
        let sets = filtered.reduce(0) { $0 + $1.completedSetCount }
        let averageDuration = filtered.isEmpty ? 0 : time / Double(filtered.count)
        let weeks = range.weeks(firstWorkout: workouts.last?.startDate)
        let perWeek = weeks > 0 ? Double(filtered.count) / weeks : 0

        return Section {
            Picker("Period", selection: $range) {
                ForEach(StatsRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                StatTile(title: "Workouts", value: "\(filtered.count)",
                         systemImage: "figure.strengthtraining.traditional", tint: nil)
                StatTile(title: "Per week", value: perWeek.formatted(.number.precision(.fractionLength(0...1))),
                         systemImage: "calendar", tint: .orange)
                StatTile(title: "Total volume", value: compactWeight(volume),
                         systemImage: "scalemass", tint: .purple)
                StatTile(title: "Time trained", value: hoursText(time),
                         systemImage: "clock", tint: .teal)
                StatTile(title: "Sets", value: "\(sets)",
                         systemImage: "checkmark.circle", tint: .green)
                StatTile(title: "Avg. workout", value: averageDuration > 0 ? hoursText(averageDuration) : "–",
                         systemImage: "stopwatch", tint: .pink)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        } header: {
            Text("Stats")
        }
        .themedRows()
    }

    /// "12.4K kg" style for big totals ("12,4 Tsd. kg" in German).
    private func compactWeight(_ kilograms: Double) -> String {
        let value = unit.fromKg(kilograms)
        let text = value >= 1000
            ? value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
            : value.formatted(.number.precision(.fractionLength(0)))
        return "\(text) \(unit.rawValue)"
    }

    /// "45 min" or "12.5 hr", in the app's language.
    private func hoursText(_ seconds: TimeInterval) -> String {
        let measurement = seconds < 3600
            ? Measurement(value: (seconds / 60).rounded(.down), unit: UnitDuration.minutes)
            : Measurement(value: seconds / 3600, unit: UnitDuration.hours)
        return measurement.formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                                  numberFormatStyle: .number.precision(.fractionLength(0...1))))
    }
}

// MARK: - Stats period

enum StatsRange: String, CaseIterable, Identifiable {
    case week, month, year, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: return String(localized: "Week")
        case .month: return String(localized: "Month")
        case .year: return String(localized: "Year")
        case .all: return String(localized: "All")
        }
    }

    /// First day included. "All" starts at the first workout.
    func start(firstWorkout: Date?, calendar: Calendar = .current) -> Date {
        let now = Date.now
        switch self {
        case .week: return calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        case .month: return calendar.date(byAdding: .day, value: -30, to: now) ?? now
        case .year: return calendar.date(byAdding: .year, value: -1, to: now) ?? now
        case .all: return firstWorkout ?? .distantPast
        }
    }

    /// Length of the period in weeks, for the "per week" average.
    func weeks(firstWorkout: Date?) -> Double {
        switch self {
        case .week: return 1
        case .month: return 30 / 7
        case .year: return 52
        case .all:
            guard let firstWorkout else { return 0 }
            return max(1, Date.now.timeIntervalSince(firstWorkout) / (7 * 86_400))
        }
    }
}

// MARK: - Weekly goal

/// Ring showing this week's workouts against the goal, plus the goal streak.
private struct WeeklyGoalCard: View {
    let workouts: [Workout]
    let goal: Int

    var body: some View {
        let thisWeek = Calendar.current.dateInterval(of: .weekOfYear, for: .now)
        let done = workouts.filter { thisWeek?.contains($0.startDate) ?? false }.count
        let progress = min(Double(done) / Double(max(goal, 1)), 1)
        let streak = WorkoutStats.goalStreak(workouts, goal: goal)
        let remaining = max(goal - done, 0)

        HStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(.tint.opacity(0.18), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.6), value: progress)
                VStack(spacing: 0) {
                    Text("\(done)/\(goal)")
                        .font(.title2.bold().monospacedDigit())
                    Text("this week")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 96, height: 96)

            VStack(alignment: .leading, spacing: 8) {
                Text(remaining == 0
                     ? String(localized: "Goal reached! 🎉")
                     : String(localized: "\(remaining) more to reach your goal"))
                    .font(.headline)
                Label(String(localized: "\(streak) week streak"), systemImage: "flame.fill")
                    .font(.subheadline)
                    .foregroundStyle(streak > 0 ? Color.orange : Color.secondary)
                Text("Goal: \(goal) workouts a week")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Big lifts

/// Best estimated 1RM for the chosen lifts, with the change since the first session.
private struct BigLiftsGrid: View {
    let names: [String]
    let exercises: [Exercise]
    let appUnit: WeightUnit
    /// Set to open a lift's page; the destination lives on ProfileView, outside the List.
    @Binding var opened: Exercise?

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(names, id: \.self) { name in
                if let exercise = exercises.first(where: { $0.name == name && !$0.isCustom })
                    ?? exercises.first(where: { $0.name == name }) {
                    // A button + navigationDestination avoids the list's disclosure arrows.
                    Button {
                        opened = exercise
                    } label: {
                        tile(for: exercise)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func tile(for exercise: Exercise) -> some View {
        let unit = exercise.unit(default: appUnit)
        let best = exercise.completedWorkingSets.map(\.estimatedOneRepMaxKg).max() ?? 0
        let first = exercise.completedEntries.last?.bestEstimatedOneRepMaxKg ?? 0
        let change = best - first

        return VStack(alignment: .leading, spacing: 4) {
            Text(exercise.name)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(best > 0 ? "\(unit.format(kg: best)) \(unit.rawValue)" : "–")
                .font(.title3.bold().monospacedDigit())
            Group {
                if best == 0 {
                    Text("Not done yet")
                        .foregroundStyle(.secondary)
                } else if change > 0.05 {
                    Text("+\(unit.format(kg: change)) \(unit.rawValue) since start")
                        .foregroundStyle(.green)
                } else {
                    Text("Est. 1RM")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption2)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.6)))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Muscle balance

/// Working sets per body part over the last 30 days, with a hint about neglected ones.
private struct MuscleBalanceView: View {
    let workouts: [Workout]

    private static let groups: [MuscleGroup] = [.chest, .back, .shoulders, .biceps, .triceps, .legs, .glutes, .core]

    private struct Item: Identifiable {
        let group: MuscleGroup
        let sets: Int
        var id: MuscleGroup { group }
    }

    var body: some View {
        let start = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
        let counts = WorkoutStats.setsPerGroup(workouts, since: start)
        let items = Self.groups.map { Item(group: $0, sets: counts[$0] ?? 0) }.sorted { $0.sets > $1.sets }
        let top = items.first?.sets ?? 0
        let behind = items.filter { top > 0 && Double($0.sets) < Double(top) * 0.25 }

        VStack(alignment: .leading, spacing: 10) {
            if top == 0 {
                Text("Log some workouts to see which muscles you train most.")
                    .foregroundStyle(.secondary)
            } else {
                MuscleSetBars(items: items.map { ($0.group, $0.sets) },
                              highlighted: Set(behind.map(\.group)))

                Label {
                    Text(behind.isEmpty
                         ? String(localized: "Nicely balanced 👍")
                         : String(localized: "Behind: \(behind.map(\.group.title).formatted(.list(type: .and)))"))
                } icon: {
                    Image(systemName: behind.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(behind.isEmpty ? Color.green : Color.orange)
                }
                .font(.subheadline)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Training year

/// GitHub-style grid of the last 12 months: one square per day, darker for more volume.
private struct YearHeatmap: View {
    let workouts: [Workout]
    private let calendar = Calendar.current

    var body: some View {
        let load = WorkoutStats.dailyLoad(workouts)
        let columns = weekColumns
        let maxLoad = max(load.values.max() ?? 1, 1)
        let yearStart = columns.first?.compactMap { $0 }.first ?? .now
        let count = workouts.filter { $0.startDate >= yearStart }.count

        VStack(alignment: .leading, spacing: 8) {
            Canvas { context, size in
                let gap: CGFloat = 2
                let cols = CGFloat(columns.count)
                let cell = min((size.width - gap * (cols - 1)) / cols, (size.height - gap * 6) / 7)
                for (x, week) in columns.enumerated() {
                    for (y, day) in week.enumerated() {
                        guard let day else { continue }
                        let rect = CGRect(x: CGFloat(x) * (cell + gap), y: CGFloat(y) * (cell + gap),
                                          width: cell, height: cell)
                        let path = Path(roundedRect: rect, cornerRadius: cell * 0.25)
                        let value = load[day] ?? 0
                        if value == 0 {
                            context.fill(path, with: .color(.gray.opacity(0.18)))
                        } else {
                            context.fill(path, with: .style(.tint.opacity(Self.intensity(value / maxLoad))))
                        }
                    }
                }
            }
            .frame(height: 64)
            .accessibilityLabel(String(localized: "\(count) workouts in the last 12 months"))

            HStack(spacing: 4) {
                Text(String(localized: "\(count) workouts in the last 12 months"))
                Spacer()
                Text("Less")
                ForEach([0.0, 0.35, 0.6, 0.8, 1.0], id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(level == 0 ? AnyShapeStyle(Color.gray.opacity(0.18)) : AnyShapeStyle(.tint.opacity(level)))
                        .frame(width: 9, height: 9)
                }
                Text("More")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
    }

    /// Four shades by share of the busiest day.
    private static func intensity(_ ratio: Double) -> Double {
        switch ratio {
        case ..<0.25: return 0.35
        case ..<0.5: return 0.6
        case ..<0.75: return 0.8
        default: return 1
        }
    }

    /// 53 columns of 7 days (first weekday at the top), ending with this week.
    /// Future days are nil.
    private var weekColumns: [[Date?]] {
        let today = calendar.startOfDay(for: .now)
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start,
              let firstWeek = calendar.date(byAdding: .weekOfYear, value: -52, to: thisWeek) else { return [] }
        return (0...52).map { column in
            (0..<7).map { row in
                guard let day = calendar.date(byAdding: .day, value: column * 7 + row, to: firstWeek),
                      day <= today else { return nil }
                return day
            }
        }
    }
}

// MARK: - Profile storage

enum Profile {
    static let nameKey = "profileName"
    static let goalTextKey = "profileGoal"
    static let weeklyGoalKey = "weeklyWorkoutGoal"
    static let bigLiftsKey = "profileBigLifts"
    static let photoVersionKey = "profilePhotoVersion"
    static let defaultBigLifts = ["Bench Press", "Squat", "Deadlift", "Overhead Press"]

    /// The photo lives in the app's Documents folder (not synced to iCloud).
    private static var photoURL: URL { URL.documentsDirectory.appending(path: "profile-photo.jpg") }

    static func loadPhoto() -> UIImage? {
        UIImage(contentsOfFile: photoURL.path())
    }

    /// Saves a downscaled JPEG, or removes the photo when `data` is nil.
    static func savePhoto(_ data: Data?) {
        guard let data, let image = UIImage(data: data) else {
            try? FileManager.default.removeItem(at: photoURL)
            return
        }
        let side: CGFloat = 600
        let scale = min(1, side / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        try? resized.jpegData(compressionQuality: 0.85)?.write(to: photoURL, options: .atomic)
    }
}

// MARK: - Edit profile

struct EditProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @AppStorage(Profile.nameKey) private var name = ""
    @AppStorage(Profile.goalTextKey) private var goalText = ""
    @AppStorage(Profile.weeklyGoalKey) private var weeklyGoal = 3
    @AppStorage(Profile.bigLiftsKey) private var bigLiftNames = Profile.defaultBigLifts.joined(separator: "|")
    @AppStorage(Profile.photoVersionKey) private var photoVersion = 0
    @AppStorage(BodyType.storageKey) private var bodyType: BodyType = .man
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var photo: UIImage?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        Group {
                            if let photo {
                                Image(uiImage: photo)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Image(systemName: "person.crop.circle.fill")
                                    .resizable()
                                    .foregroundStyle(.tint)
                            }
                        }
                        .frame(width: 64, height: 64)
                        .clipShape(Circle())
                        .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 8) {
                            PhotosPicker(selection: $pickedPhoto, matching: .images) {
                                Text(photo == nil ? "Choose Photo" : "Change Photo")
                            }
                            if photo != nil {
                                Button("Remove Photo", role: .destructive) {
                                    Profile.savePhoto(nil)
                                    photo = nil
                                    photoVersion += 1
                                }
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                    TextField("Name", text: $name)
                        .textContentType(.name)
                    TextField("Goal (e.g. Building strength 💪)", text: $goalText)
                }
                .themedRows()

                Section {
                    Stepper("\(weeklyGoal) workouts a week", value: $weeklyGoal, in: 1...7)
                } header: {
                    Text("Weekly goal")
                } footer: {
                    Text("Shown as a ring on your profile.")
                }
                .themedRows()

                Section {
                    ForEach(0..<4, id: \.self) { index in
                        Picker(String(localized: "Lift \(index + 1)"), selection: liftBinding(index)) {
                            ForEach(exerciseNames, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.navigationLink)
                    }
                } header: {
                    Text("Big lifts")
                } footer: {
                    Text("Shown with your best estimated 1RM on your profile.")
                }
                .themedRows()

                Section {
                    Picker("Body type", selection: $bodyType) {
                        ForEach(BodyType.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("Used for the exercise illustrations.")
                }
                .themedRows()
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .themedScreen()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { photo = Profile.loadPhoto() }
            .onChange(of: pickedPhoto) { _, item in
                guard let item else { return }
                Task {
                    let data = try? await item.loadTransferable(type: Data.self)
                    Profile.savePhoto(data)
                    photo = Profile.loadPhoto()
                    photoVersion += 1
                }
            }
        }
    }

    /// Unique exercise names for the big-lift pickers.
    private var exerciseNames: [String] {
        var seen = Set<String>()
        return exercises.map(\.name).filter { seen.insert($0).inserted }
    }

    private func liftBinding(_ index: Int) -> Binding<String> {
        Binding {
            let lifts = bigLiftNames.split(separator: "|").map(String.init)
            return index < lifts.count ? lifts[index] : Profile.defaultBigLifts[index]
        } set: { newValue in
            var lifts = bigLiftNames.split(separator: "|").map(String.init)
            while lifts.count < 4 { lifts.append(Profile.defaultBigLifts[lifts.count]) }
            lifts[index] = newValue
            bigLiftNames = lifts.joined(separator: "|")
        }
    }
}
