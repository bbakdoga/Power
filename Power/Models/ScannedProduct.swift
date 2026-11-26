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
    /// Grams (or millilitres) in one package, e.g. 200 for a pudding cup or 125 for one
    /// cup of a "4 x 125 g" pack; 0 when unknown.
    var packageGrams: Double = 0
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
        packageGrams = product.packageGrams ?? 0
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
            packageGrams: packageGrams > 0 ? packageGrams : nil,
            isLiquid: isLiquid,
            source: source,
            // Only products with values (or values the user entered) are stored.
            nutritionStated: true
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
    /// Grams (or millilitres) in one package or one unit of a multipack.
    var packageGrams: Double?
    var isLiquid: Bool = false
    var source: ProductDataSource
    /// The source states nutrition values, even if they're all zero (Coke Zero, water).
    var nutritionStated = false

    /// False when the product is known but has no usable nutrition values yet.
    var hasNutrition: Bool {
        caloriesPer100Grams > 0 || nutritionStated
    }

    /// Amount to suggest when logging: one serving, else one package when it's a portion
    /// someone eats at once (a pudding cup, a can), else 100 g.
    var defaultAmount: Double {
        if let servingGrams { return servingGrams }
        if let packageGrams, packageGrams <= 750 { return packageGrams }
        return 100
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
        // Saved before package sizes were stored: look again so the amount can default to
        // one package.
        if product.servingGrams <= 0 && product.packageGrams <= 0 { return true }
        return Date().timeIntervalSince(product.fetchedAt) > refreshInterval
    }
}
