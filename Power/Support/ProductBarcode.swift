import Foundation

/// A product number (GTIN) read from a retail barcode or a GS1 Digital Link QR code.
///
/// Accepts EAN-13, EAN-8, UPC-A, UPC-E, GTIN-14, GS1 element strings such as
/// `(01)04012345678901` (DataMatrix, DataBar) and Digital Link URLs such as
/// `https://id.example.com/01/04012345678901/10/ABC`. The check digit is always verified,
/// so a misread code is rejected instead of looking up the wrong product.
struct ProductBarcode: Hashable, Identifiable {
    /// Normalized code used for lookups and the on-device cache: 8 digits for EAN-8,
    /// otherwise 13 digits (UPC-A gets a leading zero) or 14 digits for case-level codes.
    let code: String

    var id: String { code }

    /// - Parameter isUPCE: The scanner reported the UPC-E symbology, so an 8 digit payload
    ///   is expanded to UPC-A instead of being read as EAN-8.
    init?(payload: String, isUPCE: Bool = false) {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let gtin = Self.gtinFromDigitalLink(trimmed) ?? Self.gtinFromElementString(trimmed) {
            guard let code = Self.normalized(gtin) else { return nil }
            self.code = code
            return
        }

        let digits = trimmed.filter { !$0.isWhitespace && $0 != "-" }
        guard digits.allSatisfy(\.isASCIIDigit) else { return nil }

        if isUPCE || digits.count == 6 {
            guard let upcA = Self.expandUPCE(digits), let code = Self.normalized(upcA) else { return nil }
            self.code = code
            return
        }

        if let code = Self.normalized(digits) {
            self.code = code
        } else if digits.count == 8, let upcA = Self.expandUPCE(digits), let code = Self.normalized(upcA) {
            // An 8 digit code that fails the EAN-8 check may still be a UPC-E code.
            self.code = code
        } else {
            return nil
        }
    }

    // MARK: - Normalization

    /// Validates the check digit and brings the code to its shortest standard length.
    static func normalized(_ digits: String) -> String? {
        guard [8, 12, 13, 14].contains(digits.count),
              digits.allSatisfy(\.isASCIIDigit),
              hasValidCheckDigit(digits)
        else { return nil }

        var code = digits
        // GTIN-14 and GTIN-13 padded with leading zeros carry the same product number.
        while code.count > 13, code.hasPrefix("0") { code.removeFirst() }
        if code.count == 12 { code = "0" + code }
        if code.count == 13, code.hasPrefix("00000") {
            // A GTIN-8 written in a 13/14 digit field.
            let short = String(code.suffix(8))
            if hasValidCheckDigit(short) { return short }
        }
        return code
    }

    /// GS1 modulo 10 check: weights 3 and 1 alternate from the digit left of the check digit.
    static func hasValidCheckDigit(_ digits: String) -> Bool {
        let values = digits.compactMap(\.wholeNumberValue)
        guard values.count == digits.count, let check = values.last else { return false }
        var sum = 0
        for (offset, value) in values.dropLast().reversed().enumerated() {
            sum += value * (offset.isMultiple(of: 2) ? 3 : 1)
        }
        return (10 - sum % 10) % 10 == check
    }

    /// Expands a UPC-E code (6 digits, or 8 with number system and check digit) to UPC-A.
    static func expandUPCE(_ digits: String) -> String? {
        let values = digits.compactMap(\.wholeNumberValue)
        let numberSystem: Int
        let body: [Int]
        let check: Int?
        switch values.count {
        case 6:
            numberSystem = 0
            body = values
            check = nil
        case 7:
            numberSystem = values[0]
            body = Array(values[1...6])
            check = nil
        case 8:
            numberSystem = values[0]
            body = Array(values[1...6])
            check = values[7]
        default:
            return nil
        }
        guard numberSystem == 0 || numberSystem == 1 else { return nil }

        let manufacturer: [Int]
        let product: [Int]
        switch body[5] {
        case 0, 1, 2:
            manufacturer = [body[0], body[1], body[5], 0, 0]
            product = [0, 0, body[2], body[3], body[4]]
        case 3:
            manufacturer = [body[0], body[1], body[2], 0, 0]
            product = [0, 0, 0, body[3], body[4]]
        case 4:
            manufacturer = [body[0], body[1], body[2], body[3], 0]
            product = [0, 0, 0, 0, body[4]]
        default:
            manufacturer = [body[0], body[1], body[2], body[3], body[4]]
            product = [0, 0, 0, 0, body[5]]
        }

        let withoutCheck = ([numberSystem] + manufacturer + product).map(String.init).joined()
        if let check {
            let upcA = withoutCheck + String(check)
            return hasValidCheckDigit(upcA) ? upcA : nil
        }
        for candidate in 0...9 where hasValidCheckDigit(withoutCheck + String(candidate)) {
            return withoutCheck + String(candidate)
        }
        return nil
    }

    // MARK: - GS1 formats

    /// Reads the GTIN from a GS1 Digital Link URI: the path segment after `01` or `gtin`.
    static func gtinFromDigitalLink(_ value: String) -> String? {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else { return nil }

        let segments = url.path.split(separator: "/").map(String.init)
        for (index, segment) in segments.enumerated() where segment == "01" || segment.lowercased() == "gtin" {
            guard index + 1 < segments.count else { continue }
            let candidate = segments[index + 1]
            if (8...14).contains(candidate.count), candidate.allSatisfy(\.isASCIIDigit) {
                return candidate
            }
        }
        return nil
    }

    /// Reads application identifier 01 from a GS1 element string, with or without
    /// parentheses and with an optional symbology identifier such as `]d2` or `]C1`.
    static func gtinFromElementString(_ value: String) -> String? {
        var text = value
        if text.hasPrefix("]"), text.count > 3 { text = String(text.dropFirst(3)) }
        text = text.replacingOccurrences(of: "\u{1D}", with: "")

        if text.hasPrefix("(01)") {
            let digits = text.dropFirst(4).prefix(14)
            return digits.count == 14 && digits.allSatisfy(\.isASCIIDigit) ? String(digits) : nil
        }
        // Without parentheses only accept codes that clearly carry more than a bare GTIN,
        // so a plain 14 digit number starting with 01 is still read as a GTIN-14.
        if text.hasPrefix("01"), text.count >= 16 {
            let digits = text.dropFirst(2).prefix(14)
            return digits.allSatisfy(\.isASCIIDigit) ? String(digits) : nil
        }
        return nil
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
