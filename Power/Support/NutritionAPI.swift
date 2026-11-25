import Foundation

struct RemoteFood: Identifiable, Decodable, Hashable {
    let id: String
    let name: String
    let brand: String?
    let servingSize: Double?
    let servingUnit: String?
    let caloriesPer100Grams: Double
    let proteinPer100Grams: Double
    let carbohydratePer100Grams: Double
    let fatPer100Grams: Double

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

extension RemoteFood {
    var foodReference: FoodReference {
        let normalizedUnit = servingUnit?.lowercased() ?? ""
        let portionIsGrams = ["g", "gram", "grams", "grm"].contains(normalizedUnit)
        let estimatedPortion = portionIsGrams ? max(servingSize ?? 100, 1) : 100

        return FoodReference(
            id: "usda-\(id)",
            name: name,
            caloriesPer100Grams: caloriesPer100Grams,
            proteinPer100Grams: proteinPer100Grams,
            carbohydratePer100Grams: carbohydratePer100Grams,
            fatPer100Grams: fatPer100Grams,
            keywords: [name.lowercased()],
            typicalPortionGrams: estimatedPortion
        )
    }
}

enum NutritionAPIError: LocalizedError {
    case notConfigured
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            String(localized: "Online food search is not configured yet.")
        case .invalidResponse:
            String(localized: "The nutrition service returned an invalid response.")
        case .server(let message):
            message
        }
    }
}

enum NutritionAPI {
    private struct SearchResponse: Decodable {
        let foods: [RemoteFood]
    }

    private struct ErrorResponse: Decodable {
        let error: String
    }

    private struct ProductResponse: Decodable {
        let food: RemoteFood
    }

    private static func configuredBaseURL() throws -> URL {
        guard
            let value = Bundle.main.object(forInfoDictionaryKey: "NutritionAPIBaseURL") as? String,
            !value.isEmpty,
            let baseURL = URL(string: value)
        else {
            throw NutritionAPIError.notConfigured
        }
        return baseURL
    }

    /// Finds a branded USDA food by its barcode (GTIN/UPC). Returns nil when USDA does not
    /// list the product. Only the barcode is sent.
    static func product(barcode: String) async throws -> RemoteFood? {
        let baseURL = try configuredBaseURL()
        var components = URLComponents(
            url: baseURL.appending(path: "v1/foods/barcode"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "gtin", value: barcode)]
        guard let url = components?.url else {
            throw NutritionAPIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(ProductLookup.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await ProductLookup.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NutritionAPIError.invalidResponse
        }
        if http.statusCode == 404 {
            // An older deployment without the barcode route also answers 404 ("Not found");
            // only a product miss carries the product-not-found error text.
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data).error) ?? ""
            if message == "Product not found" { return nil }
            throw NutritionAPIError.notConfigured
        }
        guard 200..<300 ~= http.statusCode else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data).error)
                ?? String(localized: "Online food search is temporarily unavailable.")
            throw NutritionAPIError.server(message)
        }
        return try JSONDecoder().decode(ProductResponse.self, from: data).food
    }

    static func search(query: String) async throws -> [RemoteFood] {
        let baseURL = try configuredBaseURL()

        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 2 else { return [] }

        var components = URLComponents(
            url: baseURL.appending(path: "v1/foods/search"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "q", value: normalized),
            URLQueryItem(name: "limit", value: "20"),
        ]
        guard let url = components?.url else {
            throw NutritionAPIError.invalidResponse
        }

        var request = URLRequest(url: url)
        // Cloudflare caches successful searches. Always contact it here so a temporary
        // provider failure stored in URLCache cannot keep search offline on the device.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NutritionAPIError.invalidResponse
        }
        guard 200..<300 ~= http.statusCode else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data).error)
                ?? String(localized: "Online food search is temporarily unavailable.")
            throw NutritionAPIError.server(message)
        }

        return try JSONDecoder().decode(SearchResponse.self, from: data).foods
    }
}
