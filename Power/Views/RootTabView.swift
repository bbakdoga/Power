import SwiftUI
import SwiftData

struct RootTabView: View {
    enum Tab: Hashable {
        case workout, history, routines, exercises, settings
    }

    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Workout> { $0.endDate == nil }) private var activeWorkouts: [Workout]
    @State private var selection: Tab = .workout

    var body: some View {
        TabView(selection: $selection) {
            WorkoutTabView()
                .tabItem { Label("Workout", systemImage: "figure.strengthtraining.traditional") }
                .tag(Tab.workout)
            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(Tab.history)
            RoutinesView()
                .tabItem { Label("Routines", systemImage: "list.bullet.rectangle") }
                .tag(Tab.routines)
            ExercisesView()
                .tabItem { Label("Exercises", systemImage: "dumbbell") }
                .tag(Tab.exercises)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .task { SeedData.seedIfNeeded(context) }
        .onChange(of: activeWorkouts.count) { oldCount, newCount in
            // Jump to the workout tab when a workout is started from another tab.
            if newCount > oldCount { selection = .workout }
        }
    }
}

#Preview {
    RootTabView()
        .environment(RestTimer())
        .modelContainer(for: AppSchema.models, inMemory: true)
}
