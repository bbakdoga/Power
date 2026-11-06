import Foundation

enum WeightUnit: String, CaseIterable, Identifiable {
    case kg, lb

    static let storageKey = "weightUnit"
    private static let poundsPerKilogram = 2.2046226218

    var id: String { rawValue }

    func fromKg(_ kilograms: Double) -> Double {
        self == .kg ? kilograms : kilograms * Self.poundsPerKilogram
    }

    func toKg(_ value: Double) -> Double {
        self == .kg ? value : value / Self.poundsPerKilogram
    }

    /// A kilogram value shown in this unit, e.g. "102.5".
    func format(kg: Double) -> String {
        fromKg(kg).formatted(.number.precision(.fractionLength(0...1)))
    }

    /// Plates per side for the plate calculator, heaviest first.
    var standardPlates: [Double] {
        switch self {
        case .kg: return [25, 20, 15, 10, 5, 2.5, 1.25]
        case .lb: return [45, 35, 25, 10, 5, 2.5]
        }
    }

    var barOptions: [Double] {
        switch self {
        case .kg: return [20, 15, 10]
        case .lb: return [45, 35, 15]
        }
    }
}

enum OneRepMax {
    /// Epley formula: weight × (1 + reps / 30).
    static func epley(weight: Double, reps: Int) -> Double {
        guard weight > 0, reps > 0 else { return 0 }
        if reps == 1 { return weight }
        return weight * (1 + Double(reps) / 30)
    }
}

enum PlateMath {
    struct Result {
        var perSide: [Double]
        /// Total weight (both sides) that standard plates can't make up.
        var remainder: Double
    }

    static func plates(target: Double, bar: Double, available: [Double]) -> Result {
        var perSide = (target - bar) / 2
        guard perSide > 0 else { return Result(perSide: [], remainder: 0) }
        var plates: [Double] = []
        for plate in available.sorted(by: >) {
            while perSide + 0.0001 >= plate {
                plates.append(plate)
                perSide -= plate
            }
        }
        return Result(perSide: plates, remainder: max(0, perSide * 2))
    }
}

extension TimeInterval {
    /// "4:05" or "1:02:30".
    var clockString: String {
        let total = Int(self.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

extension Int {
    var restLabel: String {
        self == 0 ? "Off" : TimeInterval(self).clockString
    }
}

extension Bundle {
    var appVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }
}
