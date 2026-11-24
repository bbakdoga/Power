import Foundation
import SwiftData

/// Turns parsed CSV workouts into Power workouts: matches exercise names to the library
/// (creating custom exercises for unknown ones) and skips workouts already imported.
@MainActor
enum WorkoutImporter {
    struct Plan {
        let source: WorkoutCSVParser.Result
        /// Start times (seconds) of workouts already in Power.
        let existingStarts: Set<Int>
        /// Source exercise name → Power exercise name, for ones that match the library.
        let matches: [String: String]
        /// Source names that will become custom exercises.
        let newExercises: [String]
        /// Sets whose weight is far above the rest for that exercise, likely typos.
        let suspicious: [SuspiciousSet]
        /// Per-exercise unit guesses and sample weights, for the unit pickers.
        let units: [ExerciseUnit]

        func isDuplicate(_ workout: WorkoutCSVParser.ParsedWorkout) -> Bool {
            existingStarts.contains(Int(workout.start.timeIntervalSince1970))
        }
        /// Workouts not yet in Power.
        var newWorkouts: [WorkoutCSVParser.ParsedWorkout] { source.workouts.filter { !isDuplicate($0) } }
        var duplicateCount: Int { source.workouts.count - newWorkouts.count }

        /// Workouts that an import adds (all of them when replacing earlier imports).
        func workouts(replacing: Bool) -> [WorkoutCSVParser.ParsedWorkout] {
            replacing ? source.workouts : newWorkouts
        }
        func setCount(replacing: Bool) -> Int {
            workouts(replacing: replacing).reduce(0) { $0 + $1.exercises.reduce(0) { $0 + $1.sets.count } }
        }
        func dateRange(replacing: Bool) -> ClosedRange<Date>? {
            let list = workouts(replacing: replacing)
            guard let first = list.first?.start, let last = list.last?.start else { return nil }
            return first...last
        }
    }

    /// A set that looks like a typo, e.g. 275 instead of 27.5.
    struct SuspiciousSet: Identifiable, Hashable {
        let id: String              // "workout-exercise-set" indexes into `source.workouts`
        let exercise: String
        let date: Date
        let weight: Double          // as written in the file
        let suggested: Double       // weight ÷ 10
        let reps: Int
    }

    /// The unit an exercise was logged in, with a guess and a typical weight to help decide.
    struct ExerciseUnit: Identifiable, Hashable {
        let name: String
        let suggested: WeightUnit
        /// Median weight as written in the file.
        let typicalWeight: Double
        let setCount: Int
        var id: String { name }
    }

    static func plan(for result: WorkoutCSVParser.Result, in context: ModelContext) -> Plan {
        let existingStarts = Set(((try? context.fetch(FetchDescriptor<Workout>())) ?? [])
            .map { Int($0.startDate.timeIntervalSince1970) })

        let library = (try? context.fetch(FetchDescriptor<Exercise>())) ?? []
        var matches: [String: String] = [:]
        var unknown: [String] = []
        var equipment: [String: Equipment] = [:]
        let names = Set(result.workouts.flatMap { $0.exercises.map(\.name) })
        for name in names.sorted() {
            if let match = match(name, in: library) {
                matches[name] = match.name
                // "(Machine)"/"(Cable)" in the source name wins over the library entry's type.
                let named = guessEquipment(name.lowercased())
                equipment[name] = [.machine, .cable].contains(named) ? named : match.equipment
            } else {
                unknown.append(name)
                equipment[name] = guessEquipment(name.lowercased())
            }
        }
        return Plan(source: result, existingStarts: existingStarts,
                    matches: matches, newExercises: unknown,
                    suspicious: findSuspicious(in: result.workouts),
                    units: guessUnits(result.workouts, equipment: equipment))
    }

    // MARK: - Units

    private static let kgPerLb = 0.45359237

    /// True for a kilogram value that is an exact pound amount converted to kg
    /// (e.g. 4.54 = 10 lb, 9.07 = 20 lb), which apps like Strong store for sets logged in lb.
    /// "Clean" kg numbers like 22.5 or 20 don't count.
    static func looksLikeConvertedPounds(_ kilograms: Double) -> Bool {
        guard kilograms > 0 else { return false }
        let pounds = kilograms / kgPerLb
        let nearHalfPound = abs(pounds * 2 - (pounds * 2).rounded()) < 0.06
        let cleanKilograms = abs(kilograms * 4 - (kilograms * 4).rounded()) < 0.02
        return nearHalfPound && !cleanKilograms
    }

    /// Guesses each exercise's unit. Pounds when many sets are converted pound values, or
    /// when a machine/cable exercise's weights are far heavier than the person's free-weight
    /// lifts (pound numbers from a weight stack written as plain numbers).
    private static func guessUnits(_ workouts: [WorkoutCSVParser.ParsedWorkout],
                                   equipment: [String: Equipment]) -> [ExerciseUnit] {
        var weights: [String: [Double]] = [:]
        var order: [String] = []
        for workout in workouts {
            for exercise in workout.exercises {
                if weights[exercise.name] == nil { order.append(exercise.name) }
                weights[exercise.name, default: []] += exercise.sets.compactMap { $0.weightKg ?? $0.weight }.filter { $0 > 0 }
            }
        }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        }
        // Reference: typical weight of free-weight lifts logged as plain kg numbers.
        let freeWeights = weights.filter { [.barbell, .dumbbell].contains(equipment[$0.key] ?? .other) }
            .flatMap(\.value).filter { !looksLikeConvertedPounds($0) }
        let reference = median(freeWeights)

        return order.compactMap { name in
            let values = weights[name] ?? []
            guard !values.isEmpty else { return nil }
            let convertedShare = Double(values.filter(looksLikeConvertedPounds).count) / Double(values.count)
            let typical = median(values)
            // Weight stacks: machines and cables, plus unknown equipment. Smith machines load
            // plates like a barbell, so they don't count.
            let isStack = [.machine, .cable, .other].contains(equipment[name] ?? .other)
                && !["smith", "dip", "chin up", "chin-up", "pull up", "pull-up", "push up", "push-up"].contains { name.lowercased().contains($0) }
            let pounds = convertedShare >= 0.25 || (isStack && reference > 0 && typical >= reference * 1.5)
            return ExerciseUnit(name: name, suggested: pounds ? .lb : .kg, typicalWeight: typical,
                                setCount: values.count)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Kilograms for a weight written in the file, given the unit the exercise was logged in.
    /// For pounds, plain pound numbers are converted; values already converted to kg are kept.
    static func kilograms(fromFile value: Double, explicitKg: Bool, unit: WeightUnit) -> Double {
        guard unit == .lb, !explicitKg, !looksLikeConvertedPounds(value) else { return value }
        return value * kgPerLb
    }

    /// Flags weights more than 4× the exercise's usual top weight when dividing by 10
    /// lands back in its normal range (a missed decimal point).
    private static func findSuspicious(in workouts: [WorkoutCSVParser.ParsedWorkout]) -> [SuspiciousSet] {
        func raw(_ set: WorkoutCSVParser.ParsedSet) -> Double { set.weightKg ?? set.weight ?? 0 }
        var weightsByExercise: [String: [Double]] = [:]
        for workout in workouts {
            for exercise in workout.exercises {
                weightsByExercise[exercise.name, default: []] += exercise.sets.map(raw).filter { $0 > 0 }
            }
        }
        var flagged: [SuspiciousSet] = []
        for (w, workout) in workouts.enumerated() {
            for (e, exercise) in workout.exercises.enumerated() {
                let all = (weightsByExercise[exercise.name] ?? []).sorted()
                guard all.count >= 5 else { continue }
                for (i, set) in exercise.sets.enumerated() {
                    let weight = raw(set)
                    // Typical heavy weight: 90th percentile of everything except this set.
                    let others = all.filter { $0 != weight }
                    guard weight > 0, !others.isEmpty else { continue }
                    let typical = others[min(others.count - 1, Int(Double(others.count) * 0.9))]
                    let suggested = weight / 10
                    if weight > typical * 4, suggested <= typical * 1.5 {
                        flagged.append(SuspiciousSet(id: "\(w)-\(e)-\(i)", exercise: exercise.name, date: workout.start,
                                                     weight: weight, suggested: suggested, reps: set.reps))
                    }
                }
            }
        }
        return flagged
    }

    // MARK: - Import

    /// Adds the plan's workouts with each exercise in its chosen unit, and saves that unit
    /// on the exercise so new workouts use it too. With `replacing`, workouts imported from
    /// this file before are deleted and imported again. Returns the number of workouts added.
    @discardableResult
    static func run(_ plan: Plan, units: [String: WeightUnit], appUnit: WeightUnit,
                    replacing: Bool = false, fixing fixes: Set<String> = [],
                    in context: ModelContext) -> Int {
        if replacing {
            let starts = Set(plan.source.workouts.map { Int($0.start.timeIntervalSince1970) })
            let existing = (try? context.fetch(FetchDescriptor<Workout>(predicate: #Predicate { $0.endDate != nil }))) ?? []
            for workout in existing where starts.contains(Int(workout.startDate.timeIntervalSince1970)) {
                context.delete(workout)
            }
        }

        var library = (try? context.fetch(FetchDescriptor<Exercise>())) ?? []
        var resolved: [String: Exercise] = [:]

        func exercise(named name: String, sets: [WorkoutCSVParser.ParsedSet]) -> Exercise {
            if let cached = resolved[name] { return cached }
            let found = match(name, in: library) ?? {
                let created = makeCustomExercise(name: name, sets: sets)
                context.insert(created)
                library.append(created)
                return created
            }()
            // Remember the unit so this exercise shows (and is logged) in it from now on.
            if let unit = units[name] {
                found.unitRaw = unit == appUnit ? nil : unit.rawValue
            }
            resolved[name] = found
            return found
        }

        var added = 0
        for (w, parsed) in plan.source.workouts.enumerated() {
            if !replacing && plan.isDuplicate(parsed) { continue }
            let workout = Workout(name: parsed.name, startDate: parsed.start)
            workout.endDate = parsed.end
            workout.notes = parsed.notes
            context.insert(workout)
            added += 1

            for (e, parsedExercise) in parsed.exercises.enumerated() {
                let entry = WorkoutExercise(order: e)
                entry.notes = parsedExercise.notes
                context.insert(entry)
                entry.workout = workout
                entry.exercise = exercise(named: parsedExercise.name, sets: parsedExercise.sets)
                let unit = units[parsedExercise.name] ?? appUnit

                for (i, parsedSet) in parsedExercise.sets.enumerated() {
                    var kilograms = parsedSet.weightKg.map {
                        kilograms(fromFile: $0, explicitKg: true, unit: unit)
                    } ?? kilograms(fromFile: parsedSet.weight ?? 0, explicitKg: false, unit: unit)
                    if fixes.contains("\(w)-\(e)-\(i)") { kilograms /= 10 }
                    let set = WorkoutSet(order: parsedSet.order, weightKg: kilograms, reps: parsedSet.reps)
                    set.durationSeconds = parsedSet.seconds
                    set.distanceMeters = parsedSet.distanceMeters
                    set.setType = SetType(rawValue: parsedSet.setType) ?? .normal
                    set.isDone = true
                    set.completedAt = parsed.end
                    context.insert(set)
                    set.workoutExercise = entry
                }
            }
        }
        try? context.save()
        return added
    }

    // MARK: - Exercise matching

    /// Common Strong/Hevy names → Power library names.
    private static let knownNames: [String: String] = [
        "bench press (barbell)": "Bench Press",
        "bench press (dumbbell)": "Dumbbell Bench Press",
        "incline bench press (barbell)": "Incline Bench Press",
        "incline bench press (dumbbell)": "Incline Dumbbell Press",
        "decline bench press (barbell)": "Decline Bench Press",
        "bench press (smith machine)": "Smith Machine Bench Press",
        "chest press (machine)": "Chest Press Machine",
        "chest fly (dumbbell)": "Dumbbell Fly",
        "chest fly (machine)": "Chest Fly Machine",
        "pec deck (machine)": "Chest Fly Machine",
        "cable crossover": "Cable Crossover",
        "chest dip": "Dip",
        "push up": "Push-up",
        "squat (barbell)": "Squat",
        "front squat (barbell)": "Front Squat",
        "squat (smith machine)": "Smith Machine Squat",
        "goblet squat (kettlebell)": "Goblet Squat",
        "hack squat": "Hack Squat",
        "hack squat (machine)": "Hack Squat",
        "leg press": "Leg Press",
        "leg press (machine)": "Leg Press",
        "leg extension (machine)": "Leg Extension",
        "lying leg curl (machine)": "Lying Leg Curl",
        "seated leg curl (machine)": "Seated Leg Curl",
        "romanian deadlift (barbell)": "Romanian Deadlift",
        "deadlift (barbell)": "Deadlift",
        "sumo deadlift (barbell)": "Sumo Deadlift",
        "standing calf raise (machine)": "Standing Calf Raise",
        "seated calf raise (machine)": "Seated Calf Raise",
        "seated calf raise (plate loaded)": "Seated Calf Raise",
        "bulgarian split squat": "Bulgarian Split Squat",
        "lunge (dumbbell)": "Walking Lunge",
        "hip thrust (barbell)": "Hip Thrust",
        "glute bridge": "Glute Bridge",
        "hip abductor (machine)": "Hip Abduction Machine",
        "hip adductor (machine)": "Hip Adduction Machine",
        "glute kickback (machine)": "Glute Kickback Machine",
        "overhead press (barbell)": "Overhead Press",
        "overhead press (dumbbell)": "Dumbbell Shoulder Press",
        "shoulder press (dumbbell)": "Dumbbell Shoulder Press",
        "overhead press (machine)": "Shoulder Press Machine",
        "shoulder press (machine)": "Shoulder Press Machine",
        "arnold press (dumbbell)": "Arnold Press",
        "lateral raise (dumbbell)": "Lateral Raise",
        "lateral raise (cable)": "Cable Lateral Raise",
        "lateral raise (machine)": "Lateral Raise Machine",
        "front raise (dumbbell)": "Front Raise",
        "reverse fly (dumbbell)": "Rear Delt Fly",
        "reverse fly (machine)": "Reverse Pec Deck",
        "face pull (cable)": "Face Pull",
        "upright row (barbell)": "Upright Row",
        "shrug (dumbbell)": "Shrug",
        "lat pulldown (cable)": "Lat Pulldown",
        "lat pulldown - close grip (cable)": "Close-Grip Lat Pulldown",
        "pull up": "Pull-up",
        "pull up (assisted)": "Assisted Pull-up",
        "chin up": "Chin-up",
        "seated row (cable)": "Seated Cable Row",
        "seated row (machine)": "Seated Row Machine",
        "iso-lateral row (machine)": "Seated Row Machine",
        "bent over row (barbell)": "Barbell Row",
        "bent over one arm row (dumbbell)": "Dumbbell Row",
        "dumbbell row": "Dumbbell Row",
        "t bar row": "T-Bar Row",
        "straight arm pulldown (cable)": "Straight-Arm Pulldown",
        "back extension": "Back Extension",
        "back extension (machine)": "Back Extension",
        "bicep curl (barbell)": "Barbell Curl",
        "bicep curl (dumbbell)": "Dumbbell Curl",
        "bicep curl (cable)": "Cable Curl",
        "bicep curl (machine)": "Biceps Curl Machine",
        "ez bar curl": "EZ-Bar Curl",
        "hammer curl (dumbbell)": "Hammer Curl",
        "preacher curl (barbell)": "Preacher Curl",
        "preacher curl (machine)": "Preacher Curl",
        "incline curl (dumbbell)": "Incline Dumbbell Curl",
        "concentration curl (dumbbell)": "Concentration Curl",
        "triceps pushdown (cable - straight bar)": "Triceps Pushdown",
        "triceps pushdown (cable)": "Triceps Pushdown",
        "triceps rope pushdown": "Rope Pushdown",
        "triceps extension (dumbbell)": "Overhead Triceps Extension",
        "skullcrusher (barbell)": "Skull Crusher",
        "skull crusher (barbell)": "Skull Crusher",
        "triceps kickback (dumbbell)": "Triceps Kickback",
        "close grip bench press (barbell)": "Close-Grip Bench Press",
        "triceps dip": "Dip",
        "ab crunch cable": "Cable Crunch",
        "cable crunch": "Cable Crunch",
        "crunch": "Crunch",
        "crunch (machine)": "Ab Crunch Machine",
        "hanging leg raise": "Hanging Leg Raise",
        "plank": "Plank",
        "side plank": "Side Plank",
        "russian twist": "Russian Twist",
        "ab wheel": "Ab Wheel Rollout",
        "running": "Running",
        "running (treadmill)": "Running",
        "rowing (machine)": "Rowing Machine",
        "cycling (indoor)": "Stationary Bike",
        "elliptical trainer": "Elliptical",
        "stair climber": "Stair Climber",
        "jump rope": "Jump Rope",
        "farmers walk": "Farmer's Carry",
        "kettlebell swing": "Kettlebell Swing",
        "power clean": "Power Clean",
        "thruster (barbell)": "Thruster",
        "burpee": "Burpee",
    ]

    /// Finds the Power exercise for a name from another app, or nil when there's none.
    static func match(_ sourceName: String, in library: [Exercise]) -> Exercise? {
        let trimmed = sourceName.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        func named(_ name: String) -> Exercise? {
            library.first { $0.name.caseInsensitiveCompare(name) == .orderedSame && !$0.isCustom }
                ?? library.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
        // 1. Same name (also finds custom exercises created by an earlier import).
        if let exact = named(trimmed) { return exact }
        // 2. Known names from Strong and Hevy.
        if let known = knownNames[lower] ?? knownNames[squeezed(lower)], let exercise = named(known) { return exercise }
        // 3. Same name ignoring spacing, hyphens and case ("Pull Up" → "Pull-up").
        let key = normalizedKey(trimmed)
        return library.first { !$0.isCustom && normalizedKey($0.name) == key }
    }

    /// "Overhead Press(Machine)" → "overhead press (machine)".
    private static func squeezed(_ name: String) -> String {
        name.replacingOccurrences(of: "(", with: " (")
            .split(separator: " ").joined(separator: " ")
    }

    private static func normalizedKey(_ name: String) -> String {
        String(name.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    // MARK: - Custom exercises

    /// A custom exercise for an unknown name, guessing body part, equipment and tracking.
    private static func makeCustomExercise(name: String, sets: [WorkoutCSVParser.ParsedSet]) -> Exercise {
        let lower = name.lowercased()
        let exercise = Exercise(name: name.trimmingCharacters(in: .whitespaces),
                                muscleGroup: guessMuscleGroup(lower), equipment: guessEquipment(lower),
                                isCustom: true)
        let hasReps = sets.contains { $0.reps > 0 }
        let hasDistance = sets.contains { $0.distanceMeters > 0 }
        let hasTime = sets.contains { $0.seconds > 0 }
        let hasWeight = sets.contains { ($0.weightKg ?? $0.weight ?? 0) > 0 }
        if hasDistance {
            exercise.tracking = hasWeight ? .weightDistance : .distanceDuration
        } else if hasTime && !hasReps {
            exercise.tracking = .duration
        }
        return exercise
    }

    private static func guessMuscleGroup(_ name: String) -> MuscleGroup {
        let rules: [(MuscleGroup, [String])] = [
            (.core, ["crunch", "plank", "ab ", "abs", "sit up", "leg raise", "russian", "oblique"]),
            (.glutes, ["glute", "hip thrust", "abduct", "kickback", "bridge"]),
            (.legs, ["squat", "leg", "lunge", "calf", "hamstring", "quad", "adduct", "deadlift"]),
            (.triceps, ["tricep", "skull", "pushdown", "dip"]),
            (.biceps, ["curl", "bicep"]),
            (.shoulders, ["shoulder", "overhead", "lateral", "front raise", "face pull", "reverse fly",
                          "rear delt", "shrug", "rotator", "upright"]),
            (.back, ["row", "pulldown", "pull up", "pull-up", "chin up", "chin-up", "back", "lat "]),
            (.chest, ["bench", "chest", "fly", "push up", "press"]),
            (.cardio, ["run", "row machine", "bike", "cycling", "elliptical", "stair", "walk", "swim"]),
        ]
        return rules.first { _, words in words.contains { name.contains($0) } }?.0 ?? .other
    }

    private static func guessEquipment(_ name: String) -> Equipment {
        if name.contains("barbell") || name.contains("ez bar") { return .barbell }
        if name.contains("dumbbell") { return .dumbbell }
        if name.contains("cable") { return .cable }
        if name.contains("band") { return .band }
        if name.contains("kettlebell") { return .kettlebell }
        if name.contains("machine") || name.contains("plate loaded") || name.contains("leg press") { return .machine }
        if name.contains("bodyweight") || name.contains("push up") || name.contains("pull up") || name.contains("plank") { return .bodyweight }
        return .other
    }
}
