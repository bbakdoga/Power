import SwiftUI
import SwiftData

struct FoodSearchView: View {
    let didSave: () -> Void

    init(didSave: @escaping () -> Void = {}) {
        self.didSave = didSave
    }

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var foods: [RemoteFood] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var selectedFood: RemoteFood?

    var body: some View {
        NavigationStack {
            List {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 {
                    ContentUnavailableView(
                        "Search foods",
                        systemImage: "magnifyingglass",
                        description: Text("Search the USDA food database by food, meal or brand name.")
                    )
                } else if isSearching && foods.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView("Searching…")
                        Spacer()
                    }
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Search unavailable",
                        systemImage: "wifi.exclamationmark",
                        description: Text(errorMessage)
                    )
                } else if foods.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ForEach(foods) { food in
                        Button {
                            selectedFood = food
                        } label: {
                            RemoteFoodRow(
                                name: food.name,
                                brand: food.brand,
                                caloriesPer100Grams: food.caloriesPer100Grams
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .searchable(text: $query, prompt: "Chicken, rice, yogurt…")
            .navigationTitle("Food Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task(id: query) {
                await search()
            }
            .sheet(item: $selectedFood) { food in
                RemoteFoodEntryView(food: food) {
                    didSave()
                    dismiss()
                }
            }
        }
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            foods = []
            errorMessage = nil
            isSearching = false
            return
        }

        do {
            try await Task.sleep(for: .milliseconds(350))
            isSearching = true
            errorMessage = nil
            foods = try await NutritionAPI.search(query: trimmed)
            isSearching = false
        } catch is CancellationError {
            return
        } catch {
            foods = []
            isSearching = false
            errorMessage = error.localizedDescription
        }
    }
}

private struct RemoteFoodRow: View {
    let name: String
    let brand: String?
    let caloriesPer100Grams: Double

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.headline)
                if let brand, !brand.isEmpty {
                    Text(brand)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(caloriesPer100Grams, format: .number.precision(.fractionLength(0)))
                    .font(.subheadline.bold())
                Text("kcal / 100 g")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct RemoteFoodEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let food: RemoteFood
    let didSave: () -> Void
    @State private var grams: Double

    init(food: RemoteFood, didSave: @escaping () -> Void) {
        self.food = food
        self.didSave = didSave
        _grams = State(initialValue: food.servingSize ?? 100)
    }

    private var nutrition: FoodNutrition {
        food.nutrition(for: grams)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Food") {
                    LabeledContent("Name", value: food.name)
                    if let brand = food.brand, !brand.isEmpty {
                        LabeledContent("Brand", value: brand)
                    }
                    LabeledContent("Portion (g)") {
                        TextField("Grams", value: $grams, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section("Estimated nutrition") {
                    LabeledContent(
                        "Calories",
                        value: "\(nutrition.calories.formatted(.number.precision(.fractionLength(0)))) kcal"
                    )
                    LabeledContent(
                        "Protein",
                        value: "\(nutrition.protein.formatted(.number.precision(.fractionLength(0)))) g"
                    )
                    LabeledContent(
                        "Carbohydrates",
                        value: "\(nutrition.carbohydrates.formatted(.number.precision(.fractionLength(0)))) g"
                    )
                    LabeledContent(
                        "Fat",
                        value: "\(nutrition.fat.formatted(.number.precision(.fractionLength(0)))) g"
                    )
                }

                Section {
                    Text("Nutrition values come from USDA FoodData Central and are adjusted to the portion entered above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { save() }
                        .disabled(grams <= 0 || nutrition.calories <= 0)
                }
            }
        }
    }

    private func save() {
        context.insert(NutritionEntry(
            name: food.name,
            grams: grams,
            calories: nutrition.calories,
            proteinGrams: nutrition.protein,
            carbohydrateGrams: nutrition.carbohydrates,
            fatGrams: nutrition.fat,
            source: .manual
        ))
        dismiss()
        didSave()
    }
}
