import Foundation
import UIKit
import Vision

/// Values read from a photo of a nutrition table. Everything is per 100 g (or 100 ml).
struct NutritionLabelValues: Equatable {
    var calories: Double?
    var protein: Double?
    var carbohydrates: Double?
    var fat: Double?
    var servingGrams: Double?
    /// The label only listed values per serving and no serving weight was found,
    /// so the numbers could not be converted to 100 g.
    var isPerServingOnly = false

    var foundAnything: Bool {
        calories != nil || protein != nil || carbohydrates != nil || fat != nil
    }

    /// Calories from macros (4/4/9 kcal per gram) differ a lot from the stated calories,
    /// which usually means a value was misread.
    var looksInconsistent: Bool {
        guard let calories, calories > 0,
              let protein, let carbohydrates, let fat
        else { return false }
        let computed = protein * 4 + carbohydrates * 4 + fat * 9
        guard computed > 0 else { return false }
        return abs(calories - computed) / max(calories, computed) > 0.3
    }
}

/// Reads a nutrition table on the device with Vision text recognition. No image leaves
/// the phone. Handles the common European layout (per 100 g first column, energy in kJ
/// and kcal) and US Nutrition Facts (per serving with the serving weight in grams), with
/// labels in English, German, Turkish, French, Italian and Spanish.
enum NutritionLabelReader {
    struct TextLine {
        let text: String
        /// Vision's normalized coordinates (origin bottom left).
        let box: CGRect
    }

    static func read(_ image: UIImage) async throws -> NutritionLabelValues {
        guard let cgImage = image.cgImage else { return NutritionLabelValues() }
        let orientation = visionOrientation(image.imageOrientation)

        let lines = try await Task.detached(priority: .userInitiated) {
            try recognizeText(in: cgImage, orientation: orientation)
        }.value
        return parse(lines)
    }

    private static func recognizeText(in image: CGImage, orientation: CGImagePropertyOrientation) throws -> [TextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Language correction tends to "fix" numbers and units, so keep raw text.
        request.usesLanguageCorrection = false

        let wanted = ["de-DE", "en-US", "tr-TR", "fr-FR", "it-IT", "es-ES"]
        if let supported = try? request.supportedRecognitionLanguages() {
            let preferred = Locale.preferredLanguages.compactMap { language in
                supported.first { $0.hasPrefix(String(language.prefix(2))) }
            }
            var languages: [String] = []
            for language in preferred + wanted where supported.contains(language) && !languages.contains(language) {
                languages.append(language)
            }
            if !languages.isEmpty { request.recognitionLanguages = languages }
        }

        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)
        try handler.perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return TextLine(text: candidate.string, box: observation.boundingBox)
        }
    }

    // MARK: - Parsing

    private enum Nutrient: CaseIterable {
        case energy, fat, carbohydrates, protein

        var keywords: [String] {
            switch self {
            case .energy:
                ["energy", "energie", "enerji", "energia", "energía", "brennwert", "calories", "calorie", "kalori", "valeur energetique"]
            case .fat:
                ["fat", "fett", "yag", "matieres grasses", "lipides", "grassi", "grasas", "lipidi"]
            case .carbohydrates:
                ["carbohydrate", "kohlenhydrat", "karbonhidrat", "glucides", "carboidrati", "hidratos de carbono", "carbohidratos"]
            case .protein:
                ["protein", "eiweiss", "eiweiß", "proteines", "proteine", "proteinas"]
            }
        }

        /// Rows that mention the keyword but describe a sub-value.
        var exclusions: [String] {
            switch self {
            case .energy:
                ["from fat"]
            case .fat:
                ["saturated", "gesattigt", "fettsaure", "doymus", "trans", "satures", "saturi", "saturadas",
                 "mono", "poly", "davon", "of which", "dont", "di cui", "de las cuales", "calories from"]
            case .carbohydrates:
                ["sugar", "zucker", "seker", "sucres", "zuccheri", "azucares", "davon", "of which", "dont", "di cui"]
            case .protein:
                []
            }
        }
    }

    private struct Row {
        var text: String
        let midY: CGFloat
        let height: CGFloat
    }

    static func parse(_ lines: [TextLine]) -> NutritionLabelValues {
        let rows = groupIntoRows(lines)
        let normalizedRows = rows.map { normalize($0.text) }
        let fullText = normalizedRows.joined(separator: "\n")

        var values = NutritionLabelValues()

        // Energy: prefer kcal on the energy row or the two rows below it, else convert kJ,
        // else the first plain number (US "Calories 250").
        if let index = rowIndex(for: .energy, in: normalizedRows) {
            let window = normalizedRows[index..<min(index + 3, normalizedRows.count)]
            let numbers = window.flatMap { numbersWithUnits(in: $0) }
            if let kcal = numbers.first(where: { $0.unit == "kcal" }) {
                values.calories = kcal.value
            } else if let kilojoules = numbers.first(where: { $0.unit == "kj" }) {
                values.calories = kilojoules.value / 4.184
            } else {
                // "Enerji (kJ/kcal) 1966/470" puts the units in the label, or US "Calories 230".
                let row = normalizedRows[index]
                let plain = numbersWithUnits(in: row).filter { $0.unit.isEmpty && !$0.isPercent }.map(\.value)
                let kilojoulePosition = row.range(of: "kj")?.lowerBound
                let kilocaloriePosition = row.range(of: "kcal")?.lowerBound
                if plain.count >= 2, let kilojoulePosition, let kilocaloriePosition {
                    values.calories = kilojoulePosition < kilocaloriePosition ? plain[1] : plain[0]
                } else if let first = plain.first {
                    values.calories = kilojoulePosition != nil && kilocaloriePosition == nil ? first / 4.184 : first
                }
            }
        } else if let kcal = numbersWithUnits(in: fullText).first(where: { $0.unit == "kcal" }) {
            values.calories = kcal.value
        }

        values.fat = gramValue(for: .fat, in: normalizedRows)
        values.carbohydrates = gramValue(for: .carbohydrates, in: normalizedRows)
        values.protein = gramValue(for: .protein, in: normalizedRows)
        values.servingGrams = servingGrams(in: normalizedRows)

        let isPer100 = fullText.range(
            of: #"(^|[^\d.,])100\s*(g|gr|ml)\b"#,
            options: .regularExpression
        ) != nil

        if !isPer100, values.foundAnything {
            if let serving = values.servingGrams, serving > 0 {
                let factor = 100 / serving
                values.calories = values.calories.map { $0 * factor }
                values.fat = values.fat.map { $0 * factor }
                values.carbohydrates = values.carbohydrates.map { $0 * factor }
                values.protein = values.protein.map { $0 * factor }
            } else {
                values.isPerServingOnly = true
            }
        }

        values.calories = plausible(values.calories, max: 950)
        values.fat = plausible(values.fat, max: 100)
        values.carbohydrates = plausible(values.carbohydrates, max: 100)
        values.protein = plausible(values.protein, max: 100)
        return values
    }

    private static func groupIntoRows(_ lines: [TextLine]) -> [Row] {
        let sorted = lines.sorted {
            $0.box.midY == $1.box.midY ? $0.box.minX < $1.box.minX : $0.box.midY > $1.box.midY
        }
        var rows: [(midY: CGFloat, height: CGFloat, items: [TextLine])] = []
        for line in sorted {
            if let last = rows.indices.last,
               abs(rows[last].midY - line.box.midY) < max(rows[last].height, line.box.height) * 0.5 {
                rows[last].items.append(line)
            } else {
                rows.append((line.box.midY, line.box.height, [line]))
            }
        }
        return rows.map { row in
            let text = row.items.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: "  ")
            return Row(text: text, midY: row.midY, height: row.height)
        }
    }

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "ß", with: "ss")
            .folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "ı", with: "i")
    }

    private static func rowIndex(for nutrient: Nutrient, in rows: [String]) -> Int? {
        let keywords = nutrient.keywords.map(normalize)
        let exclusions = nutrient.exclusions.map(normalize)
        return rows.firstIndex { row in
            keywords.contains { containsWord(row, $0) } && !exclusions.contains { row.contains($0) }
        }
    }

    /// Keyword match at a word start, so "fat" does not match "fatty" in the middle of a word
    /// but "kohlenhydrat" still matches "kohlenhydrate".
    private static func containsWord(_ text: String, _ word: String) -> Bool {
        let pattern = "(^|[^a-z])" + NSRegularExpression.escapedPattern(for: word)
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func gramValue(for nutrient: Nutrient, in rows: [String]) -> Double? {
        guard let index = rowIndex(for: nutrient, in: rows) else { return nil }
        let candidates = numbersWithUnits(in: textAfterKeyword(nutrient, in: rows[index]))
            .filter { !$0.isPercent && ($0.unit == "g" || $0.unit.isEmpty) }
        if let value = candidates.first?.value { return value }

        // The value can sit on the next row when the label wraps.
        if index + 1 < rows.count, rowIndex(for: nutrient, in: [rows[index + 1]]) == nil {
            let next = rows[index + 1]
            let startsWithNumber = next.range(of: #"^\s*<?\s*\d"#, options: .regularExpression) != nil
            if startsWithNumber {
                return numbersWithUnits(in: next).first { !$0.isPercent && ($0.unit == "g" || $0.unit.isEmpty) }?.value
            }
        }
        return nil
    }

    private static func textAfterKeyword(_ nutrient: Nutrient, in row: String) -> String {
        for keyword in nutrient.keywords.map(normalize) {
            if let range = row.range(of: keyword) {
                return String(row[range.upperBound...])
            }
        }
        return row
    }

    private static func servingGrams(in rows: [String]) -> Double? {
        let servingWords = ["serving size", "serving", "portion", "porsiyon", "per serving"]
        for row in rows where servingWords.contains(where: { row.contains($0) }) {
            // "Serving size 1 cup (228g)" or "Portion 30 g"
            if let grams = numbersWithUnits(in: row).first(where: { ($0.unit == "g" || $0.unit == "ml") && $0.value != 100 }) {
                return grams.value
            }
        }
        return nil
    }

    struct NumberToken: Equatable {
        let value: Double
        let unit: String
        let isPercent: Bool
    }

    /// Numbers with an optional unit. Accepts "3,5 g", "<0.5g", "1046 kJ", "250kcal", "13%".
    static func numbersWithUnits(in text: String) -> [NumberToken] {
        let pattern = #"(\d+(?:[.,]\d+)?)\s*(kcal|kj|mcg|mg|µg|gr|g|ml|%)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let numberRange = Range(match.range(at: 1), in: text) else { return nil }
            // Skip digits glued to letters, such as "B12" or "E330".
            if numberRange.lowerBound > text.startIndex {
                let previous = text[text.index(before: numberRange.lowerBound)]
                if previous.isLetter { return nil }
            }
            let raw = text[numberRange].replacingOccurrences(of: ",", with: ".")
            guard let value = Double(raw) else { return nil }
            var unit = ""
            if let unitRange = Range(match.range(at: 2), in: text) {
                unit = String(text[unitRange])
            }
            if unit == "gr" { unit = "g" }
            // A unit only counts when it is not the start of a longer word ("g" in "gesamt").
            if !unit.isEmpty, unit != "%" {
                let end = Range(match.range, in: text)!.upperBound
                if end < text.endIndex, text[end].isLetter { unit = "" }
            }
            return NumberToken(value: value, unit: unit == "%" ? "" : unit, isPercent: unit == "%")
        }
    }

    private static func plausible(_ value: Double?, max upperBound: Double) -> Double? {
        guard let value, value.isFinite, value >= 0, value <= upperBound else { return nil }
        return value
    }
}

private func visionOrientation(_ orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
    switch orientation {
    case .up: .up
    case .upMirrored: .upMirrored
    case .down: .down
    case .downMirrored: .downMirrored
    case .left: .left
    case .leftMirrored: .leftMirrored
    case .right: .right
    case .rightMirrored: .rightMirrored
    @unknown default: .up
    }
}
