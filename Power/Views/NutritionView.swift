import SwiftUI
import SwiftData
import PhotosUI
import UIKit

struct NutritionView: View {
    @Query(sort: \NutritionEntry.date, order: .reverse) private var entries: [NutritionEntry]
    @AppStorage("dailyCalorieGoal") private var calorieGoal = 2_000
    @State private var showingManualEntry = false
    @State private var showingFoodSearch = false
    @State private var showingBarcodeScanner = false
    /// A food photo that turned out to show a labeled product; opens the product search.
    @State private var packagePhoto: PackagePhoto?
    @State private var showingCamera = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var analyzedImageData: Data?
    @State private var suggestions: [FoodReference] = []
    @State private var showingPhotoReview = false
    @State private var isAnalyzing = false
    @State private var analysisError: String?

    private var todayEntries: [NutritionEntry] {
        entries.filter { Calendar.current.isDateInToday($0.date) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NutritionSummaryCard(
                        calories: todayEntries.reduce(0) { $0 + $1.calories },
                        goal: calorieGoal,
                        protein: todayEntries.reduce(0) { $0 + $1.proteinGrams },
                        carbohydrates: todayEntries.reduce(0) { $0 + $1.carbohydrateGrams },
                        fat: todayEntries.reduce(0) { $0 + $1.fatGrams }
                    )
                }
                .themedRows()

                Section("Add food") {
                    Button {
                        showingBarcodeScanner = true
                    } label: {
                        Label("Scan barcode", systemImage: "barcode.viewfinder")
                    }

                    Button {
                        showingFoodSearch = true
                    } label: {
                        Label("Search food database", systemImage: "magnifyingglass")
                    }

                    Button {
                        showingCamera = true
                    } label: {
                        Label("Take food photo", systemImage: "camera.fill")
                    }

                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label("Choose food photo", systemImage: "photo.on.rectangle")
                    }

                    Button {
                        showingManualEntry = true
                    } label: {
                        Label("Enter food manually", systemImage: "square.and.pencil")
                    }
                }
                .themedRows()

                Section("Today") {
                    if todayEntries.isEmpty {
                        ContentUnavailableView(
                            "No food logged",
                            systemImage: "fork.knife",
                            description: Text("Add a meal manually or estimate it from a photo.")
                        )
                    } else {
                        ForEach(todayEntries) { entry in
                            NutritionEntryRow(entry: entry)
                        }
                        .onDelete(perform: deleteTodayEntries)
                    }
                }
                .themedRows()
            }
            .navigationTitle("Nutrition")
            .themedScreen()
            .overlay {
                if isAnalyzing {
                    ZStack {
                        Color.black.opacity(0.15).ignoresSafeArea()
                        ProgressView("Analyzing food…")
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .sheet(isPresented: $showingManualEntry) {
                ManualNutritionEntryView()
            }
            .sheet(isPresented: $showingFoodSearch) {
                FoodSearchView()
            }
            .fullScreenCover(item: $packagePhoto) { photo in
                BarcodeFoodView(packageImage: photo.image)
            }
            .fullScreenCover(isPresented: $showingBarcodeScanner) {
                BarcodeFoodView()
            }
            .fullScreenCover(isPresented: $showingCamera) {
                CameraPicker(
                    onImage: { image in
                        showingCamera = false
                        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
                        analyze(data)
                    },
                    onCancel: {
                        showingCamera = false
                    }
                )
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showingPhotoReview) {
                if let analyzedImageData {
                    PhotoFoodReviewView(imageData: analyzedImageData, suggestions: suggestions)
                }
            }
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        analyze(data)
                    } else {
                        analysisError = String(localized: "The selected photo could not be loaded.")
                    }
                    selectedPhoto = nil
                }
            }
            .alert("Photo analysis unavailable", isPresented: Binding(
                get: { analysisError != nil },
                set: { if !$0 { analysisError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(analysisError ?? "")
            }
        }
    }

    private func analyze(_ data: Data) {
        analyzedImageData = data
        isAnalyzing = true

        Task {
            // Bottles, cans and packages have large printed text; dishes don't. Those are
            // looked up as products instead of guessed as one of the 101 dish types.
            if let image = UIImage(data: data),
               let lines = try? await PackageReader.textLines(in: image),
               PackageReader.looksLikePackage(lines) {
                isAnalyzing = false
                packagePhoto = PackagePhoto(image: image)
                return
            }
            do {
                let labels = try await FoodImageClassifier.labels(in: data)
                var resolvedSuggestions = FoodCatalog.suggestions(for: labels)

                if resolvedSuggestions.isEmpty, let bestLabel = labels.first {
                    let remoteFoods = try? await NutritionAPI.search(query: bestLabel)
                    if let bestMatch = remoteFoods?.first {
                        resolvedSuggestions = [bestMatch.foodReference]
                    }
                }

                suggestions = resolvedSuggestions
                isAnalyzing = false
                showingPhotoReview = true
            } catch {
                isAnalyzing = false
                analysisError = String(localized: "Power could not recognize this photo. You can still enter the food manually.")
            }
        }
    }

    @Environment(\.modelContext) private var context

    private func deleteTodayEntries(at offsets: IndexSet) {
        for offset in offsets {
            context.delete(todayEntries[offset])
        }
    }
}

private struct NutritionSummaryCard: View {
    let calories: Double
    let goal: Int
    let protein: Double
    let carbohydrates: Double
    let fat: Double

    private var progress: Double {
        guard goal > 0 else { return 0 }
        return min(calories / Double(goal), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 18) {
                ZStack {
                    Circle()
                        .stroke(.quaternary, lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(.tint, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text(calories, format: .number.precision(.fractionLength(0)))
                            .font(.title2.bold())
                        Text("kcal")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 112, height: 112)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Today")
                        .font(.headline)
                    Text("\(max(goal - Int(calories), 0)) kcal remaining")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ProgressView(value: calories, total: Double(max(goal, 1)))
                }
            }

            HStack {
                MacroValue(title: "Protein", value: protein, color: .blue)
                MacroValue(title: "Carbs", value: carbohydrates, color: .orange)
                MacroValue(title: "Fat", value: fat, color: .purple)
            }
        }
        .padding(.vertical, 8)
    }
}

private struct MacroValue: View {
    let title: LocalizedStringKey
    let value: Double
    let color: Color

    var body: some View {
        VStack(spacing: 3) {
            Text(value, format: .number.precision(.fractionLength(0)))
                .font(.headline)
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("grams")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct NutritionEntryRow: View {
    let entry: NutritionEntry

    private var iconName: String {
        switch entry.source {
        case .photo: "camera.fill"
        case .barcode: "barcode"
        case .manual: "fork.knife"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.headline)
                Text("\(entry.grams.formatted(.number.precision(.fractionLength(0)))) g · P \(entry.proteinGrams.formatted(.number.precision(.fractionLength(0)))) · C \(entry.carbohydrateGrams.formatted(.number.precision(.fractionLength(0)))) · F \(entry.fatGrams.formatted(.number.precision(.fractionLength(0))))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(entry.calories.formatted(.number.precision(.fractionLength(0)))) kcal")
                .font(.subheadline.bold())
        }
    }
}

private struct ManualNutritionEntryView: View {
    let didSave: () -> Void

    init(didSave: @escaping () -> Void = {}) {
        self.didSave = didSave
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var name = ""
    @State private var grams = 100.0
    @State private var calories = 0.0
    @State private var protein = 0.0
    @State private var carbohydrates = 0.0
    @State private var fat = 0.0

    var body: some View {
        NavigationStack {
            Form {
                Section("Food") {
                    TextField("Food name", text: $name)
                    LabeledContent("Portion (g)") {
                        TextField("Grams", value: $grams, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Calories") {
                        TextField("kcal", value: $calories, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section("Macros") {
                    nutrientField("Protein (g)", value: $protein)
                    nutrientField("Carbohydrates (g)", value: $carbohydrates)
                    nutrientField("Fat (g)", value: $fat)
                }
            }
            .navigationTitle("Add Food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || calories <= 0)
                }
            }
        }
    }

    private func nutrientField(_ title: LocalizedStringKey, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            TextField("0", value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
        }
    }

    private func save() {
        context.insert(NutritionEntry(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            grams: grams,
            calories: calories,
            proteinGrams: protein,
            carbohydrateGrams: carbohydrates,
            fatGrams: fat,
            source: .manual
        ))
        dismiss()
        didSave()
    }
}

private struct FoodDraft: Identifiable {
    let food: FoodReference
    var isSelected: Bool
    var grams: Double
    var id: String { food.id }
}

private struct PhotoFoodReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let imageData: Data
    @State private var drafts: [FoodDraft]
    @State private var showingFoodSearch = false
    @State private var showingManualEntry = false

    init(imageData: Data, suggestions: [FoodReference]) {
        self.imageData = imageData
        _drafts = State(initialValue: suggestions.enumerated().map {
            FoodDraft(
                food: $0.element,
                isSelected: $0.offset == 0,
                grams: $0.element.typicalPortionGrams
            )
        })
    }

    var body: some View {
        NavigationStack {
            List {
                if let image = UIImage(data: imageData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 230)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .listRowInsets(EdgeInsets())
                }

                Section {
                    Text("Select the foods Power recognized, then adjust each estimated portion.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Food suggestions") {
                    if drafts.isEmpty {
                        ContentUnavailableView(
                            "No confident match",
                            systemImage: "questionmark.circle",
                            description: Text("Power could not confidently identify the food in this photo.")
                        )
                    } else {
                        ForEach($drafts) { $draft in
                            PhotoFoodSuggestionRow(draft: $draft)
                        }
                    }
                }

                Section("Not correct?") {
                    Button {
                        drafts.indices.forEach { drafts[$0].isSelected = false }
                        showingFoodSearch = true
                    } label: {
                        Label("None of these — search by name", systemImage: "magnifyingglass")
                    }

                    Button {
                        drafts.indices.forEach { drafts[$0].isSelected = false }
                        showingManualEntry = true
                    } label: {
                        Label("Enter food and nutrition manually", systemImage: "square.and.pencil")
                    }
                }

                Section {
                    Text("Photo results are estimates. Oils, sauces, ingredients and portion sizes may not be visible.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Review Estimate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { save() }
                        .disabled(!drafts.contains(where: { $0.isSelected && $0.grams > 0 }))
                }
            }
            .sheet(isPresented: $showingFoodSearch) {
                FoodSearchView {
                    dismiss()
                }
            }
            .sheet(isPresented: $showingManualEntry) {
                ManualNutritionEntryView {
                    dismiss()
                }
            }
        }
    }

    private func save() {
        for draft in drafts where draft.isSelected && draft.grams > 0 {
            let values = draft.food.nutrition(for: draft.grams)
            context.insert(NutritionEntry(
                name: draft.food.name,
                grams: draft.grams,
                calories: values.calories,
                proteinGrams: values.protein,
                carbohydrateGrams: values.carbohydrates,
                fatGrams: values.fat,
                source: .photo
            ))
        }
        dismiss()
    }
}

private struct PhotoFoodSuggestionRow: View {
    @Binding var draft: FoodDraft

    private var nutrition: FoodNutrition {
        draft.food.nutrition(for: draft.grams)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(draft.food.name, isOn: $draft.isSelected)

            if draft.isSelected {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Estimated portion")
                        Text("Based on a typical serving")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    TextField("Grams", value: $draft.grams, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                    Text("g")
                        .foregroundStyle(.secondary)
                }

                Stepper("Adjust estimated portion", value: $draft.grams, in: 5...2_000, step: 5)
                    .labelsHidden()

                Text("\(nutrition.calories.formatted(.number.precision(.fractionLength(0)))) kcal · P \(nutrition.protein.formatted(.number.precision(.fractionLength(0)))) · C \(nutrition.carbohydrates.formatted(.number.precision(.fractionLength(0)))) · F \(nutrition.fat.formatted(.number.precision(.fractionLength(0))))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onImage: (UIImage) -> Void
        let onCancel: () -> Void

        init(onImage: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onImage = onImage
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onImage(image)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}

/// A photo handed from the food photo flow to the product search.
private struct PackagePhoto: Identifiable {
    let id = UUID()
    let image: UIImage
}
