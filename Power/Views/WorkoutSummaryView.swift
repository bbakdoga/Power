import SwiftUI
import SwiftData

/// Shown after a workout is saved: totals, records, best sets, sharing and
/// "Save as Routine".
struct WorkoutSummaryView: View {
    let workout: Workout
    /// False when the workout came from a routine that already exists.
    let canSaveRoutine: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage(WeightUnit.storageKey) private var unit: WeightUnit = .kg
    @State private var naming = false
    @State private var routineName = ""
    @State private var savedRoutine = false
    @State private var shareImage: Image?

    var body: some View {
        let stats = WorkoutSummaryStats(workout: workout, unit: unit)

        NavigationStack {
            List {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: stats.records.isEmpty ? "checkmark.seal.fill" : "trophy.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(stats.records.isEmpty ? Color.green : Color.yellow)
                            .symbolEffect(.bounce, value: workout.persistentModelID)
                        Text("Workout complete")
                            .font(.title2.bold())
                        Text("\(workout.name) · \(workout.startDate.formatted(date: .abbreviated, time: .shortened))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                Section {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        StatTile(title: "Time", value: workout.duration.clockString, systemImage: "clock", tint: .teal)
                        StatTile(title: "Volume", value: stats.volumeText, systemImage: "scalemass", tint: .purple)
                        StatTile(title: "Sets", value: "\(workout.completedSetCount)", systemImage: "checkmark.circle", tint: .green)
                        StatTile(title: "Records", value: "\(stats.records.count)", systemImage: "trophy.fill", tint: .yellow)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                if !stats.records.isEmpty {
                    Section("New records") {
                        ForEach(stats.records, id: \.self) { record in
                            Label(record, systemImage: "trophy.fill")
                                .labelStyle(TintedIconLabelStyle(tint: .yellow))
                        }
                    }
                }

                Section("Best sets") {
                    ForEach(stats.bestSets, id: \.name) { item in
                        LabeledContent(item.name, value: item.best)
                    }
                }

                Section {
                    if let shareImage {
                        ShareLink(item: shareImage,
                                  preview: SharePreview("\(workout.name) – Power", image: shareImage)) {
                            Label("Share Workout", systemImage: "square.and.arrow.up")
                        }
                    }
                    if canSaveRoutine && !savedRoutine {
                        Button {
                            routineName = workout.name
                            naming = true
                        } label: {
                            Label("Save as Routine", systemImage: "square.and.arrow.down")
                        }
                    } else if savedRoutine {
                        Label("Saved to My routines", systemImage: "checkmark")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Save as a routine?", isPresented: $naming) {
                TextField("Routine name", text: $routineName)
                Button("Save Routine") { saveRoutine() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Start it again any time from My routines on the Workout tab.")
            }
            .task {
                shareImage = renderShareCard(stats)
            }
        }
    }

    private func saveRoutine() {
        let routine = WorkoutStarter.saveAsRoutine(workout, in: context)
        let name = routineName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { routine.name = name }
        try? context.save()
        savedRoutine = true
    }

    @MainActor
    private func renderShareCard(_ stats: WorkoutSummaryStats) -> Image? {
        let renderer = ImageRenderer(content: WorkoutShareCard(workout: workout, stats: stats))
        renderer.scale = 3
        return renderer.uiImage.map { Image(uiImage: $0) }
    }
}

/// Numbers shared by the summary screen and the share image.
struct WorkoutSummaryStats {
    let volumeText: String
    let records: [String]
    let bestSets: [(name: String, best: String)]

    init(workout: Workout, unit appUnit: WeightUnit) {
        let volume = appUnit.fromKg(workout.totalVolumeKg)
        volumeText = volume >= 10_000
            ? "\((volume / 1000).formatted(.number.precision(.fractionLength(0...1))))k \(appUnit.rawValue)"
            : "\(volume.formatted(.number.precision(.fractionLength(0)))) \(appUnit.rawValue)"

        var records: [String] = []
        var bestSets: [(String, String)] = []
        for entry in workout.sortedExercises {
            guard let exercise = entry.exercise else { continue }
            let unit = exercise.unit(default: appUnit)
            let working = entry.completedSets.filter { $0.setType != .warmup }
            for set in working {
                for kind in PersonalRecords.newRecords(for: set) {
                    records.append("\(exercise.name): \(kind.title)")
                }
            }
            // Best set: highest est. 1RM for strength, otherwise the longest/farthest.
            let best: WorkoutSet?
            switch exercise.tracking {
            case .weightReps: best = working.max { $0.estimatedOneRepMaxKg < $1.estimatedOneRepMaxKg }
            case .duration: best = working.max { $0.durationSeconds < $1.durationSeconds }
            case .distanceDuration, .weightDistance: best = working.max { $0.distanceMeters < $1.distanceMeters }
            }
            if let best {
                bestSets.append((exercise.name, best.summary(exercise.tracking, unit: unit)))
            }
        }
        // One line per exercise and record type, even if several sets broke it.
        self.records = records.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        self.bestSets = bestSets
    }
}

/// The image shared to Messages, WhatsApp, Instagram, etc.
struct WorkoutShareCard: View {
    let workout: Workout
    let stats: WorkoutSummaryStats

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("POWER", systemImage: "bolt.fill")
                    .font(.headline.bold())
                Spacer()
                Text(workout.startDate.formatted(date: .abbreviated, time: .omitted))
                    .font(.subheadline)
                    .opacity(0.8)
            }
            Text(workout.name)
                .font(.system(size: 30, weight: .heavy))
                .lineLimit(2)
            HStack(spacing: 0) {
                stat(workout.duration.clockString, "Time")
                stat(stats.volumeText, "Volume")
                stat("\(workout.completedSetCount)", "Sets")
                if !stats.records.isEmpty {
                    stat("\(stats.records.count)", "Records")
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(stats.bestSets.prefix(6), id: \.name) { item in
                    HStack {
                        Text(item.name)
                            .fontWeight(.semibold)
                        Spacer()
                        Text(item.best)
                            .monospacedDigit()
                            .opacity(0.85)
                    }
                    .font(.subheadline)
                }
                if stats.bestSets.count > 6 {
                    Text("+ \(stats.bestSets.count - 6) more")
                        .font(.caption)
                        .opacity(0.7)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(28)
        .frame(width: 380)
        .background(
            LinearGradient(colors: [Color(red: 0.98, green: 0.47, blue: 0.16), Color(red: 0.86, green: 0.2, blue: 0.16)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 28))
    }

    private func stat(_ value: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.bold().monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.caption)
                .opacity(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TintedIconLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}
