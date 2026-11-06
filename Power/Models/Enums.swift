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
}
