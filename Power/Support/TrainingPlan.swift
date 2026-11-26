import Foundation
import SwiftData

// MARK: - Answers

/// What the person told Power in the plan setup.
struct TrainingProfile: Codable, Hashable {
    enum Goal: String, Codable, CaseIterable, Identifiable {
        case strength, muscle, fatLoss, fitness
        var id: String { rawValue }
        var title: String {
            switch self {
            case .strength: return String(localized: "Get stronger")
            case .muscle: return String(localized: "Build muscle")
            case .fatLoss: return String(localized: "Lose fat")
            case .fitness: return String(localized: "Stay fit and healthy")
            }
        }
        var systemImage: String {
            switch self {
            case .strength: return "scalemass.fill"
            case .muscle: return "figure.strengthtraining.traditional"
            case .fatLoss: return "flame.fill"
            case .fitness: return "heart.fill"
            }
        }
    }

    enum Experience: String, Codable, CaseIterable, Identifiable {
        case beginner, intermediate, advanced
        var id: String { rawValue }
        var title: String {
            switch self {
            case .beginner: return String(localized: "New to the gym")
            case .intermediate: return String(localized: "Training for a while")
            case .advanced: return String(localized: "Experienced")
            }
        }
        var detail: String {
            switch self {
            case .beginner: return String(localized: "Less than 6 months")
            case .intermediate: return String(localized: "6 months to 2 years")
            case .advanced: return String(localized: "More than 2 years")
            }
        }
    }

    enum Gym: String, Codable, CaseIterable, Identifiable {
        case fullGym, smallGym, dumbbells, bodyweight
        var id: String { rawValue }
        var title: String {
            switch self {
            case .fullGym: return String(localized: "Full gym")
            case .smallGym: return String(localized: "Small gym")
            case .dumbbells: return String(localized: "Dumbbells at home")
            case .bodyweight: return String(localized: "No equipment")
            }
        }
        var detail: String {
            switch self {
            case .fullGym: return String(localized: "Machines, cables, barbells and dumbbells")
            case .smallGym: return String(localized: "Barbells, dumbbells and a bench, few machines")
            case .dumbbells: return String(localized: "A pair of dumbbells, maybe a bench")
            case .bodyweight: return String(localized: "Bodyweight only, maybe a pull-up bar")
            }
        }
        var systemImage: String {
            switch self {
            case .fullGym: return "building.2.fill"
            case .smallGym: return "dumbbell.fill"
            case .dumbbells: return "house.fill"
            case .bodyweight: return "figure.cooldown"
            }
        }
        var equipment: Set<Equipment> {
            switch self {
            case .fullGym: return Set(Equipment.allCases)
            case .smallGym: return [.barbell, .dumbbell, .bodyweight, .kettlebell, .band, .other]
            case .dumbbells: return [.dumbbell, .bodyweight, .band]
            case .bodyweight: return [.bodyweight, .band]
            }
        }
    }

    enum Limitation: String, Codable, CaseIterable, Identifiable {
        case knees, lowerBack, shoulders
        var id: String { rawValue }
        var title: String {
            switch self {
            case .knees: return String(localized: "Knees")
            case .lowerBack: return String(localized: "Lower back")
            case .shoulders: return String(localized: "Shoulders")
            }
        }
    }

    var goal: Goal = .muscle
    var experience: Experience = .beginner
    var daysPerWeek = 3
    var minutesPerWorkout = 60
    var gym: Gym = .fullGym
    var focus: Set<MuscleGroup> = []
    var limitations: Set<Limitation> = []
    /// Free text for Apple Intelligence, e.g. "I love deadlifts" or "no lunges".
    var notes = ""

    static let storageKey = "trainingProfile"

    /// Body parts someone can choose to focus on.
    static let focusOptions: [MuscleGroup] = [.chest, .back, .shoulders, .biceps, .triceps, .legs, .glutes, .core]

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    static func load() -> TrainingProfile? {
        UserDefaults.standard.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(TrainingProfile.self, from: $0) }
    }
}

// MARK: - Plan

/// A training plan: a few routines to rotate through during the week.
struct TrainingPlan: Hashable {
    struct Item: Hashable {
        var exerciseName: String
        var sets: Int
        var reps: Int
    }

    struct Day: Hashable {
        var name: String
        var items: [Item]
        /// Short coaching tip for this routine (from Apple Intelligence), may be empty.
        var tip = ""
    }

    var name: String
    var summary: String
    var days: [Day]
    /// True when Apple Intelligence chose the exercises and wrote the tips.
    var personalizedWithAI = false

    /// Adds the plan's routines. Names already in use get a number ("Upper A 2").
    /// Returns the routines created.
    @discardableResult
    func add(to context: ModelContext) -> [Routine] {
        let exercises = (try? context.fetch(FetchDescriptor<Exercise>(predicate: #Predicate { !$0.isCustom }))) ?? []
        let byName = Dictionary(exercises.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var taken = Set(((try? context.fetch(FetchDescriptor<Routine>())) ?? []).map(\.name))

        var created: [Routine] = []
        for day in days {
            var name = day.name
            var number = 2
            while taken.contains(name) {
                name = "\(day.name) \(number)"
                number += 1
            }
            taken.insert(name)
            let routine = Routine(name: name)
            context.insert(routine)
            for (index, item) in day.items.enumerated() {
                guard let exercise = byName[item.exerciseName] else { continue }
                let entry = RoutineExercise(order: index, targetSets: item.sets, targetReps: item.reps)
                context.insert(entry)
                entry.routine = routine
                entry.exercise = exercise
            }
            created.append(routine)
        }
        try? context.save()
        return created
    }
}

// MARK: - Rule-based builder

/// Builds a sensible plan from the answers with fixed training rules: split by days per
/// week, exercise count by session length, sets and reps by goal and experience, and
/// exercises the gym has and that avoid the person's sore spots. Works on every iPhone;
/// Apple Intelligence can then personalize the exercise choice (see `PlanCoach`).
enum PlanBuilder {
    /// One place in a routine, with exercises that can fill it in order of preference.
    struct Slot: Hashable {
        enum Role { case compound, isolation, core }
        let role: Role
        let muscle: MuscleGroup
        let candidates: [String]
    }

    /// A routine to fill: its name and the slots it would like, most important first.
    struct DayTemplate {
        let name: String
        /// 0 for A, 1 for B, 2 for C: later variants pick later candidates for variety.
        var variant = 0
        let slots: [Slot]
    }

    /// A planned routine before sets/reps: the slots that could be filled, each with the
    /// exercises the person can do, and the rule-based pick.
    struct DraftDay: Hashable {
        let name: String
        let slots: [Slot]
        let options: [[String]]
        let picks: [String]
    }

    static func draft(for profile: TrainingProfile, library: [(name: String, equipment: Equipment)]) -> [DraftDay] {
        let allowed = allowedExercises(profile, library: library)
        let count = exerciseCount(profile)
        var drafts: [DraftDay] = []
        for template in split(profile) {
            var slots = template.slots
            // A focus body part gets an extra exercise on the days that train it, right
            // after the main lifts so shorter sessions keep it.
            if let focusSlot = focusSlot(profile, day: template) {
                slots.insert(focusSlot, at: min(slots.count, 3))
            }
            var used = Set<String>()
            var chosenSlots: [Slot] = []
            var options: [[String]] = []
            var picks: [String] = []
            for slot in slots where chosenSlots.count < count {
                let available = slot.candidates.filter { allowed.contains($0) && !used.contains($0) }
                guard !available.isEmpty else { continue }
                // B and C days start further down the list, so the routines differ.
                let pick = available[min(template.variant, available.count - 1)]
                used.insert(pick)
                chosenSlots.append(slot)
                options.append(available)
                picks.append(pick)
            }
            drafts.append(DraftDay(name: template.name, slots: chosenSlots, options: options, picks: picks))
        }
        return drafts
    }

    /// The rule-based plan.
    static func plan(for profile: TrainingProfile, library: [(name: String, equipment: Equipment)]) -> TrainingPlan {
        let drafts = draft(for: profile, library: library)
        return plan(from: drafts, picks: drafts.map(\.picks), profile: profile)
    }

    /// A plan from drafts with chosen exercises (rule-based or from Apple Intelligence).
    static func plan(from drafts: [DraftDay], picks: [[String]], profile: TrainingProfile,
                     name: String? = nil, summary: String? = nil, tips: [String] = [],
                     personalizedWithAI: Bool = false) -> TrainingPlan {
        let days = drafts.enumerated().map { index, draft in
            let chosen = index < picks.count ? picks[index] : draft.picks
            let items = zip(draft.slots, chosen).map { slot, exercise in
                let (sets, reps) = volume(for: slot, exercise: exercise, profile: profile)
                return TrainingPlan.Item(exerciseName: exercise, sets: sets, reps: reps)
            }
            return TrainingPlan.Day(name: draft.name, items: items, tip: index < tips.count ? tips[index] : "")
        }
        return TrainingPlan(name: name ?? defaultName(profile),
                            summary: summary ?? defaultSummary(profile),
                            days: days,
                            personalizedWithAI: personalizedWithAI)
    }

    // MARK: Split

    static func split(_ profile: TrainingProfile) -> [DayTemplate] {
        let fullBodyName = String(localized: "Full Body")
        let upperName = String(localized: "Upper Body")
        let lowerName = String(localized: "Lower Body")
        let pushName = String(localized: "Push")
        let pullName = String(localized: "Pull")
        let legsName = String(localized: "Legs")
        switch profile.daysPerWeek {
        case ...2:
            return [fullBody("\(fullBodyName) A"), fullBody("\(fullBodyName) B", variant: 1)]
        case 3:
            return profile.experience == .beginner
                ? [fullBody("\(fullBodyName) A"), fullBody("\(fullBodyName) B", variant: 1), fullBody("\(fullBodyName) C", variant: 2)]
                : [push(pushName), pull(pullName), legs(legsName)]
        case 4:
            return [upper("\(upperName) A"), lower("\(lowerName) A"), upper("\(upperName) B", variant: 1), lower("\(lowerName) B", variant: 1)]
        case 5:
            return [push(pushName), pull(pullName), legs(legsName), upper(upperName, variant: 1), lower(lowerName, variant: 1)]
        default:
            return [push("\(pushName) A"), pull("\(pullName) A"), legs("\(legsName) A"),
                    push("\(pushName) B", variant: 1), pull("\(pullName) B", variant: 1), legs("\(legsName) B", variant: 1)]
        }
    }

    // Candidate lists use the built-in library's names, best choice first.
    private static let horizontalPress = ["Bench Press", "Dumbbell Bench Press", "Chest Press Machine", "Smith Machine Bench Press", "Push-up"]
    private static let inclinePress = ["Incline Dumbbell Press", "Incline Bench Press", "Incline Chest Press Machine", "Push-up"]
    private static let chestFly = ["Chest Fly Machine", "Cable Crossover", "Dumbbell Fly", "Low-to-High Cable Fly", "Incline Dumbbell Fly"]
    private static let verticalPress = ["Overhead Press", "Dumbbell Shoulder Press", "Shoulder Press Machine", "Arnold Press"]
    private static let lateralRaise = ["Lateral Raise", "Cable Lateral Raise", "Lateral Raise Machine"]
    private static let rearDelt = ["Face Pull", "Reverse Pec Deck", "Rear Delt Fly", "Band Pull-Apart"]
    private static let verticalPull = ["Lat Pulldown", "Pull-up", "Assisted Pull-up", "Chin-up", "Close-Grip Lat Pulldown"]
    private static let horizontalRow = ["Barbell Row", "Seated Cable Row", "Chest-Supported Dumbbell Row", "Dumbbell Row", "Seated Row Machine", "T-Bar Row", "Inverted Row"]
    private static let biceps = ["Barbell Curl", "Dumbbell Curl", "Cable Curl", "EZ-Bar Curl", "Preacher Curl", "Biceps Curl Machine"]
    private static let bicepsAccessory = ["Hammer Curl", "Incline Dumbbell Curl", "Concentration Curl", "Cable Curl"]
    private static let triceps = ["Triceps Pushdown", "Rope Pushdown", "Skull Crusher", "Overhead Triceps Extension", "Close-Grip Bench Press", "Diamond Push-up", "Triceps Kickback", "Triceps Dip Machine"]
    private static let tricepsAccessory = ["Overhead Triceps Extension", "Rope Pushdown", "Triceps Kickback", "Diamond Push-up"]
    private static let squat = ["Squat", "Hack Squat", "Leg Press", "Goblet Squat", "Smith Machine Squat", "Front Squat", "Bulgarian Split Squat", "Reverse Lunge"]
    private static let hinge = ["Romanian Deadlift", "Deadlift", "Hip Thrust", "Cable Pull-Through", "Kettlebell Swing", "Glute Bridge", "Back Extension"]
    private static let singleLeg = ["Bulgarian Split Squat", "Walking Lunge", "Reverse Lunge", "Step-up", "Leg Press"]
    private static let legCurl = ["Lying Leg Curl", "Seated Leg Curl"]
    private static let legExtension = ["Leg Extension", "Step-up"]
    private static let calves = ["Standing Calf Raise", "Seated Calf Raise"]
    private static let glutes = ["Hip Thrust", "Glute Kickback Machine", "Cable Kickback", "Hip Abduction Machine", "Glute Bridge"]
    private static let core = ["Hanging Leg Raise", "Cable Crunch", "Plank", "Dead Bug", "Ab Wheel Rollout", "Pallof Press", "Crunch", "Side Plank"]

    private static func push(_ name: String, variant: Int = 0) -> DayTemplate {
        DayTemplate(name: name, variant: variant, slots: [
            Slot(role: .compound, muscle: .chest, candidates: horizontalPress),
            Slot(role: .compound, muscle: .shoulders, candidates: verticalPress),
            Slot(role: .compound, muscle: .chest, candidates: inclinePress),
            Slot(role: .isolation, muscle: .shoulders, candidates: lateralRaise),
            Slot(role: .isolation, muscle: .triceps, candidates: triceps),
            Slot(role: .isolation, muscle: .chest, candidates: chestFly),
            Slot(role: .isolation, muscle: .triceps, candidates: tricepsAccessory),
        ])
    }

    private static func pull(_ name: String, variant: Int = 0) -> DayTemplate {
        DayTemplate(name: name, variant: variant, slots: [
            Slot(role: .compound, muscle: .back, candidates: verticalPull),
            Slot(role: .compound, muscle: .back, candidates: horizontalRow),
            Slot(role: .isolation, muscle: .shoulders, candidates: rearDelt),
            Slot(role: .isolation, muscle: .biceps, candidates: biceps),
            Slot(role: .compound, muscle: .back, candidates: Array(horizontalRow.dropFirst())),
            Slot(role: .isolation, muscle: .biceps, candidates: bicepsAccessory),
            Slot(role: .core, muscle: .core, candidates: core),
        ])
    }

    private static func legs(_ name: String, variant: Int = 0) -> DayTemplate {
        DayTemplate(name: name, variant: variant, slots: [
            Slot(role: .compound, muscle: .legs, candidates: squat),
            Slot(role: .compound, muscle: .legs, candidates: hinge),
            Slot(role: .compound, muscle: .legs, candidates: singleLeg),
            Slot(role: .isolation, muscle: .legs, candidates: legCurl),
            Slot(role: .isolation, muscle: .legs, candidates: legExtension),
            Slot(role: .isolation, muscle: .legs, candidates: calves),
            Slot(role: .core, muscle: .core, candidates: core),
        ])
    }

    private static func upper(_ name: String, variant: Int = 0) -> DayTemplate {
        DayTemplate(name: name, variant: variant, slots: [
            Slot(role: .compound, muscle: .chest, candidates: horizontalPress),
            Slot(role: .compound, muscle: .back, candidates: horizontalRow),
            Slot(role: .compound, muscle: .shoulders, candidates: verticalPress),
            Slot(role: .compound, muscle: .back, candidates: verticalPull),
            Slot(role: .isolation, muscle: .biceps, candidates: biceps),
            Slot(role: .isolation, muscle: .triceps, candidates: triceps),
            Slot(role: .isolation, muscle: .shoulders, candidates: lateralRaise),
        ])
    }

    private static func lower(_ name: String, variant: Int = 0) -> DayTemplate {
        DayTemplate(name: name, variant: variant, slots: [
            Slot(role: .compound, muscle: .legs, candidates: squat),
            Slot(role: .compound, muscle: .legs, candidates: hinge),
            Slot(role: .compound, muscle: .legs, candidates: singleLeg),
            Slot(role: .isolation, muscle: .legs, candidates: legCurl),
            Slot(role: .isolation, muscle: .legs, candidates: calves),
            Slot(role: .core, muscle: .core, candidates: core),
            Slot(role: .isolation, muscle: .glutes, candidates: glutes),
        ])
    }

    private static func fullBody(_ name: String, variant: Int = 0) -> DayTemplate {
        DayTemplate(name: name, variant: variant, slots: [
            Slot(role: .compound, muscle: .legs, candidates: squat),
            Slot(role: .compound, muscle: .chest, candidates: horizontalPress),
            Slot(role: .compound, muscle: .back, candidates: horizontalRow),
            Slot(role: .compound, muscle: .legs, candidates: hinge),
            Slot(role: .compound, muscle: .back, candidates: verticalPull),
            Slot(role: .compound, muscle: .shoulders, candidates: verticalPress),
            Slot(role: .core, muscle: .core, candidates: core),
        ])
    }

    /// An extra slot for a focus body part, on days that already train it.
    private static func focusSlot(_ profile: TrainingProfile, day: DayTemplate) -> Slot? {
        let trained = Set(day.slots.map(\.muscle))
        let extra: [MuscleGroup: Slot] = [
            .chest: Slot(role: .isolation, muscle: .chest, candidates: chestFly),
            .back: Slot(role: .compound, muscle: .back, candidates: Array(horizontalRow.reversed())),
            .shoulders: Slot(role: .isolation, muscle: .shoulders, candidates: Array(lateralRaise.reversed()) + rearDelt),
            .biceps: Slot(role: .isolation, muscle: .biceps, candidates: bicepsAccessory),
            .triceps: Slot(role: .isolation, muscle: .triceps, candidates: tricepsAccessory),
            .legs: Slot(role: .isolation, muscle: .legs, candidates: legExtension + legCurl),
            .glutes: Slot(role: .isolation, muscle: .glutes, candidates: glutes),
            .core: Slot(role: .core, muscle: .core, candidates: Array(core.reversed())),
        ]
        // Glutes are trained on leg days; arms on any upper day.
        let related: [MuscleGroup: Set<MuscleGroup>] = [
            .glutes: [.legs, .glutes], .biceps: [.back, .biceps], .triceps: [.chest, .shoulders, .triceps],
        ]
        return profile.focus
            .sorted { $0.rawValue < $1.rawValue }
            .first { !trained.isDisjoint(with: related[$0] ?? [$0]) }
            .flatMap { extra[$0] }
    }

    // MARK: Rules

    /// Exercises per routine by session length; beginners get one fewer.
    static func exerciseCount(_ profile: TrainingProfile) -> Int {
        let base: Int = switch profile.minutesPerWorkout {
        case ..<40: 4
        case ..<55: 5
        case ..<70: 6
        default: 7
        }
        return profile.experience == .beginner ? max(4, base - 1) : base
    }

    /// Sets and reps by goal, experience and whether it's a big lift or an isolation.
    static func volume(for slot: Slot, exercise: String, profile: TrainingProfile) -> (sets: Int, reps: Int) {
        if exercise.contains("Plank") { return (3, 1) }
        var (sets, reps): (Int, Int)
        switch (profile.goal, slot.role) {
        case (.strength, .compound): (sets, reps) = (4, 5)
        case (.strength, _): (sets, reps) = (3, 10)
        case (.muscle, .compound): (sets, reps) = (4, 8)
        case (.muscle, _): (sets, reps) = (3, 12)
        case (.fatLoss, .compound): (sets, reps) = (3, 10)
        case (.fatLoss, _): (sets, reps) = (3, 15)
        case (.fitness, .compound): (sets, reps) = (3, 10)
        case (.fitness, _): (sets, reps) = (3, 12)
        }
        if slot.role == .core { reps = 15 }
        // Focus body parts get an extra set everywhere they're trained.
        if profile.focus.contains(slot.muscle) { sets += 1 }
        if profile.experience == .beginner {
            // Fewer sets and slightly more reps while learning the movements.
            sets = min(sets, profile.focus.contains(slot.muscle) ? 4 : 3)
            if slot.role == .compound { reps = max(reps, 8) }
        } else if profile.experience == .advanced, slot.role != .core {
            sets += slot.role == .compound ? 0 : 1
        }
        return (sets, reps)
    }

    /// Exercises the gym has that avoid the person's limitations.
    static func allowedExercises(_ profile: TrainingProfile, library: [(name: String, equipment: Equipment)]) -> Set<String> {
        let equipment = profile.gym.equipment
        // Lunges and step-ups work without weights, so they're fine at home.
        let bodyweightFriendly: Set<String> = ["Walking Lunge", "Reverse Lunge", "Step-up", "Bulgarian Split Squat"]
        var avoid = Set<String>()
        if profile.limitations.contains(.knees) {
            avoid.formUnion(["Squat", "Front Squat", "Hack Squat", "Smith Machine Squat", "Goblet Squat",
                             "Bulgarian Split Squat", "Walking Lunge", "Reverse Lunge", "Step-up", "Leg Extension"])
        }
        if profile.limitations.contains(.lowerBack) {
            avoid.formUnion(["Deadlift", "Sumo Deadlift", "Rack Pull", "Romanian Deadlift", "Barbell Row", "T-Bar Row",
                             "Squat", "Front Squat", "Good Morning", "Kettlebell Swing", "Back Extension"])
        }
        if profile.limitations.contains(.shoulders) {
            avoid.formUnion(["Overhead Press", "Dumbbell Shoulder Press", "Arnold Press", "Shoulder Press Machine",
                             "Upright Row", "Dip", "Triceps Dip Machine", "Skull Crusher"])
        }
        return Set(library.filter { item in
            (equipment.contains(item.equipment) || (profile.gym != .fullGym && bodyweightFriendly.contains(item.name)))
                && !avoid.contains(item.name)
        }.map(\.name))
    }

    static func defaultName(_ profile: TrainingProfile) -> String {
        String(localized: "\(profile.goal.title) · \(profile.daysPerWeek) days")
    }

    static func defaultSummary(_ profile: TrainingProfile) -> String {
        switch profile.goal {
        case .strength: return String(localized: "Heavy compound lifts with lower reps. Add weight when you hit all your reps.")
        case .muscle: return String(localized: "Moderate weights for 8–12 reps. Add a rep or a little weight each week.")
        case .fatLoss: return String(localized: "Full-body work with higher reps and short rests to keep your heart rate up.")
        case .fitness: return String(localized: "A balanced mix of strength exercises for the whole body.")
        }
    }
}
