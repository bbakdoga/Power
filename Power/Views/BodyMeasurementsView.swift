import SwiftUI
import SwiftData
import Charts

/// Latest value of each body measurement, with a chart and history per measurement.
struct BodyMeasurementsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \BodyMeasurement.date, order: .reverse) private var measurements: [BodyMeasurement]
    @AppStorage(WeightUnit.storageKey) private var unit: WeightUnit = .kg
    @AppStorage(HealthSync.enabledKey) private var healthEnabled = false
    @State private var adding = false

    var body: some View {
        List {
            ForEach(BodyMeasurementKind.allCases) { kind in
                let entries = measurements.filter { $0.kind == kind }
                NavigationLink {
                    BodyMeasurementDetailView(kind: kind)
                } label: {
                    HStack {
                        Label(kind.title, systemImage: kind.systemImage)
                        Spacer()
                        if let latest = entries.first {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(kind.format(latest.value, unit: unit))
                                    .font(.headline.monospacedDigit())
                                if entries.count > 1 {
                                    ChangeText(kind: kind, change: latest.value - entries[1].value, unit: unit)
                                }
                            }
                        } else {
                            Text("–")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Body")
        .task {
            if healthEnabled {
                await HealthSync.shared.importBodyweight(into: context)
            }
        }
        .toolbar {
            Button {
                adding = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add measurement")
        }
        .sheet(isPresented: $adding) {
            AddMeasurementView(initialKind: .bodyweight)
        }
    }
}

struct BodyMeasurementDetailView: View {
    let kind: BodyMeasurementKind

    @Environment(\.modelContext) private var context
    @Query(sort: \BodyMeasurement.date, order: .reverse) private var measurements: [BodyMeasurement]
    @AppStorage(WeightUnit.storageKey) private var unit: WeightUnit = .kg
    @State private var adding = false

    var body: some View {
        let entries = measurements.filter { $0.kind == kind }

        List {
            Section {
                if entries.count < 2 {
                    Text("Add at least two entries to see a chart.")
                        .foregroundStyle(.secondary)
                } else {
                    Chart(entries) { entry in
                        LineMark(x: .value("Date", entry.date),
                                 y: .value(kind.title, kind.displayValue(entry.value, unit: unit)))
                        PointMark(x: .value("Date", entry.date),
                                  y: .value(kind.title, kind.displayValue(entry.value, unit: unit)))
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartYAxisLabel(kind.unitLabel(unit))
                    .frame(height: 220)
                    .padding(.vertical, 8)
                }
            }

            Section("History") {
                if entries.isEmpty {
                    Text("No entries yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    LabeledContent(entry.date.formatted(date: .abbreviated, time: .omitted),
                                   value: kind.format(entry.value, unit: unit))
                }
                .onDelete { offsets in
                    for index in offsets {
                        context.delete(entries[index])
                    }
                }
            }
        }
        .navigationTitle(kind.title)
        .toolbar {
            Button {
                adding = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add \(kind.title)")
        }
        .sheet(isPresented: $adding) {
            AddMeasurementView(initialKind: kind)
        }
    }
}

private struct ChangeText: View {
    let kind: BodyMeasurementKind
    let change: Double
    let unit: WeightUnit

    var body: some View {
        let shown = kind.displayValue(abs(change), unit: unit).formatted(.number.precision(.fractionLength(0...1)))
        Text(change == 0 ? "No change" : "\(change > 0 ? "+" : "−")\(shown)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct AddMeasurementView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage(WeightUnit.storageKey) private var unit: WeightUnit = .kg
    @AppStorage(HealthSync.enabledKey) private var healthEnabled = false
    @State private var kind: BodyMeasurementKind
    @State private var value: Double?
    @State private var date = Date.now

    init(initialKind: BodyMeasurementKind) {
        _kind = State(initialValue: initialKind)
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Measurement", selection: $kind) {
                    ForEach(BodyMeasurementKind.allCases) { Text($0.title).tag($0) }
                }
                HStack {
                    TextField("Value", value: $value, format: .number)
                        .keyboardType(.decimalPad)
                    Text(kind.unitLabel(unit))
                        .foregroundStyle(.secondary)
                }
                DatePicker("Date", selection: $date, in: ...Date.now)
            }
            .navigationTitle("Add Measurement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled((value ?? 0) <= 0)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard let value, value > 0 else { return }
        let measurement = BodyMeasurement(date: date, kind: kind, value: kind.storedValue(value, unit: unit))
        context.insert(measurement)
        if healthEnabled && kind == .bodyweight {
            HealthSync.shared.saveBodyweight(kilograms: measurement.value, date: date)
        }
        dismiss()
    }
}
