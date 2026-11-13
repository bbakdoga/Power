import SwiftUI
import SwiftData

@main
struct PowerApp: App {
    @State private var restTimer = RestTimer()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(restTimer)
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
