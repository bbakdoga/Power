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
    /// Finds products by name (e.g. text read from the package front): Open Food Facts
    /// first, USDA branded foods when it has nothing. Only the search text is sent.
    /// Products with nutrition values come first. Throws when no database could be reached.
    static func search(name query: String) async throws -> [ProductInfo] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        var reachedAnyDatabase = false
        var results: [ProductInfo] = []

        do {
            results = try await OpenFoodFacts.search(trimmed)
            reachedAnyDatabase = true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Try USDA.
        }

        if results.isEmpty {
            do {
                results = try await NutritionAPI.search(query: trimmed).prefix(10).map { $0.productInfo(barcode: "") }
                reachedAnyDatabase = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The USDA proxy is optional.
            }
        }

        guard reachedAnyDatabase else { throw LookupError.unavailable }
        return results.filter { !$0.name.isEmpty }.sorted { $0.hasNutrition && !$1.hasNutrition }
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
        "product_quantity_unit", "product_quantity", "quantity",
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

    /// Finds products by name with Open Food Facts' search service
    /// (https://search.openfoodfacts.org), then loads each top match through the product
    /// API, because search results usually leave out the nutrition values. The search
    /// needs every word to match, so words are dropped from the end until something does.
    static func search(_ terms: String, limit: Int = 8) async throws -> [ProductInfo] {
        var words = terms.split(whereSeparator: \.isWhitespace).map(String.init)
        var hits: [ProductInfo] = []
        while !words.isEmpty {
            hits = try await searchHits(words.joined(separator: " "), limit: limit)
            if !hits.isEmpty || words.count == 1 { break }
            words.removeLast()
        }

        // Full details in parallel, keeping the search order; fall back to the hit itself.
        let detailed = await withTaskGroup(of: (Int, ProductInfo?).self) { group in
            for (index, hit) in hits.enumerated() {
                group.addTask { (index, try? await product(code: hit.barcode)) }
            }
            var byIndex: [Int: ProductInfo] = [:]
            for await (index, info) in group {
                if let info { byIndex[index] = info }
            }
            return byIndex
        }
        return hits.enumerated().map { index, hit in
            guard var info = detailed[index] else { return hit }
            if info.name.isEmpty { info.name = hit.name }
            if info.brand.isEmpty { info.brand = hit.brand }
            return info
        }
    }

    /// One search request: barcode, name and brand for each hit (no nutrition).
    private static func searchHits(_ query: String, limit: Int) async throws -> [ProductInfo] {
        guard var components = URLComponents(string: "https://search.openfoodfacts.org/search") else { return [] }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "page_size", value: String(limit)),
            URLQueryItem(name: "fields", value: "code,product_name,product_name_en,product_name_de,product_name_tr,generic_name,brands"),
        ]
        guard let url = components.url else { return [] }

        let (data, response) = try await ProductLookup.session.data(from: url)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw NutritionAPIError.server("Open Food Facts search")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hits = root["hits"] as? [[String: Any]] else {
            throw NutritionAPIError.invalidResponse
        }
        return hits.compactMap { hit in
            guard let code = hit["code"] as? String, !code.isEmpty, code.allSatisfy(\.isNumber) else { return nil }
            // Brands come as tags like "xx:milka" in search results.
            let brands = (hit["brands"] as? [String] ?? (hit["brands"] as? String).map { [$0] } ?? [])
                .map { tag in tag.split(separator: ":", maxSplits: 1).last.map(String.init) ?? tag }
            var info = ProductInfo(barcode: code, name: localizedName(hit), source: .openFoodFacts)
            info.brand = brands.first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? ""
            return info
        }
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
        let package = unitSize(fromQuantity: product["quantity"] as? String ?? "")
            ?? number(product["product_quantity"]).flatMap { $0 > 0 && $0 <= 5_000 ? $0 : nil }

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
            packageGrams: package,
            isLiquid: isLiquid,
            source: .openFoodFacts,
            nutritionStated: calories != nil
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

    /// Size of one unit from a quantity like "4 x 125 g", "6 × 0,33 l" or "200 g", in grams
    /// or milliliters. Single sizes are left to `product_quantity`, which is cleaner.
    static func unitSize(fromQuantity text: String) -> Double? {
        let pattern = #"(\d+)\s*[x×*]\s*(\d+(?:[.,]\d+)?)\s*(kg|g|ml|cl|l)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let sizeRange = Range(match.range(at: 2), in: text),
              let unitRange = Range(match.range(at: 3), in: text),
              let size = Double(text[sizeRange].replacingOccurrences(of: ",", with: "."))
        else { return nil }
        let factor: Double = switch text[unitRange].lowercased() {
        case "kg", "l": 1000
        case "cl": 10
        default: 1
        }
        let grams = size * factor
        return grams > 0 && grams <= 5_000 ? grams : nil
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
            source: .usda,
            nutritionStated: true
        )
    }
}
