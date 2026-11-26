import Foundation
import UIKit
import Vision
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What Power could tell about a product from a photo of the front of its package.
struct PackageGuess: Hashable {
    var brand: String = ""
    var name: String = ""
    /// Package size in grams or milliliters, e.g. 100 for "100 g".
    var quantity: Double?
    var isLiquid = false
    /// Text to search the food databases with.
    var searchQuery: String = ""
    /// True when Apple's on-device language model did the identifying.
    var usedLanguageModel = false

    var isEmpty: Bool { searchQuery.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Brand and name for display, e.g. "Milka · Alpenmilch".
    var title: String {
        [brand, name].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Reads the front of a food package on the device and works out which product it is.
/// Text is recognized with Vision. On iPhones with Apple Intelligence (iOS 26+), Apple's
/// on-device language model turns the text into brand, product name and size; elsewhere a
/// heuristic uses the largest text. The photo and text never leave the phone.
enum PackageReader {
    struct TextLine: Hashable {
        let text: String
        /// Height of the text relative to the photo; bigger is more prominent.
        let size: Double
    }

    static func read(_ image: UIImage) async throws -> PackageGuess {
        await identify(try await textLines(in: image))
    }

    /// All text in the photo, with its size.
    static func textLines(in image: UIImage) async throws -> [TextLine] {
        guard let cgImage = image.cgImage else { return [] }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        return try await Task.detached(priority: .userInitiated) {
            try recognizeText(in: cgImage, orientation: orientation)
        }.value
    }

    /// True when the photo shows a labeled product (bottle, can, package) rather than a
    /// plated meal: there is large, printed text that isn't small print.
    static func looksLikePackage(_ lines: [TextLine]) -> Bool {
        let prominent = lines.filter { line in
            let lower = line.text.lowercased()
            return line.size >= 0.035
                && line.text.filter(\.isLetter).count >= 3
                && !smallPrint.contains { lower.contains($0) }
        }
        let letters = lines.reduce(0) { $0 + $1.text.filter(\.isLetter).count }
        return !prominent.isEmpty && letters >= 6
    }

    /// Identifies the product from recognized text: language model first, heuristic as
    /// fallback (and to fill in the package size, which the model sometimes skips).
    static func identify(_ lines: [TextLine]) async -> PackageGuess {
        var guess = heuristicGuess(lines)
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), let modelGuess = await modelGuess(lines) {
            let size = guess.quantity
            let liquid = guess.isLiquid
            guess = modelGuess
            if guess.quantity == nil {
                guess.quantity = size
                guess.isLiquid = liquid
            }
        }
        #endif
        return guess
    }

    // MARK: - Text recognition

    private static func recognizeText(in image: CGImage, orientation: CGImagePropertyOrientation) throws -> [TextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["de-DE", "en-US", "tr-TR", "fr-FR", "it-IT", "es-ES"]
        try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TextLine(text: text, size: Double(observation.boundingBox.height))
        }
    }

    // MARK: - Heuristic

    /// Words that mark a line as small print rather than the product's name.
    private static let smallPrint = [
        "nährwert", "nutrition", "zutaten", "ingredients", "energie", "energy", "kcal", "kj",
        "fett", "fat", "protein", "eiweiß", "kohlenhydrat", "carbohydrate", "zucker", "sugar",
        "salz", "salt", "mindestens haltbar", "best before", "store", "lagern", "www.", "http",
        "hergestellt", "made in", "e-mail", "kontakt", "%",
    ]

    /// Words that describe a variety rather than name a brand.
    private static let varietyWords: Set<String> = [
        "zero", "light", "lite", "bio", "organic", "neu", "new", "classic", "original", "diet",
        "sugar free", "zuckerfrei", "ohne zucker", "vegan", "protein", "max", "plus",
    ]

    static func heuristicGuess(_ lines: [TextLine]) -> PackageGuess {
        var guess = PackageGuess()
        if let (amount, liquid) = packageSize(in: lines.map(\.text)) {
            guess.quantity = amount
            guess.isLiquid = liquid
        }

        let candidates = lines.filter { line in
            let lower = line.text.lowercased()
            let letters = line.text.filter(\.isLetter).count
            return letters >= 3
                && line.text.count <= 40
                && !smallPrint.contains { lower.contains($0) }
                && packageSize(in: [line.text]).map { _ in letters > 6 } ?? true
        }
        // Most prominent text first; skip repeats of the same words.
        var seen = Set<String>()
        let prominent = candidates.sorted { $0.size > $1.size }.filter { seen.insert($0.text.lowercased()).inserted }
        guard !prominent.isEmpty else { return guess }

        // Brand logos are usually the largest, shortest text; the name follows. Variety
        // words ("zero", "light") are often printed even bigger, so they don't count.
        var ordered = Array(prominent)
        if let brandIndex = ordered.firstIndex(where: { !varietyWords.contains($0.text.lowercased()) }), brandIndex > 0 {
            ordered.insert(ordered.remove(at: brandIndex), at: 0)
        }
        let first = ordered[0]
        let rest = ordered.dropFirst().prefix(2).map(\.text)
        if first.text.split(separator: " ").count <= 2, !rest.isEmpty {
            guess.brand = first.text
            guess.name = uniqueWords(rest, excluding: first.text)
        } else {
            guess.name = first.text
        }
        guess.searchQuery = ([guess.brand, guess.name].filter { !$0.isEmpty }).joined(separator: " ")
        return guess
    }

    /// Joins lines without repeating words ("Alpenmilch" + "Zarte Alpenmilch Schokolade"
    /// gives "Alpenmilch Zarte Schokolade"), leaving out words already in `excluding`.
    private static func uniqueWords(_ lines: [String], excluding: String) -> String {
        var seen = Set(excluding.lowercased().split(separator: " ").map(String.init))
        return lines.flatMap { $0.split(separator: " ").map(String.init) }
            .filter { seen.insert($0.lowercased()).inserted }
            .joined(separator: " ")
    }

    /// Finds a package size like "100 g", "1,5 l" or "330ml"; returns grams/milliliters.
    static func packageSize(in texts: [String]) -> (Double, isLiquid: Bool)? {
        let pattern = #"(\d+(?:[.,]\d+)?)\s?(kg|g|gr|ml|cl|l)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        for text in texts {
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard let numberRange = Range(match.range(at: 1), in: text),
                      let unitRange = Range(match.range(at: 2), in: text),
                      let number = Double(text[numberRange].replacingOccurrences(of: ",", with: "."))
                else { continue }
                let unit = text[unitRange].lowercased()
                let (amount, liquid): (Double, Bool) = switch unit {
                case "kg": (number * 1000, false)
                case "l": (number * 1000, true)
                case "cl": (number * 10, true)
                case "ml": (number, true)
                default: (number, false)
                }
                if (5...5000).contains(amount) { return (amount, liquid) }
            }
        }
        return nil
    }

    // MARK: - Apple Intelligence

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    @Generable
    struct Identification {
        @Guide(description: "The brand or manufacturer printed on the package, e.g. Milka or Alpro. Empty if no brand is visible.")
        var brand: String
        @Guide(description: "The product name and variety, without the brand, e.g. Alpenmilch Schokolade or Hafer Drink Barista.")
        var productName: String
        @Guide(description: "Short text to search a food database for this exact product: brand plus product name.")
        var searchQuery: String
    }

    @available(iOS 26.0, *)
    private static func modelGuess(_ lines: [TextLine]) async -> PackageGuess? {
        guard SystemLanguageModel.default.isAvailable, !lines.isEmpty else { return nil }
        // Largest text first, with a size hint, capped so the prompt stays small.
        let maxSize = lines.map(\.size).max() ?? 1
        let listing = lines.sorted { $0.size > $1.size }.prefix(40).map { line in
            let relative = Int((line.size / maxSize * 10).rounded())
            return "[size \(relative)] \(line.text)"
        }.joined(separator: "\n")

        let session = LanguageModelSession(instructions: """
            You identify packaged food and drink products from text read off the front of \
            the package. Bigger size numbers mean more prominent text. Use only words that \
            appear in the text; never invent a product. Ignore slogans, claims like "bio" or \
            "neu", nutrition facts and addresses.
            """)
        do {
            let response = try await session.respond(
                to: "Text on the package:\n\(listing)\n\nWhich product is this?",
                generating: Identification.self
            )
            let result = response.content
            var guess = PackageGuess(brand: result.brand.trimmingCharacters(in: .whitespaces),
                                     name: result.productName.trimmingCharacters(in: .whitespaces),
                                     searchQuery: result.searchQuery.trimmingCharacters(in: .whitespaces),
                                     usedLanguageModel: true)
            if guess.searchQuery.isEmpty {
                guess.searchQuery = [guess.brand, guess.name].filter { !$0.isEmpty }.joined(separator: " ")
            }
            return guess.isEmpty ? nil : guess
        } catch {
            return nil
        }
    }
    #endif
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
