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
    @AppStorage(Onboarding.completedKey) private var onboarded = false
    @State private var showingOnboarding = false
    @State private var openedFile: OpenedFile?

    private struct OpenedFile: Identifiable {
        let url: URL
        var id: URL { url }
    }

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
            if !onboarded {
                // People who already have workouts (from before onboarding existed, or via
                // iCloud on a new device) don't need the welcome screens.
                let hasWorkouts = ((try? context.fetchCount(FetchDescriptor<Workout>())) ?? 0) > 0
                if hasWorkouts { onboarded = true } else { showingOnboarding = true }
            }
        }
        .fullScreenCover(isPresented: $showingOnboarding) {
            OnboardingView()
        }
        .onChange(of: onboarded) { _, done in
            if done { showingOnboarding = false }
        }
        .onOpenURL { url in
            // A CSV shared to Power from another app (e.g. Strong's export): offer to import it.
            if url.isFileURL { openedFile = OpenedFile(url: url) }
        }
        .sheet(item: $openedFile) { file in
            NavigationStack {
                ImportWorkoutsView(fileURL: file.url)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { openedFile = nil }
                        }
                    }
            }
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
