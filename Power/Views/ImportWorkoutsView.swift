import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Imports workout history from a CSV export (Strong, Hevy or similar): pick a file,
/// review what will be added, then import.
struct ImportWorkoutsView: View {
    /// A file opened from another app ("Open in Power"); nil shows the file picker.
    var fileURL: URL?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(WeightUnit.storageKey) private var appUnit: WeightUnit = .kg
    @State private var picking = false
    @State private var plan: WorkoutImporter.Plan?
    /// Unit each exercise was logged in (source exercise name → unit).
    @State private var units: [String: WeightUnit] = [:]
    /// Re-import workouts that were imported before (to fix their units).
    @State private var replacing = false
    @State private var errorMessage: String?
    @State private var importedCount: Int?
    @State private var importing = false
    @State private var fileName = ""
    /// Suspicious sets the user wants corrected (all of them by default).
    @State private var fixes: Set<String> = []

    var body: some View {
        List {
            if let importedCount {
                doneSection(importedCount)
            } else if let plan {
                previewSections(plan)
            } else {
                introSection
            }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .themedRows()
            }
        }
        .navigationTitle("Import Workouts")
        .navigationBarTitleDisplayMode(.inline)
        .themedScreen()
        .fileImporter(isPresented: $picking,
                      allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText, .text]) { result in
            switch result {
            case .success(let url): load(url)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .onAppear {
            if let fileURL, plan == nil { load(fileURL) }
        }
    }

    // MARK: - Sections

    private var introSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label("Bring your history", systemImage: "square.and.arrow.down.on.square")
                    .font(.headline)
                Text("Import workouts exported as a CSV file from Strong, Hevy or another app. Your sets, records and charts carry over.")
                    .foregroundStyle(.secondary)
                Text("In Strong: Settings → Export Data. In Hevy: Settings → Export & Import Data.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            Button {
                errorMessage = nil
                picking = true
            } label: {
                Label("Choose CSV File", systemImage: "doc.badge.plus")
            }
        }
        .themedRows()
    }

    @ViewBuilder
    private func previewSections(_ plan: WorkoutImporter.Plan) -> some View {
        Section {
            LabeledContent("File", value: fileName)
            LabeledContent("Format", value: plan.source.format)
            LabeledContent("Workouts to import", value: "\(plan.workouts(replacing: replacing).count)")
            LabeledContent("Sets", value: "\(plan.setCount(replacing: replacing))")
            if let range = plan.dateRange(replacing: replacing) {
                LabeledContent("Dates",
                               value: "\(range.lowerBound.formatted(date: .abbreviated, time: .omitted)) – \(range.upperBound.formatted(date: .abbreviated, time: .omitted))")
            }
            if plan.duplicateCount > 0 && !replacing {
                LabeledContent("Already in Power (skipped)", value: "\(plan.duplicateCount)")
            }
        } header: {
            Text("Preview")
        }
        .themedRows()

        if plan.duplicateCount > 0 {
            Section {
                Toggle(String(localized: "Replace the \(plan.duplicateCount) workouts imported before"), isOn: $replacing)
            } footer: {
                Text("Use this to fix units or typos in an earlier import. Those workouts are deleted and imported again with the settings below.")
            }
            .themedRows()
        }

        unitSection(plan)

        if !plan.suspicious.isEmpty {
            Section {
                ForEach(plan.suspicious) { item in
                    Toggle(isOn: Binding(
                        get: { fixes.contains(item.id) },
                        set: { if $0 { fixes.insert(item.id) } else { fixes.remove(item.id) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(item.exercise) · \(item.date.formatted(date: .abbreviated, time: .omitted))")
                                .font(.subheadline)
                            Text("\(number(item.weight)) × \(item.reps) → \(number(item.suggested)) × \(item.reps)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Possible typos")
            } footer: {
                Text("These weights are much heavier than your usual sets, like a missing decimal point. Turned on means the corrected weight is imported.")
            }
            .themedRows()
        }

        Section {
            DisclosureGroup(String(localized: "\(plan.matches.count) matched to Power exercises")) {
                ForEach(plan.matches.keys.sorted(), id: \.self) { name in
                    LabeledContent(name, value: plan.matches[name] ?? "")
                        .font(.footnote)
                }
            }
            if !plan.newExercises.isEmpty {
                DisclosureGroup(String(localized: "\(plan.newExercises.count) new custom exercises")) {
                    ForEach(plan.newExercises, id: \.self) { name in
                        Text(name).font(.footnote)
                    }
                }
            }
        } header: {
            Text("Exercises")
        }
        .themedRows()

        Section {
            Button {
                runImport(plan)
            } label: {
                HStack {
                    Spacer()
                    if importing {
                        ProgressView()
                    } else {
                        let count = plan.workouts(replacing: replacing).count
                        Text(count == 0 ? String(localized: "Nothing new to import")
                             : String(localized: "Import \(count) workouts"))
                            .bold()
                    }
                    Spacer()
                }
            }
            .disabled(plan.workouts(replacing: replacing).isEmpty || importing)
            Button("Choose a Different File") {
                self.plan = nil
                picking = true
            }
        }
        .themedRows()
    }

    /// Per-exercise kg/lb choice, pre-filled with the importer's guess.
    private func unitSection(_ plan: WorkoutImporter.Plan) -> some View {
        let poundCount = plan.units.filter { units[$0.name] == .lb }.count
        return Section {
            DisclosureGroup(String(localized: "\(poundCount) of \(plan.units.count) exercises in lb")) {
                HStack {
                    Button("All kg") { setAll(.kg, plan) }
                    Spacer()
                    Button("All lb") { setAll(.lb, plan) }
                }
                .buttonStyle(.borderless)
                .font(.subheadline)
                ForEach(plan.units) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.subheadline)
                                .lineLimit(2)
                            Text("Typical: \(number(item.typicalWeight)) · \(String(localized: "\(item.setCount) sets"))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker(item.name, selection: unitBinding(item.name)) {
                            ForEach(WeightUnit.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
        } header: {
            Text("Weight units")
        } footer: {
            Text("The file doesn't say which unit each exercise used, so Power guessed. Check the ones you logged in pounds. Each exercise keeps its unit for future workouts.")
        }
        .themedRows()
    }

    private func unitBinding(_ name: String) -> Binding<WeightUnit> {
        Binding { units[name] ?? appUnit } set: { units[name] = $0 }
    }

    private func setAll(_ unit: WeightUnit, _ plan: WorkoutImporter.Plan) {
        for item in plan.units { units[item.name] = unit }
    }

    private func doneSection(_ count: Int) -> some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                Text("Imported \(count) workouts")
                    .font(.title3.bold())
                Text("They're in History now, and your records, charts and profile include them.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            Button("Done") { dismiss() }
                .frame(maxWidth: .infinity)
        }
        .themedRows()
    }

    // MARK: - Actions

    private func load(_ url: URL) {
        errorMessage = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                errorMessage = String(localized: "The file couldn't be read.")
                return
            }
            let result = try WorkoutCSVParser.parse(text, distanceIsMiles: appUnit == .lb)
            guard !result.workouts.isEmpty else {
                errorMessage = String(localized: "No workouts were found in this file.")
                return
            }
            fileName = url.lastPathComponent
            let newPlan = WorkoutImporter.plan(for: result, in: context)
            fixes = Set(newPlan.suspicious.map(\.id))
            units = Dictionary(uniqueKeysWithValues: newPlan.units.map { ($0.name, $0.suggested) })
            replacing = false
            plan = newPlan
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private func runImport(_ plan: WorkoutImporter.Plan) {
        importing = true
        // Let the progress spinner draw before the (synchronous) import starts.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            importedCount = WorkoutImporter.run(plan, units: units, appUnit: appUnit, replacing: replacing,
                                                fixing: fixes, in: context)
            importing = false
        }
    }
}
