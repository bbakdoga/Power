import SwiftUI
import SwiftData

struct RootTabView: View {
    enum Tab: Hashable {
        case profile, history, workout, exercises, settings
    }

    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Workout> { $0.endDate == nil }) private var activeWorkouts: [Workout]
    @Query private var exercises: [Exercise]
    @State private var selection: Tab = .workout

    var body: some View {
        TabView(selection: $selection) {
            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                .tag(Tab.profile)
            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(Tab.history)
            WorkoutTabView()
                .tabItem { Label("Workout", systemImage: "plus.circle.fill") }
                .tag(Tab.workout)
            ExercisesView()
                .tabItem { Label("Exercises", systemImage: "dumbbell") }
                .tag(Tab.exercises)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .task {
            SeedData.seedIfNeeded(context)
            SeedData.mergeDuplicates(context)
        }
        .onChange(of: exercises.count) {
            // Synced exercises from iCloud arrived; merge any built-ins that now appear twice.
            SeedData.mergeDuplicates(context)
        }
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
