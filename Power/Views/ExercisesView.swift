import SwiftUI
import PhotosUI
import ImagePlayground
import SwiftData
import Charts

struct ExercisesView: View {
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @AppStorage(AppLanguage.storageKey) private var language: AppLanguage = .system
    @State private var showingNew = false

    private var availableGroups: [MuscleGroup] {
        MuscleGroup.allCases.filter { !exercises(for: $0).isEmpty }
    }

    private func exercises(for group: MuscleGroup) -> [Exercise] {
        guard group == .fullBody else {
            return exercises.filter { $0.muscleGroup == group }
        }

        return exercises.filter { exercise in
            guard exercise.muscleGroup != .cardio else { return false }
            if exercise.muscleGroup == .fullBody { return true }
            guard let guide = ExerciseGuide.guide(for: exercise) else { return false }
            return Set(guide.primary + guide.secondary).count > 1
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 16) {
                    ForEach(availableGroups) { group in
                        NavigationLink(value: group) {
                            BodyPartCard(
                                title: group.localizedTitle(language: language),
                                assetName: group.assetName,
                                systemImage: group.systemImage
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle("Exercises")
            .themedScreen()
            .navigationDestination(for: MuscleGroup.self) { group in
                ExerciseGroupView(
                    group: group,
                    exercises: exercises(for: group)
                )
            }
            .navigationDestination(for: Exercise.self) { exercise in
                ExerciseDetailView(exercise: exercise)
            }
            .toolbar {
                Button {
                    showingNew = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New exercise")
            }
            .sheet(isPresented: $showingNew) {
                ExerciseEditorView(exercise: nil)
            }
        }
    }
}

private struct BodyPartCard: View {
    let title: String
    let assetName: String?
    let systemImage: String

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if let assetName {
                    Image(assetName)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(height: 88)

            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 150)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ExerciseGroupView: View {
    let group: MuscleGroup
    let exercises: [Exercise]

    @AppStorage(AppLanguage.storageKey) private var language: AppLanguage = .system
    @State private var search = ""

    private var filteredExercises: [Exercise] {
        search.isEmpty
            ? exercises
            : exercises.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List(filteredExercises) { exercise in
            NavigationLink(value: exercise) {
                ExerciseListRow(exercise: exercise)
            }
        }
        .searchable(text: $search)
        .navigationTitle(group.localizedTitle(language: language))
        .themedScreen()
    }
}

private struct ExerciseListRow: View {
    let exercise: Exercise

    var body: some View {
        HStack(spacing: 12) {
            ExerciseThumbnail(exercise: exercise)
            VStack(alignment: .leading, spacing: 2) {
                Text(exercise.name)
                Text(exercise.equipment.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ExerciseDetailView: View {
    @Bindable var exercise: Exercise
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(WeightUnit.storageKey) private var appUnit: WeightUnit = .kg
    @State private var editing = false

    private var unit: WeightUnit { exercise.unit(default: appUnit) }
    @State private var confirmingDelete = false

    private struct ChartPoint: Identifiable {
        let id: PersistentIdentifier
        let date: Date
        let value: Double
    }

    private var chartPoints: [ChartPoint] {
        exercise.completedEntries.reversed().compactMap { entry -> ChartPoint? in
            let best = entry.bestEstimatedOneRepMaxKg
            guard best > 0, let date = entry.workout?.startDate else { return nil }
            return ChartPoint(id: entry.persistentModelID, date: date, value: unit.fromKg(best))
        }
    }

    var body: some View {
        let points = chartPoints
        let sets = exercise.completedWorkingSets
        let entries = exercise.completedEntries

        List {
            Section {
                ExerciseGraphicView(exercise: exercise)
            }
            .themedRows()

            Section("Estimated 1-rep max (\(unit.rawValue))") {
                if points.count < 2 {
                    Text("Log this exercise in two workouts to see your progress here.")
                        .foregroundStyle(.secondary)
                } else {
                    Chart(points) { point in
                        LineMark(x: .value("Date", point.date), y: .value("e1RM", point.value))
                        PointMark(x: .value("Date", point.date), y: .value("e1RM", point.value))
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 200)
                    .padding(.vertical, 8)
                }
            }
            .themedRows()

            Section("Personal records") {
                LabeledContent("Heaviest weight", value: weightText(sets.map(\.weightKg).max()))
                LabeledContent("Best estimated 1RM", value: weightText(sets.map(\.estimatedOneRepMaxKg).max()))
                LabeledContent("Most reps in one set", value: sets.map(\.reps).max().map { "\($0)" } ?? "–")
                LabeledContent("Best session volume", value: weightText(entries.map(\.volumeKg).max()))
            }
            .themedRows()

            Section("History") {
                if entries.isEmpty {
                    Text("No sets logged yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.workout?.startDate.formatted(date: .abbreviated, time: .omitted) ?? "")
                            .font(.subheadline.bold())
                        Text(entry.completedSets.map { $0.summary(exercise.tracking, unit: unit) }.joined(separator: "   "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .themedRows()

            if exercise.isCustom {
                Section {
                    Button("Delete exercise", role: .destructive) { confirmingDelete = true }
                }
                .themedRows()
            }
        }
        .navigationTitle(exercise.name)
        .themedScreen()
        .toolbar {
            Button("Edit") { editing = true }
        }
        .sheet(isPresented: $editing) {
            ExerciseEditorView(exercise: exercise)
        }
        .confirmationDialog("Delete \(exercise.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                context.delete(exercise)
                dismiss()
            }
        } message: {
            Text("Past workouts keep their sets, but they will no longer show this exercise's name.")
        }
    }

    private func weightText(_ kilograms: Double?) -> String {
        guard let kilograms, kilograms > 0 else { return "–" }
        return "\(unit.format(kg: kilograms)) \(unit.rawValue)"
    }
}

struct ExerciseEditorView: View {
    let exercise: Exercise?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var name = ""
    @State private var muscleGroup: MuscleGroup = .chest
    @State private var equipment: Equipment = .barbell
    @State private var restSeconds = 90
    @State private var tracking: TrackingType = .weightReps
    /// Picture being edited; saved to the exercise on Save.
    @State private var imageData: Data?
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var takingPhoto = false
    @State private var generating = false

    var body: some View {
        NavigationStack {
            Form {
                pictureSection
                TextField("Name", text: $name)
                Picker("Muscle group", selection: $muscleGroup) {
                    ForEach(MuscleGroup.allCases) { Text($0.title).tag($0) }
                }
                Picker("Equipment", selection: $equipment) {
                    ForEach(Equipment.allCases) { Text($0.title).tag($0) }
                }
                Picker("Tracks", selection: $tracking) {
                    ForEach(TrackingType.allCases) { Text($0.title).tag($0) }
                }
                Stepper("Rest timer: \(restSeconds.restLabel)", value: $restSeconds, in: 0...600, step: 15)
            }
            .navigationTitle(exercise == nil ? "New Exercise" : "Edit Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onChange(of: pickedPhoto) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        imageData = image.downscaledJPEG()
                    }
                    pickedPhoto = nil
                }
            }
            .fullScreenCover(isPresented: $takingPhoto) {
                ExercisePhotoCamera { image in
                    imageData = image.downscaledJPEG()
                }
                .ignoresSafeArea()
            }
            .exerciseImagePlayground(isPresented: $generating, concepts: playgroundConcepts) { image in
                imageData = image.downscaledJPEG()
            }
            .onAppear {
                if let exercise {
                    imageData = exercise.imageData
                    name = exercise.name
                    muscleGroup = exercise.muscleGroup
                    equipment = exercise.equipment
                    restSeconds = exercise.restSeconds
                    tracking = exercise.tracking
                }
            }
        }
    }

    /// Preview of the picture plus ways to set it: camera, photo library, or Image Playground.
    private var pictureSection: some View {
        Section {
            HStack(spacing: 16) {
                picturePreview
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 10) {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button {
                            takingPhoto = true
                        } label: {
                            Label("Take Photo", systemImage: "camera")
                        }
                    }
                    PhotosPicker(selection: $pickedPhoto, matching: .images) {
                        Label("Choose Photo", systemImage: "photo")
                    }
                    if #available(iOS 18.1, *) {
                        GenerateDrawingButton(disabled: name.trimmingCharacters(in: .whitespaces).isEmpty) {
                            generating = true
                        }
                    }
                    if imageData != nil {
                        Button("Remove Picture", role: .destructive) { imageData = nil }
                    }
                }
                .buttonStyle(.borderless)
            }
        } footer: {
            Text(imageData == nil
                 ? "Without a picture, the drawing of the exercise's body part is used."
                 : "Shown in your exercise list and on the exercise page.")
        }
    }

    @ViewBuilder
    private var picturePreview: some View {
        if let imageData, let image = UIImage(data: imageData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else if let asset = muscleGroup.assetName, let image = UIImage(named: asset) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .background(Color.white)
        } else {
            Image(systemName: muscleGroup.systemImage)
                .font(.largeTitle)
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary)
        }
    }

    /// What Image Playground should draw: the exercise, its equipment and body part.
    private var playgroundConcepts: [String] {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return [trimmed, "Person doing the \(trimmed) exercise in a gym", "\(equipment.title), \(muscleGroup.title)"]
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let exercise {
            exercise.name = trimmed
            exercise.muscleGroup = muscleGroup
            exercise.equipment = equipment
            exercise.restSeconds = restSeconds
            exercise.tracking = tracking
            exercise.imageData = imageData
        } else {
            let new = Exercise(name: trimmed, muscleGroup: muscleGroup, equipment: equipment,
                               isCustom: true, restSeconds: restSeconds)
            new.tracking = tracking
            new.imageData = imageData
            context.insert(new)
        }
        dismiss()
    }
}

/// The system camera, for taking a picture of a machine.
private struct ExercisePhotoCamera: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ExercisePhotoCamera
        init(_ parent: ExercisePhotoCamera) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - Image Playground (iOS 18.1+)

/// "Generate Drawing", shown only on devices that support Image Playground
/// (Apple Intelligence, iOS 18.1 or later).
@available(iOS 18.1, *)
private struct GenerateDrawingButton: View {
    let disabled: Bool
    let action: () -> Void
    @Environment(\.supportsImagePlayground) private var supportsImagePlayground

    var body: some View {
        if supportsImagePlayground {
            Button(action: action) {
                Label("Generate Drawing", systemImage: "apple.image.playground")
            }
            .disabled(disabled)
        }
    }
}

private struct ExerciseImagePlayground: ViewModifier {
    @Binding var isPresented: Bool
    let concepts: [String]
    let onImage: (UIImage) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.4, *) {
            sheet(content)
                .imagePlaygroundGenerationStyle(.illustration, in: [.illustration, .sketch, .animation])
        } else if #available(iOS 18.1, *) {
            sheet(content)
        } else {
            content
        }
    }

    @available(iOS 18.1, *)
    private func sheet(_ content: Content) -> some View {
        content.imagePlaygroundSheet(isPresented: $isPresented, concepts: concepts.map { .text($0) }) { url in
            if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                onImage(image)
            }
        }
    }
}

private extension View {
    /// Presents Image Playground to draw a picture for an exercise (no-op before iOS 18.1).
    func exerciseImagePlayground(isPresented: Binding<Bool>, concepts: [String],
                                 onImage: @escaping (UIImage) -> Void) -> some View {
        modifier(ExerciseImagePlayground(isPresented: isPresented, concepts: concepts, onImage: onImage))
    }
}
