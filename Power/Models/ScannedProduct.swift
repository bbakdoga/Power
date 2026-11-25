import Foundation
import SwiftData

/// Where the nutrition values of a scanned product came from.
enum ProductDataSource: String, Codable {
    case openFoodFacts
    case usda
    /// Read on the device from a photo of the package's nutrition table.
    case nutritionLabel
    /// Typed or corrected by the user.
    case user

    /// Values the user read or typed themselves are never replaced by an online refresh.
    var isUserProvided: Bool {
        self == .nutritionLabel || self == .user
    }
}

/// On-device copy of a product looked up by barcode, so a product scanned once can be
/// logged again offline. Only the products this user scanned are stored; the online
/// databases themselves are never downloaded or bundled with the app.
@Model
final class ScannedProduct {
    var barcode: String = ""
    var name: String = ""
    var brand: String = ""
    var caloriesPer100Grams: Double = 0
    var proteinPer100Grams: Double = 0
    var carbohydratePer100Grams: Double = 0
    var fatPer100Grams: Double = 0
    /// Grams (or millilitres for drinks) in one serving; 0 when unknown.
    var servingGrams: Double = 0
    var isLiquid: Bool = false
    var sourceRaw: String = ProductDataSource.openFoodFacts.rawValue
    var fetchedAt: Date = Date()
    var lastUsedAt: Date = Date()

    init(product: ProductInfo) {
        barcode = product.barcode
        update(from: product)
    }

    var source: ProductDataSource {
        ProductDataSource(rawValue: sourceRaw) ?? .user
    }

    func update(from product: ProductInfo) {
        name = product.name
        brand = product.brand
        caloriesPer100Grams = product.caloriesPer100Grams
        proteinPer100Grams = product.proteinPer100Grams
        carbohydratePer100Grams = product.carbohydratePer100Grams
        fatPer100Grams = product.fatPer100Grams
        servingGrams = product.servingGrams ?? 0
        isLiquid = product.isLiquid
        sourceRaw = product.source.rawValue
        fetchedAt = Date()
    }

    var info: ProductInfo {
        ProductInfo(
            barcode: barcode,
            name: name,
            brand: brand,
            caloriesPer100Grams: caloriesPer100Grams,
            proteinPer100Grams: proteinPer100Grams,
            carbohydratePer100Grams: carbohydratePer100Grams,
            fatPer100Grams: fatPer100Grams,
            servingGrams: servingGrams > 0 ? servingGrams : nil,
            isLiquid: isLiquid,
            source: source
        )
    }
}

/// Nutrition facts of a packaged product, always per 100 g (or 100 ml for drinks).
struct ProductInfo: Hashable {
    var barcode: String
    var name: String
    var brand: String = ""
    var caloriesPer100Grams: Double = 0
    var proteinPer100Grams: Double = 0
    var carbohydratePer100Grams: Double = 0
    var fatPer100Grams: Double = 0
    var servingGrams: Double?
    var isLiquid: Bool = false
    var source: ProductDataSource

    /// The product is known but has no usable nutrition values yet.
    var hasNutrition: Bool {
        caloriesPer100Grams > 0
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "Unnamed product") : trimmed
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

/// Reads and writes the on-device product cache.
@MainActor
enum ProductCache {
    /// Online data older than this is refreshed when the phone is online.
    static let refreshInterval: TimeInterval = 60 * 60 * 24 * 30

    static func product(for barcode: String, in context: ModelContext) -> ScannedProduct? {
        var descriptor = FetchDescriptor<ScannedProduct>(
            predicate: #Predicate { $0.barcode == barcode },
            sortBy: [SortDescriptor(\.fetchedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    @discardableResult
    static func save(_ info: ProductInfo, in context: ModelContext) -> ScannedProduct {
        if let existing = product(for: info.barcode, in: context) {
            existing.update(from: info)
            return existing
        }
        let stored = ScannedProduct(product: info)
        context.insert(stored)
        return stored
    }

    static func needsRefresh(_ product: ScannedProduct) -> Bool {
        if product.source.isUserProvided { return false }
        if product.caloriesPer100Grams <= 0 { return true }
        return Date().timeIntervalSince(product.fetchedAt) > refreshInterval
    }
}
