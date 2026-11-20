import Foundation

/// Reads workout exports (CSV) from other apps: Strong, Hevy, and anything with similar
/// columns. Each row is one set; rows are grouped into workouts by start time and name.
/// Pure Foundation so it can be tested without the database.
struct WorkoutCSVParser {
    struct ParsedSet {
        var order: Int
        var weight: Double?          // in `weightUnit` unless the column said kg/lb
        var weightKg: Double?        // set when the column was explicitly kg or lb
        var reps: Int
        var seconds: Double
        var distanceMeters: Double
        var setType: String          // "normal", "warmup", "drop", "failure"
    }

    struct ParsedExercise {
        var name: String
        var notes: String
        var sets: [ParsedSet]
    }

    struct ParsedWorkout {
        var name: String
        var start: Date
        var end: Date
        var notes: String
        var exercises: [ParsedExercise]
    }

    struct Result {
        var format: String            // "Strong", "Hevy" or "CSV"
        var workouts: [ParsedWorkout]
        /// True when weights carry no unit and the user should confirm kg or lb.
        var weightUnitIsAmbiguous: Bool
        var skippedRows: Int
    }

    enum ParseError: LocalizedError {
        case empty, missingColumns([String])

        var errorDescription: String? {
            switch self {
            case .empty:
                return String(localized: "The file is empty.")
            case .missingColumns(let names):
                return String(localized: "This file doesn't look like a workout export. Missing columns: \(names.joined(separator: ", ")).")
            }
        }
    }

    // MARK: - Columns

    private enum Column: CaseIterable {
        case start, end, workoutName, duration, exercise, setOrder, setType
        case weight, weightKg, weightLb, reps, distance, distanceKm, distanceMiles, distanceMeters
        case seconds, notes, workoutNotes

        /// Header names (lowercased) that map to this column, English and German.
        var aliases: [String] {
            switch self {
            case .start: return ["date", "start_time", "start time", "start", "datum", "startzeit", "workout date"]
            case .end: return ["end_time", "end time", "end", "endzeit"]
            case .workoutName: return ["workout name", "title", "workout", "workout_name", "workout title", "workout-name", "name des trainings", "trainingsname", "training"]
            case .duration: return ["duration", "workout duration", "dauer"]
            case .exercise: return ["exercise name", "exercise_title", "exercise", "exercise title", "name der übung", "übung", "übungsname", "uebung"]
            case .setOrder: return ["set order", "set_index", "set", "set number", "reihenfolge festlegen", "satz", "satzreihenfolge"]
            case .setType: return ["set_type", "set type", "satztyp"]
            case .weight: return ["weight", "gewicht", "load"]
            case .weightKg: return ["weight_kg", "weight (kg)", "weight kg", "gewicht (kg)", "kg"]
            case .weightLb: return ["weight_lbs", "weight_lb", "weight (lbs)", "weight (lb)", "lbs", "lb"]
            case .reps: return ["reps", "repetitions", "wiederholungen", "wiederh.", "wdh", "wdh."]
            case .distance: return ["distance", "entfernung", "distanz", "strecke"]
            case .distanceKm: return ["distance_km", "distance (km)", "km"]
            case .distanceMiles: return ["distance_miles", "distance (mi)", "miles", "mi"]
            case .distanceMeters: return ["distance_meters", "distance (m)", "meters", "m"]
            case .seconds: return ["seconds", "duration_seconds", "time", "sekunden", "duration (seconds)"]
            case .notes: return ["notes", "exercise_notes", "exercise notes", "notizen", "notiz"]
            case .workoutNotes: return ["workout notes", "description", "workout_notes", "workout-notizen", "trainingsnotizen"]
            }
        }
    }

    // MARK: - Parsing

    /// `distanceIsMiles` applies to a plain "Distance" column (Strong uses the app's unit).
    static func parse(_ text: String, distanceIsMiles: Bool = false) throws -> Result {
        var text = text
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let headerLine = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw ParseError.empty
        }
        let delimiter = detectDelimiter(headerLine)
        let rows = csvRows(text, delimiter: delimiter)
        guard let header = rows.first else { throw ParseError.empty }

        // Map columns by header name.
        let normalized = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        var index: [Column: Int] = [:]
        for column in Column.allCases {
            if let position = normalized.firstIndex(where: { column.aliases.contains($0) }) {
                index[column] = position
            }
        }
        var missing: [String] = []
        if index[.start] == nil { missing.append("Date") }
        if index[.exercise] == nil { missing.append("Exercise") }
        if !missing.isEmpty { throw ParseError.missingColumns(missing) }

        let format: String
        if normalized.contains("exercise_title") || normalized.contains("weight_kg") || normalized.contains("weight_lbs") {
            format = "Hevy"
        } else if normalized.contains("set order") || normalized.contains("reihenfolge festlegen") {
            format = "Strong"
        } else {
            format = "CSV"
        }

        // Group rows into workouts, keeping the file's order of exercises and sets.
        var workouts: [String: ParsedWorkout] = [:]
        var workoutOrder: [String] = []
        var skipped = 0

        for row in rows.dropFirst() {
            func value(_ column: Column) -> String {
                guard let position = index[column], position < row.count else { return "" }
                return row[position].trimmingCharacters(in: .whitespaces)
            }
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }

            let exerciseName = value(.exercise)
            guard !exerciseName.isEmpty, let start = parseDate(value(.start)) else {
                skipped += 1
                continue
            }
            // Strong writes rest-timer rows ("Rest Timer", German "Ruhezeit") between sets.
            let orderText = value(.setOrder)
            let orderLower = orderText.lowercased()
            if ["rest", "ruhezeit", "pause", "note", "notiz"].contains(where: { orderLower.contains($0) }) { continue }

            let weightKg: Double? = parseNumber(value(.weightKg)).map { $0 }
                ?? parseNumber(value(.weightLb)).map { $0 / 2.2046226218 }
            let weight = parseNumber(value(.weight))
            let reps = Int(parseNumber(value(.reps)) ?? 0)
            let seconds = parseNumber(value(.seconds)) ?? 0
            var meters = 0.0
            if let km = parseNumber(value(.distanceKm)) { meters = km * 1000 }
            else if let miles = parseNumber(value(.distanceMiles)) { meters = miles * 1609.344 }
            else if let m = parseNumber(value(.distanceMeters)) { meters = m }
            else if let plain = parseNumber(value(.distance)) { meters = plain * (distanceIsMiles ? 1609.344 : 1000) }

            // Skip rows with nothing logged.
            if reps == 0 && seconds == 0 && meters == 0 && (weight ?? weightKg ?? 0) == 0 {
                skipped += 1
                continue
            }

            let rawName = value(.workoutName)
            let workoutName = rawName.isEmpty ? String(localized: "Imported Workout") : rawName
            let key = "\(start.timeIntervalSince1970)|\(workoutName)"
            if workouts[key] == nil {
                let end = parseDate(value(.end))
                    ?? parseDuration(value(.duration)).map { start.addingTimeInterval($0) }
                    ?? start.addingTimeInterval(3600)
                workouts[key] = ParsedWorkout(name: workoutName, start: start, end: max(end, start),
                                              notes: value(.workoutNotes), exercises: [])
                workoutOrder.append(key)
            }

            var setType = "normal"
            let typeText = (value(.setType).isEmpty ? orderText : value(.setType)).lowercased()
            if typeText == "w" || typeText.contains("warm") { setType = "warmup" }
            else if typeText == "d" || typeText.contains("drop") { setType = "drop" }
            else if typeText == "f" || typeText.contains("fail") { setType = "failure" }

            guard var workout = workouts[key] else { continue }
            // Consecutive rows of the same exercise belong together.
            if workout.exercises.last?.name != exerciseName {
                workout.exercises.append(ParsedExercise(name: exerciseName, notes: value(.notes), sets: []))
            }
            let exerciseIndex = workout.exercises.count - 1
            let order = workout.exercises[exerciseIndex].sets.count
            workout.exercises[exerciseIndex].sets.append(
                ParsedSet(order: order, weight: weightKg == nil ? weight : nil, weightKg: weightKg,
                          reps: reps, seconds: seconds, distanceMeters: meters, setType: setType))
            workouts[key] = workout
        }

        let ordered = workoutOrder.compactMap { workouts[$0] }.sorted { $0.start < $1.start }
        let ambiguous = index[.weightKg] == nil && index[.weightLb] == nil && index[.weight] != nil
        return Result(format: format, workouts: ordered, weightUnitIsAmbiguous: ambiguous, skippedRows: skipped)
    }

    // MARK: - Helpers

    static func detectDelimiter(_ header: String) -> Character {
        let candidates: [Character] = [",", ";", "\t"]
        return candidates.max { header.count(of: $0) < header.count(of: $1) } ?? ","
    }

    /// RFC 4180-style CSV: quoted fields may contain delimiters, newlines and "" escapes.
    static func csvRows(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character? = nil

        while let char = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if char == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(char)
                }
            } else if char == "\"" {
                inQuotes = true
            } else if char == delimiter {
                row.append(field); field = ""
            } else if char.isNewline {
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(char)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }

    /// Accepts "80", "80.5" and "80,5"; empty or invalid gives nil.
    static func parseNumber(_ text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty else { return nil }
        if let value = Double(cleaned) { return value }
        // "1.234,5" (German thousands) or "80,5"
        let normalized = cleaned.contains(",") && cleaned.contains(".")
            ? cleaned.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            : cleaned.replacingOccurrences(of: ",", with: ".")
        return Double(normalized)
    }

    /// "1h 5m", "45m", "30s", "1:05:00", "65:00" or plain seconds.
    static func parseDuration(_ text: String) -> TimeInterval? {
        let text = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text.contains(":") {
            let parts = text.split(separator: ":").compactMap { Double($0) }
            guard !parts.isEmpty else { return nil }
            return parts.reduce(0) { $0 * 60 + $1 }
        }
        var total = 0.0
        var number = ""
        var found = false
        for char in text {
            if char.isNumber || char == "." || char == "," {
                number.append(char == "," ? "." : char)
            } else if let value = Double(number) {
                switch char {
                case "h": total += value * 3600; found = true
                case "m": total += value * 60; found = true
                case "s": total += value; found = true
                default: break
                }
                number = ""
            }
        }
        if !found, let value = Double(number) { return value }
        return found ? total : nil
    }

    private static let dateFormats = [
        "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm",
        "d MMM yyyy, HH:mm", "d MMM yyyy HH:mm", "dd MMM yyyy, HH:mm", "MMM d, yyyy, h:mm a", "MMM d, yyyy h:mm a",
        "dd.MM.yyyy HH:mm:ss", "dd.MM.yyyy HH:mm", "dd.MM.yyyy, HH:mm", "d.M.yyyy HH:mm",
        "MM/dd/yyyy HH:mm:ss", "MM/dd/yyyy HH:mm", "M/d/yyyy h:mm a", "dd/MM/yyyy HH:mm",
        "yyyy-MM-dd", "dd.MM.yyyy",
    ]

    private static let formatters: [DateFormatter] = dateFormats.flatMap { format in
        ["en_US_POSIX", "de_DE"].map { localeID in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: localeID)
            formatter.timeZone = .current
            formatter.dateFormat = format
            return formatter
        }
    }

    static func parseDate(_ text: String) -> Date? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        for formatter in formatters {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

private extension String {
    func count(of character: Character) -> Int {
        reduce(0) { $1 == character ? $0 + 1 : $0 }
    }
}
