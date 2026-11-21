import Foundation
import SwiftData

@Model
final class NutritionEntry {
    var date: Date = Date()
    var name: String = ""
    var grams: Double = 0
    var calories: Double = 0
    var proteinGrams: Double = 0
    var carbohydrateGrams: Double = 0
    var fatGrams: Double = 0
    var sourceRaw: String = NutritionSource.manual.rawValue

    init(
        date: Date = Date(),
        name: String,
        grams: Double,
        calories: Double,
        proteinGrams: Double,
        carbohydrateGrams: Double,
        fatGrams: Double,
        source: NutritionSource
    ) {
        self.date = date
        self.name = name
        self.grams = grams
        self.calories = calories
        self.proteinGrams = proteinGrams
        self.carbohydrateGrams = carbohydrateGrams
        self.fatGrams = fatGrams
        self.sourceRaw = source.rawValue
    }

    var source: NutritionSource {
        get { NutritionSource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }
}

enum NutritionSource: String, Codable {
    case manual
    case photo
}

struct FoodReference: Identifiable, Hashable {
    let id: String
    let name: String
    let caloriesPer100Grams: Double
    let proteinPer100Grams: Double
    let carbohydratePer100Grams: Double
    let fatPer100Grams: Double
    let keywords: [String]
    let typicalPortionGrams: Double

    init(
        id: String,
        name: String,
        caloriesPer100Grams: Double,
        proteinPer100Grams: Double,
        carbohydratePer100Grams: Double,
        fatPer100Grams: Double,
        keywords: [String],
        typicalPortionGrams: Double
    ) {
        self.id = id
        self.name = name
        self.caloriesPer100Grams = caloriesPer100Grams
        self.proteinPer100Grams = proteinPer100Grams
        self.carbohydratePer100Grams = carbohydratePer100Grams
        self.fatPer100Grams = fatPer100Grams
        self.keywords = keywords
        self.typicalPortionGrams = typicalPortionGrams
    }

    func nutrition(for grams: Double) -> FoodNutrition {
        let factor = grams / 100
        return FoodNutrition(
            calories: caloriesPer100Grams * factor,
            protein: proteinPer100Grams * factor,
            carbohydrates: carbohydratePer100Grams * factor,
            fat: fatPer100Grams * factor
        )
    }
}

struct FoodNutrition {
    let calories: Double
    let protein: Double
    let carbohydrates: Double
    let fat: Double
}

enum FoodCatalog {
    static let foods: [FoodReference] = [
        FoodReference(id: "apple", name: "Apple", caloriesPer100Grams: 52, proteinPer100Grams: 0.3, carbohydratePer100Grams: 13.8, fatPer100Grams: 0.2, keywords: ["apple", "fruit"], typicalPortionGrams: 182),
        FoodReference(id: "banana", name: "Banana", caloriesPer100Grams: 89, proteinPer100Grams: 1.1, carbohydratePer100Grams: 22.8, fatPer100Grams: 0.3, keywords: ["banana"], typicalPortionGrams: 118),
        FoodReference(id: "bread", name: "Bread", caloriesPer100Grams: 265, proteinPer100Grams: 9, carbohydratePer100Grams: 49, fatPer100Grams: 3.2, keywords: ["bread", "toast", "bagel"], typicalPortionGrams: 30),
        FoodReference(id: "chicken-breast", name: "Chicken breast", caloriesPer100Grams: 165, proteinPer100Grams: 31, carbohydratePer100Grams: 0, fatPer100Grams: 3.6, keywords: ["chicken", "poultry"], typicalPortionGrams: 170),
        FoodReference(id: "egg", name: "Egg", caloriesPer100Grams: 155, proteinPer100Grams: 13, carbohydratePer100Grams: 1.1, fatPer100Grams: 11, keywords: ["egg", "omelet", "omelette"], typicalPortionGrams: 50),
        FoodReference(id: "salmon", name: "Salmon", caloriesPer100Grams: 208, proteinPer100Grams: 20, carbohydratePer100Grams: 0, fatPer100Grams: 13, keywords: ["salmon", "fish"], typicalPortionGrams: 170),
        FoodReference(id: "rice", name: "Cooked rice", caloriesPer100Grams: 130, proteinPer100Grams: 2.7, carbohydratePer100Grams: 28, fatPer100Grams: 0.3, keywords: ["rice"], typicalPortionGrams: 158),
        FoodReference(id: "pasta", name: "Cooked pasta", caloriesPer100Grams: 158, proteinPer100Grams: 5.8, carbohydratePer100Grams: 31, fatPer100Grams: 0.9, keywords: ["pasta", "spaghetti", "noodle"], typicalPortionGrams: 140),
        FoodReference(id: "potato", name: "Potato", caloriesPer100Grams: 87, proteinPer100Grams: 1.9, carbohydratePer100Grams: 20, fatPer100Grams: 0.1, keywords: ["potato"], typicalPortionGrams: 173),
        FoodReference(id: "broccoli", name: "Broccoli", caloriesPer100Grams: 35, proteinPer100Grams: 2.4, carbohydratePer100Grams: 7.2, fatPer100Grams: 0.4, keywords: ["broccoli"], typicalPortionGrams: 91),
        FoodReference(id: "salad", name: "Mixed salad", caloriesPer100Grams: 33, proteinPer100Grams: 1.5, carbohydratePer100Grams: 5, fatPer100Grams: 0.5, keywords: ["salad", "vegetable", "greens"], typicalPortionGrams: 85),
        FoodReference(id: "pizza", name: "Pizza", caloriesPer100Grams: 266, proteinPer100Grams: 11, carbohydratePer100Grams: 33, fatPer100Grams: 10, keywords: ["pizza"], typicalPortionGrams: 107),
        FoodReference(id: "burger", name: "Hamburger", caloriesPer100Grams: 254, proteinPer100Grams: 17, carbohydratePer100Grams: 25, fatPer100Grams: 10, keywords: ["burger", "hamburger", "cheeseburger"], typicalPortionGrams: 226),
        FoodReference(id: "oatmeal", name: "Cooked oatmeal", caloriesPer100Grams: 71, proteinPer100Grams: 2.5, carbohydratePer100Grams: 12, fatPer100Grams: 1.5, keywords: ["oatmeal", "porridge", "oat"], typicalPortionGrams: 234),
        FoodReference(id: "yogurt", name: "Yogurt", caloriesPer100Grams: 61, proteinPer100Grams: 3.5, carbohydratePer100Grams: 4.7, fatPer100Grams: 3.3, keywords: ["yogurt", "yoghurt"], typicalPortionGrams: 170),
        FoodReference(id: "steak", name: "Beef steak", caloriesPer100Grams: 271, proteinPer100Grams: 25, carbohydratePer100Grams: 0, fatPer100Grams: 19, keywords: ["steak", "beef steak"], typicalPortionGrams: 225)
    ]

    static func suggestions(for labels: [String]) -> [FoodReference] {
        let normalizedLabels = labels.map {
            $0.lowercased()
                .replacingOccurrences(of: "_", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return foods.filter { food in
            normalizedLabels.contains { label in
                food.keywords.contains { keyword in
                    label == keyword || label.hasPrefix("\(keyword),")
                }
            }
        }
    }
}
