import SwiftUI

struct SettingsView: View {
    @AppStorage(WeightUnit.storageKey) private var unit: WeightUnit = .kg

    var body: some View {
        NavigationStack {
            Form {
                Section("Units") {
                    Picker("Weight", selection: $unit) {
                        ForEach(WeightUnit.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Tools") {
                    NavigationLink {
                        PlateCalculatorView()
                    } label: {
                        Label("Plate calculator", systemImage: "circle.circle")
                    }
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.appVersion)
                } footer: {
                    Text("Every feature is free. Your workouts are stored only on this iPhone.")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
