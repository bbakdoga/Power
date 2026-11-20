import SwiftUI
import SwiftData

enum Onboarding {
    static let completedKey = "hasCompletedOnboarding"
}

/// Three-step welcome shown on first launch: intro, about you, starter routines.
struct OnboardingView: View {
    @Environment(\.modelContext) private var context
    @AppStorage(Onboarding.completedKey) private var completed = false
    @AppStorage(Profile.nameKey) private var name = ""
    @AppStorage(WeightUnit.storageKey) private var unit: WeightUnit = .kg
    @AppStorage(BodyType.storageKey) private var bodyType: BodyType = .man
    @State private var step = 0

    var body: some View {
        TabView(selection: $step) {
            welcome.tag(0)
            aboutYou.tag(1)
            StarterRoutinesPicker(buttonTitle: String(localized: "Start Training")) {
                completed = true
            }
            .tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .animation(.easeInOut, value: step)
        .interactiveDismissDisabled()
    }

    private var welcome: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "bolt.fill")
                .font(.system(size: 64, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 120, height: 120)
                .background(RoundedRectangle(cornerRadius: 28).fill(Color.orange.gradient))
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Welcome to Power")
                    .font(.largeTitle.bold())
                Text("Log your sets, beat your records and see your progress.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 14) {
                feature("checkmark.circle.fill", "Fast set logging with rest timer")
                feature("trophy.fill", "Personal records and smart weight suggestions")
                feature("chart.xyaxis.line", "Charts, weekly summary and body stats")
                feature("icloud.fill", "Backed up to your iCloud")
            }
            .padding(.top, 8)
            Spacer()
            primaryButton("Get Started") { step = 1 }
        }
        .padding(24)
        .padding(.bottom, 32)
    }

    private var aboutYou: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("About you")
                .font(.largeTitle.bold())
                .padding(.top, 40)
            VStack(alignment: .leading, spacing: 8) {
                Text("Name").font(.headline)
                TextField("Your name", text: $name)
                    .textContentType(.givenName)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Weight unit").font(.headline)
                Picker("Weight unit", selection: $unit) {
                    ForEach(WeightUnit.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Exercise illustrations").font(.headline)
                Picker("Body type", selection: $bodyType) {
                    ForEach(BodyType.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Text("You can change all of this later in Profile and Settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            primaryButton("Continue") { step = 2 }
        }
        .padding(24)
        .padding(.bottom, 32)
        .scrollDismissesKeyboard(.interactively)
    }

    private func feature(_ systemImage: String, _ text: LocalizedStringKey) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.orange)
        }
        .font(.body)
    }

    private func primaryButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
    }
}

/// Lets the user pick ready-made programs to add as routines. Used in onboarding
/// and from the Workout tab.
struct StarterRoutinesPicker: View {
    let buttonTitle: String
    let onDone: () -> Void

    @Environment(\.modelContext) private var context
    @State private var selected: Set<StarterProgram> = [.pushPullLegs]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Starter routines")
                .font(.largeTitle.bold())
                .padding(.top, 40)
            Text("Pick a program to get going. You can edit or delete the routines any time.")
                .foregroundStyle(.secondary)
            ForEach(StarterProgram.allCases) { program in
                let isOn = selected.contains(program)
                Button {
                    if isOn { selected.remove(program) } else { selected.insert(program) }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: program.systemImage)
                            .font(.title2)
                            .frame(width: 36)
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(program.title).font(.headline)
                            Text(program.detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundStyle(isOn ? Color.orange : Color.secondary)
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 16).fill(.quaternary.opacity(isOn ? 1 : 0.5)))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
            Spacer()
            Button {
                for program in StarterProgram.allCases where selected.contains(program) {
                    program.add(to: context)
                }
                onDone()
            } label: {
                Text(selected.isEmpty ? String(localized: "Skip") : buttonTitle)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding(24)
        .padding(.bottom, 32)
    }
}
