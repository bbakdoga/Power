import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case german = "de"

    static let storageKey = "appLanguage"

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .system: "System Default"
        case .english: "English"
        case .german: "Deutsch"
        }
    }

    var locale: Locale {
        switch self {
        case .system: .autoupdatingCurrent
        case .english, .german: Locale(identifier: rawValue)
        }
    }

    /// Sets the app's preferred language the same way iOS's per-app language setting
    /// does, so every string (including ones built in code, permission prompts and the
    /// Lock Screen timer) uses it. Takes full effect the next time the app launches.
    func applyToBundle() {
        let defaults = UserDefaults.standard
        if self == .system {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([rawValue], forKey: "AppleLanguages")
        }
    }

    /// The language the running app is actually using.
    static var active: String {
        Bundle.main.preferredLocalizations.first ?? "en"
    }
}

enum MuscleGroup: String, CaseIterable, Identifiable, Codable {
    case chest, back, shoulders, biceps, triceps, legs, glutes, core, fullBody, cardio, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chest: return String(localized: "Chest")
        case .back: return String(localized: "Back")
        case .shoulders: return String(localized: "Shoulders")
        case .biceps: return String(localized: "Biceps")
        case .triceps: return String(localized: "Triceps")
        case .legs: return String(localized: "Legs")
        case .glutes: return String(localized: "Glutes")
        case .core: return String(localized: "Core")
        case .fullBody: return String(localized: "Full Body")
        case .cardio: return String(localized: "Cardio")
        case .other: return String(localized: "Other")
        }
    }
}

enum Equipment: String, CaseIterable, Identifiable, Codable {
    case barbell, dumbbell, machine, cable, bodyweight, kettlebell, band, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .barbell: return String(localized: "Barbell")
        case .dumbbell: return String(localized: "Dumbbell")
        case .machine: return String(localized: "Machine")
        case .cable: return String(localized: "Cable")
        case .bodyweight: return String(localized: "Bodyweight")
        case .kettlebell: return String(localized: "Kettlebell")
        case .band: return String(localized: "Band")
        case .other: return String(localized: "Other")
        }
    }
}

/// What each set of an exercise records.
enum TrackingType: String, CaseIterable, Identifiable, Codable {
    case weightReps, duration, distanceDuration, weightDistance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weightReps: return String(localized: "Weight & Reps")
        case .duration: return String(localized: "Time")
        case .distanceDuration: return String(localized: "Distance & Time")
        case .weightDistance: return String(localized: "Weight & Distance")
        }
    }

    var usesWeight: Bool { self == .weightReps || self == .weightDistance }
}

/// Which figure the exercise illustrations show.
enum BodyType: String, CaseIterable, Identifiable {
    case man, woman

    static let storageKey = "bodyType"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .man: return String(localized: "Man")
        case .woman: return String(localized: "Woman")
        }
    }
}

enum SetType: String, CaseIterable, Identifiable, Codable {
    case normal, warmup, drop, failure

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: return String(localized: "Normal")
        case .warmup: return String(localized: "Warm-up")
        case .drop: return String(localized: "Drop set")
        case .failure: return String(localized: "To failure")
        }
    }

    /// Short label shown in place of the set number.
    var shortLabel: String {
        switch self {
        case .normal: return ""
        case .warmup: return String(localized: "W", comment: "Set label for a warm-up set (one letter)")
        case .drop: return String(localized: "D", comment: "Set label for a drop set (one letter)")
        case .failure: return String(localized: "F", comment: "Set label for a set to failure (one letter)")
        }
    }
}

enum BodyMeasurementKind: String, CaseIterable, Identifiable, Codable {
    case bodyweight, bodyFat, chest, waist, hips, arm, thigh

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .bodyweight: "Bodyweight"
        case .bodyFat: "Body Fat"
        case .chest: "Chest"
        case .waist: "Waist"
        case .hips: "Hips"
        case .arm: "Arms"
        case .thigh: "Thighs"
        }
    }

    func localizedTitle(language: AppLanguage) -> String {
        if language == .english {
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

        switch self {
        case .bodyweight: return String(localized: "Bodyweight", locale: language.locale)
        case .bodyFat: return String(localized: "Body Fat", locale: language.locale)
        case .chest: return String(localized: "Chest", locale: language.locale)
        case .waist: return String(localized: "Waist", locale: language.locale)
        case .hips: return String(localized: "Hips", locale: language.locale)
        case .arm: return String(localized: "Arms", locale: language.locale)
        case .thigh: return String(localized: "Thighs", locale: language.locale)
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
