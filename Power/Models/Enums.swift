import Foundation

enum MuscleGroup: String, CaseIterable, Identifiable, Codable {
    case chest, back, shoulders, biceps, triceps, legs, glutes, core, fullBody, cardio, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullBody: return "Full Body"
        default: return rawValue.capitalized
        }
    }
}

enum Equipment: String, CaseIterable, Identifiable, Codable {
    case barbell, dumbbell, machine, cable, bodyweight, kettlebell, band, other

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Which figure the exercise illustrations show.
enum BodyType: String, CaseIterable, Identifiable {
    case man, woman

    static let storageKey = "bodyType"

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum SetType: String, CaseIterable, Identifiable, Codable {
    case normal, warmup, drop, failure

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: return "Normal"
        case .warmup: return "Warm-up"
        case .drop: return "Drop set"
        case .failure: return "To failure"
        }
    }

    /// Short label shown in place of the set number.
    var shortLabel: String {
        switch self {
        case .normal: return ""
        case .warmup: return "W"
        case .drop: return "D"
        case .failure: return "F"
        }
    }
}

enum BodyMeasurementKind: String, CaseIterable, Identifiable, Codable {
    case bodyweight, bodyFat, chest, waist, hips, arm, thigh

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bodyweight: return "Bodyweight"
        case .bodyFat: return "Body Fat"
        case .chest: return "Chest"
        case .waist: return "Waist"
        case .hips: return "Hips"
        case .arm: return "Arms"
        case .thigh: return "Thighs"
        }
    }

    var systemImage: String {
        switch self {
        case .bodyweight: return "scalemass"
        case .bodyFat: return "percent"
        default: return "ruler"
        }
    }

    /// Stored values are kilograms, percent, or centimetres; lb users see lb and inches.
    func unitLabel(_ unit: WeightUnit) -> String {
        switch self {
        case .bodyweight: return unit.rawValue
        case .bodyFat: return "%"
        default: return unit == .kg ? "cm" : "in"
        }
    }

    func displayValue(_ stored: Double, unit: WeightUnit) -> Double {
        switch self {
        case .bodyweight: return unit.fromKg(stored)
        case .bodyFat: return stored
        default: return unit == .kg ? stored : stored / 2.54
        }
    }

    func storedValue(_ shown: Double, unit: WeightUnit) -> Double {
        switch self {
        case .bodyweight: return unit.toKg(shown)
        case .bodyFat: return shown
        default: return unit == .kg ? shown : shown * 2.54
        }
    }

    func format(_ stored: Double, unit: WeightUnit) -> String {
        let value = displayValue(stored, unit: unit).formatted(.number.precision(.fractionLength(0...1)))
        return self == .bodyFat ? "\(value)%" : "\(value) \(unitLabel(unit))"
    }
}
