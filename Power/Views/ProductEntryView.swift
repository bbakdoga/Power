import SwiftData
import SwiftUI

/// Enter how much of a scanned product was eaten and log it.
@MainActor
struct ProductEntryView: View {
    @Environment(\.modelContext) private var context
    let product: ProductInfo
    let isOfflineCopy: Bool
    let onLogged: () -> Void
    let onEdit: () -> Void
    let onScanAnother: () -> Void
    @State private var amount: Double

    init(
        product: ProductInfo,
        isOfflineCopy: Bool,
        onLogged: @escaping () -> Void,
        onEdit: @escaping () -> Void,
        onScanAnother: @escaping () -> Void
    ) {
        self.product = product
        self.isOfflineCopy = isOfflineCopy
        self.onLogged = onLogged
        self.onEdit = onEdit
        self.onScanAnother = onScanAnother
        _amount = State(initialValue: product.servingGrams ?? 100)
    }

    private var unit: String { product.isLiquid ? "ml" : "g" }

    private var nutrition: FoodNutrition {
        product.nutrition(for: amount)
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(product.displayName)
                        .font(.headline)
                    if !product.brand.isEmpty {
                        Text(product.brand)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Amount") {
                LabeledContent(product.isLiquid ? "Amount (ml)" : "Amount (g)") {
                    TextField("Amount", value: $amount, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }

                HStack(spacing: 8) {
                    quickAmountButton(Text(verbatim: "100 \(unit)"), grams: 100)
                    if let serving = product.servingGrams {
                        quickAmountButton(
                            Text("1 serving (\(format(serving)) \(unit))"),
                            grams: serving
                        )
                        quickAmountButton(Text("2 servings"), grams: serving * 2)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Section("Nutrition for this amount") {
                nutrientRow("Calories", value: nutrition.calories, unit: "kcal")
                nutrientRow("Protein", value: nutrition.protein, unit: "g")
                nutrientRow("Carbohydrates", value: nutrition.carbohydrates, unit: "g")
                nutrientRow("Fat", value: nutrition.fat, unit: "g")
            }

            Section {
                Text(verbatim: "\(format(product.caloriesPer100Grams)) kcal · P \(format(product.proteinPer100Grams)) · C \(format(product.carbohydratePer100Grams)) · F \(format(product.fatPer100Grams))")
                    .font(.subheadline)
                Button("Edit nutrition values", action: onEdit)
            } header: {
                Text(product.isLiquid ? "Per 100 ml" : "Per 100 g")
            }

            Section {
                ProductSourceNote(product: product, isOfflineCopy: isOfflineCopy)
                Button("Scan another product", action: onScanAnother)
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { log() }
                    .disabled(amount <= 0 || nutrition.calories <= 0)
            }
        }
    }

    private func quickAmountButton(_ title: Text, grams: Double) -> some View {
        Button {
            amount = grams
        } label: {
            title
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func nutrientRow(_ title: LocalizedStringKey, value: Double, unit: String) -> some View {
        LabeledContent(title) {
            Text(verbatim: "\(format(value)) \(unit)")
        }
    }

    private func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    private func log() {
        context.insert(NutritionEntry(
            name: product.displayName,
            grams: amount,
            calories: nutrition.calories,
            proteinGrams: nutrition.protein,
            carbohydrateGrams: nutrition.carbohydrates,
            fatGrams: nutrition.fat,
            source: .barcode
        ))
        ProductCache.product(for: product.barcode, in: context)?.lastUsedAt = Date()
        onLogged()
    }
}

/// Says where the values came from. Open Food Facts data is under the Open Database
/// License, which requires this attribution.
struct ProductSourceNote: View {
    let product: ProductInfo
    var isOfflineCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch product.source {
            case .openFoodFacts:
                Text("Data: Open Food Facts")
                    .font(.footnote.weight(.semibold))
                Text("Product data by Open Food Facts contributors, available under the Open Database License (ODbL).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let url = OpenFoodFacts.productPageURL(code: product.barcode) {
                    Link("View or improve on Open Food Facts", destination: url)
                        .font(.caption)
                }
            case .usda:
                Text("Data: USDA FoodData Central")
                    .font(.footnote.weight(.semibold))
                Text("Branded Foods database of the U.S. Department of Agriculture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .nutritionLabel:
                Text("Read from your photo of the nutrition table on this iPhone. Check the values against the package.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .user:
                Text("Values entered by you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isOfflineCopy {
                Label("Offline: showing the copy saved on this iPhone.", systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Edit a product's name and per-100 g values, prefilled from a nutrition table photo or
/// from the saved product.
struct ProductNutritionForm: View {
    enum Note {
        case readFromLabel
        case checkValues
        case perServing
        case nothingFound
        case manual
    }

    let note: Note
    let onSave: (ProductInfo) -> Void
    let onRetakePhoto: (() -> Void)?
    @State private var product: ProductInfo
    @State private var convertedFromServing = false

    init(product: ProductInfo, note: Note, onSave: @escaping (ProductInfo) -> Void, onRetakePhoto: (() -> Void)?) {
        self.note = note
        self.onSave = onSave
        self.onRetakePhoto = onRetakePhoto
        _product = State(initialValue: product)
    }

    private var servingBinding: Binding<Double> {
        Binding(
            get: { product.servingGrams ?? 0 },
            set: { product.servingGrams = $0 > 0 ? $0 : nil }
        )
    }

    private var canSave: Bool {
        !product.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && product.caloriesPer100Grams > 0
            && product.caloriesPer100Grams <= 950
    }

    var body: some View {
        Form {
            if let message = noteMessage {
                Section {
                    Label {
                        Text(message)
                    } icon: {
                        Image(systemName: note == .readFromLabel ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(note == .readFromLabel ? Color.green : Color.orange)
                    }
                    .font(.subheadline)

                    if note == .perServing, !convertedFromServing {
                        Button("Convert per-serving values to 100 g") { convertFromServing() }
                            .disabled((product.servingGrams ?? 0) <= 0)
                    }

                    if let onRetakePhoto {
                        Button("Take another photo", action: onRetakePhoto)
                    }
                }
            }

            Section("Product") {
                TextField("Product name", text: $product.name)
                TextField("Brand (optional)", text: $product.brand)
                Toggle("Drink (values per 100 ml)", isOn: $product.isLiquid)
            }

            Section {
                valueField("Calories (kcal)", value: $product.caloriesPer100Grams)
                valueField("Protein (g)", value: $product.proteinPer100Grams)
                valueField("Carbohydrates (g)", value: $product.carbohydratePer100Grams)
                valueField("Fat (g)", value: $product.fatPer100Grams)
            } header: {
                Text(product.isLiquid ? "Per 100 ml" : "Per 100 g")
            }

            Section {
                valueField(product.isLiquid ? "Serving size (ml)" : "Serving size (g)", value: servingBinding)
            } footer: {
                Text(verbatim: product.barcode)
                    .font(.caption.monospacedDigit())
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    var saved = product
                    saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    saved.brand = saved.brand.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(saved)
                }
                .disabled(!canSave)
            }
        }
    }

    private var noteMessage: LocalizedStringKey? {
        switch note {
        case .readFromLabel:
            "Values read from the photo. Check them against the package and add the product name."
        case .checkValues:
            "Some values may be misread. Compare them with the package before saving."
        case .perServing:
            "The label only shows values per serving. Enter the serving size below, then convert the values to 100 g."
        case .nothingFound:
            "No nutrition values were found in the photo. Try again with the table filling the frame, or type the values."
        case .manual:
            nil
        }
    }

    private func convertFromServing() {
        guard let serving = product.servingGrams, serving > 0 else { return }
        let factor = 100 / serving
        product.caloriesPer100Grams *= factor
        product.proteinPer100Grams *= factor
        product.carbohydratePer100Grams *= factor
        product.fatPer100Grams *= factor
        convertedFromServing = true
    }

    private func valueField(_ title: LocalizedStringKey, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            TextField("0", value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
        }
    }
}
