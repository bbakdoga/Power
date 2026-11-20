import SwiftUI
import SwiftData

@main
struct PowerApp: App {
    @State private var restTimer = RestTimer.shared
    @AppStorage(AppLanguage.storageKey) private var language: AppLanguage = .system
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .system
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Keep the bundle language in sync with the in-app choice from launch on.
        let stored = UserDefaults.standard.string(forKey: AppLanguage.storageKey)
        (stored.flatMap(AppLanguage.init(rawValue:)) ?? .system).applyToBundle()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(restTimer)
                .environment(\.locale, language.locale)
                .preferredColorScheme(theme.colorScheme)
                .tint(theme.accent)
        }
        .onChange(of: language) { _, newLanguage in
            newLanguage.applyToBundle()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { restTimer.clearIfFinished() }
        }
        .modelContainer(Self.container)
    }

    /// iCloud container that workouts are backed up to.
    static let iCloudContainerID = "iCloud.com.bbakdoga.Power"

    /// Syncs with the user's private iCloud database. Existing on-device data is uploaded
    /// automatically on first launch. If CloudKit can't be set up, keep working on-device only.
    private static let container: ModelContainer = {
        let schema = Schema(AppSchema.models)
        do {
            let cloud = ModelConfiguration(schema: schema, cloudKitDatabase: .private(iCloudContainerID))
            return try ModelContainer(for: schema, configurations: cloud)
        } catch {
            print("iCloud sync unavailable, using on-device storage: \(error)")
        }
        do {
            let local = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
            return try ModelContainer(for: schema, configurations: local)
        } catch {
            fatalError("Could not open the workout database: \(error)")
        }
    }()
}
