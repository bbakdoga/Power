import SwiftUI
import SwiftData
import CloudKit

struct SettingsView: View {
    @AppStorage(WeightUnit.storageKey) private var unit: WeightUnit = .kg
    @AppStorage(AppLanguage.storageKey) private var language: AppLanguage = .system
    @State private var iCloudStatus: ICloudStatus = .checking

    /// The picked language differs from the one this launch is running in.
    private var needsRelaunch: Bool {
        let wanted = language == .system
            ? (Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: Locale.preferredLanguages).first ?? "en")
            : language.rawValue
        return !AppLanguage.active.hasPrefix(wanted)
    }
    @AppStorage(HealthSync.enabledKey) private var healthEnabled = false
    @Environment(\.modelContext) private var context

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("App Language", selection: $language) {
                        ForEach(AppLanguage.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                } header: {
                    Text("Language")
                } footer: {
                    if needsRelaunch {
                        Text("Close and reopen Power to switch everything, including the Lock Screen timer.")
                            .foregroundStyle(.orange)
                    }
                }

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
        case .checking: return String(localized: "Checking…")
        case .on: return String(localized: "On")
        case .signedOut: return String(localized: "Signed Out")
        case .unavailable: return String(localized: "Unavailable")
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
        case .on: return String(localized: "Workouts, routines and exercises are backed up to your iCloud and sync to your other devices.")
        case .signedOut: return String(localized: "Sign in to iCloud in the Settings app (and allow iCloud Drive) to back up your workouts. Until then they're stored only on this iPhone.")
        case .unavailable: return String(localized: "iCloud couldn't be reached. Your workouts are safe on this iPhone and will back up when iCloud is available.")
        }
    }
}
