import SwiftUI
import SwiftData

@main
struct PowerApp: App {
    @State private var restTimer = RestTimer()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(restTimer)
        }
        .modelContainer(for: AppSchema.models)
    }
}
