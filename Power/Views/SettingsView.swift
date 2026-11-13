import SwiftUI
import SwiftData
import CloudKit

struct SettingsView: View {
    @AppStorage(WeightUnit.storageKey) private var unit: WeightUnit = .kg
    @State private var iCloudStatus: ICloudStatus = .checking
    @AppStorage(HealthSync.enabledKey) private var healthEnabled = false
    @Environment(\.modelContext) private var context

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

                if HealthSync.shared.isAvailable {
                    Section {
                        Toggle("Sync with Apple Health", isOn: $healthEnabled)
                            .onChange(of: healthEnabled) { _, isOn in
                                guard isOn else { return }
                                Task {
                                    if await HealthSync.shared.requestAuthorization() {
                                        await HealthSync.shared.importBodyweight(into: context)
                                    } else {
                                        healthEnabled = false
                                    }
                                }
                            }
                    } header: {
                        Text("Apple Health")
                    } footer: {
                        Text("Saves finished workouts and the bodyweight you log to Health, and imports bodyweight from your scale or the Health app. You can change exactly what's shared in the Health app.")
                    }
                }

                Section {
                    LabeledContent("iCloud backup") {
                        Label(iCloudStatus.title, systemImage: iCloudStatus.systemImage)
                            .foregroundStyle(iCloudStatus == .on ? Color.green : Color.secondary)
                    }
                } header: {
                    Text("Backup")
                } footer: {
                    Text(iCloudStatus.footer)
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.appVersion)
                } footer: {
                    Text("Every feature is free.")
                }
            }
            .navigationTitle("Settings")
            .task { await refreshICloudStatus() }
            .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
                Task { await refreshICloudStatus() }
            }
        }
    }

    private func refreshICloudStatus() async {
        let status = try? await CKContainer(identifier: PowerApp.iCloudContainerID).accountStatus()
        iCloudStatus = status == .available ? .on : (status == nil ? .unavailable : .signedOut)
    }
}

private enum ICloudStatus {
    case checking, on, signedOut, unavailable

    var title: String {
        switch self {
        case .checking: return "Checking…"
        case .on: return "On"
        case .signedOut: return "Off"
        case .unavailable: return "Unavailable"
        }
    }

    var systemImage: String {
        switch self {
        case .checking: return "icloud"
        case .on: return "checkmark.icloud"
        case .signedOut, .unavailable: return "xmark.icloud"
        }
    }

    var footer: String {
        switch self {
        case .checking: return ""
        case .on: return "Workouts, routines and exercises are backed up to your iCloud and sync to your other devices."
        case .signedOut: return "Sign in to iCloud in the Settings app (and allow iCloud Drive) to back up your workouts. Until then they're stored only on this iPhone."
        case .unavailable: return "iCloud couldn't be reached. Your workouts are safe on this iPhone and will back up when iCloud is available."
        }
    }
}
