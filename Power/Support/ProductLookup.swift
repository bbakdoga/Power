import Foundation

/// Looks up a product by barcode in Open Food Facts, then USDA FoodData Central.
///
/// Only the barcode is sent. Requests use an ephemeral session (no cookies, no cache on
/// disk) and a generic User-Agent, so nothing identifies the user.
enum ProductLookup {
    enum LookupError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            String(localized: "Product lookup is unavailable. Check your internet connection and try again.")
        }
    }

    static let userAgent = "Power/1.0 (iOS food logging)"

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.httpAdditionalHeaders = [
            "User-Agent": userAgent,
            "Accept": "application/json",
        ]
        return URLSession(configuration: configuration)
    }()

    /// Returns the product, possibly without nutrition values (known name only), or nil
    /// when neither database knows the barcode. Throws when no database could be reached.
    static func lookup(_ barcode: ProductBarcode) async throws -> ProductInfo? {
        var reachedAnyDatabase = false
        var partial: ProductInfo?

        do {
            let product = try await OpenFoodFacts.product(code: barcode.code)
            reachedAnyDatabase = true
            if let product, product.hasNutrition { return product }
            partial = product
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Try the next database.
        }

        do {
            if let food = try await NutritionAPI.product(barcode: barcode.code) {
                var product = food.productInfo(barcode: barcode.code)
                if product.name.isEmpty, let partial { product.name = partial.name }
                return product
            }
            reachedAnyDatabase = true
        } catch is CancellationError {
            throw CancellationError()
        } catch NutritionAPIError.notConfigured {
            // The USDA proxy is optional.
        } catch {
            // Fall through: Open Food Facts may still have answered.
        }

        guard reachedAnyDatabase else { throw LookupError.unavailable }
        return partial
    }
}

/// Open Food Facts product API (https://openfoodfacts.github.io/openfoodfacts-server/api/).
/// Data is available under the Open Database License, so the app shows
/// "Data: Open Food Facts" wherever it displays a product from it.
enum OpenFoodFacts {
    static func productPageURL(code: String) -> URL? {
        URL(string: "https://world.openfoodfacts.org/product/\(code)")
    }

    private static let fields = [
        "code", "product_name", "product_name_en", "product_name_de", "product_name_tr",
        "generic_name", "brands", "nutriments", "serving_quantity", "serving_quantity_unit",
        "product_quantity_unit", "quantity",
    ]

    static func product(code: String) async throws -> ProductInfo? {
        guard code.allSatisfy(\.isNumber),
              var components = URLComponents(string: "https://world.openfoodfacts.org/api/v2/product/\(code).json")
        else { return nil }
        components.queryItems = [URLQueryItem(name: "fields", value: fields.joined(separator: ","))]
        guard let url = components.url else { return nil }

        let (data, response) = try await ProductLookup.session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw NutritionAPIError.invalidResponse
        }
        if http.statusCode == 404 { return nil }
        guard 200..<300 ~= http.statusCode else {
            throw NutritionAPIError.server("Open Food Facts \(http.statusCode)")
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NutritionAPIError.invalidResponse
        }
        if let status = number(root["status"]), status == 0 { return nil }
        guard let product = root["product"] as? [String: Any] else { return nil }
        return parse(product, code: code)
    }

    static func parse(_ product: [String: Any], code: String) -> ProductInfo {
        let nutriments = product["nutriments"] as? [String: Any] ?? [:]

        var calories = number(nutriments["energy-kcal_100g"])
        if calories == nil, let kilojoules = number(nutriments["energy-kj_100g"]) ?? number(nutriments["energy_100g"]) {
            calories = kilojoules / 4.184
        }

        let quantityUnit = (product["product_quantity_unit"] as? String
            ?? product["serving_quantity_unit"] as? String ?? "").lowercased()
        let quantityText = (product["quantity"] as? String ?? "").lowercased()
        let isLiquid = quantityUnit == "ml"
            || quantityText.range(of: #"\d\s*(ml|cl|l)\b"#, options: .regularExpression) != nil

        let serving = number(product["serving_quantity"]).flatMap { $0 > 0 && $0 <= 2_000 ? $0 : nil }

        return ProductInfo(
            barcode: code,
            name: localizedName(product),
            brand: (product["brands"] as? String ?? "")
                .split(separator: ",").first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? "",
            caloriesPer100Grams: clamp(calories, max: 950),
            proteinPer100Grams: clamp(number(nutriments["proteins_100g"]), max: 100),
            carbohydratePer100Grams: clamp(number(nutriments["carbohydrates_100g"]), max: 100),
            fatPer100Grams: clamp(number(nutriments["fat_100g"]), max: 100),
            servingGrams: serving,
            isLiquid: isLiquid,
            source: .openFoodFacts
        )
    }

    private static func localizedName(_ product: [String: Any]) -> String {
        var keys: [String] = []
        if let preferred = Locale.preferredLanguages.first,
           let language = Locale(identifier: preferred).language.languageCode?.identifier {
            keys.append("product_name_\(language)")
        }
        keys += ["product_name", "product_name_en", "product_name_de", "product_name_tr", "generic_name"]
        for key in keys {
            if let value = (product[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return ""
    }

    /// Open Food Facts stores numbers as JSON numbers or as strings.
    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string.replacingOccurrences(of: ",", with: "."))
        default:
            return nil
        }
    }

    private static func clamp(_ value: Double?, max upperBound: Double) -> Double {
        guard let value, value.isFinite, value >= 0, value <= upperBound else { return 0 }
        return value
    }
}

extension RemoteFood {
    func productInfo(barcode: String) -> ProductInfo {
        let unit = servingUnit?.lowercased() ?? ""
        let servingInGrams = ["g", "gram", "grams", "grm", "ml", "mlt"].contains(unit)
        return ProductInfo(
            barcode: barcode,
            name: name,
            brand: brand ?? "",
            caloriesPer100Grams: caloriesPer100Grams,
            proteinPer100Grams: proteinPer100Grams,
            carbohydratePer100Grams: carbohydratePer100Grams,
            fatPer100Grams: fatPer100Grams,
            servingGrams: servingInGrams ? servingSize.flatMap { $0 > 0 ? $0 : nil } : nil,
            isLiquid: unit == "ml" || unit == "mlt",
            source: .usda
        )
    }
}
