import Foundation

/// Ready-made programs inspired by how well-known athletes and coaches are publicly
/// known to train. They're interpretations built from Power's exercise library, not
/// official programs. Programs are named by training style: people are only mentioned
/// as a fact in the description, with no photos, and they aren't affiliated with Power.
struct ProProgram: Identifiable, Hashable {
    enum Category: String, CaseIterable, Identifiable {
        case bodybuilders, powerlifters, creators
        var id: String { rawValue }
        var title: String {
            switch self {
            case .bodybuilders: return String(localized: "Bodybuilders")
            case .powerlifters: return String(localized: "Powerlifters")
            case .creators: return String(localized: "Fitness creators")
            }
        }
        var systemImage: String {
            switch self {
            case .bodybuilders: return "figure.strengthtraining.traditional"
            case .powerlifters: return "scalemass.fill"
            case .creators: return "play.rectangle.fill"
            }
        }
    }

    let id: String
    /// The person who inspired it, never translated. Shown in the description and the
    /// "not affiliated" note only, never as a headline.
    let person: String
    let category: Category
    let bodyType: BodyType
    let programName: String
    /// What the program is about in a few words, e.g. "Classic high-volume bodybuilding".
    let tagline: String
    /// Says who it's inspired by, as a plain fact.
    let summary: String
    /// Library exercise whose illustration stands in for a photo.
    let signatureExercise: String
    let daysPerWeek: Int
    let days: [TrainingPlan.Day]

    var plan: TrainingPlan {
        TrainingPlan(name: programName, summary: summary, days: days)
    }

    var exerciseCount: Int { days.reduce(0) { $0 + $1.items.count } }
}

extension ProProgram {
    /// Shorthand for a routine entry.
    private static func e(_ name: String, _ sets: Int, _ reps: Int) -> TrainingPlan.Item {
        TrainingPlan.Item(exerciseName: name, sets: sets, reps: reps)
    }

    private static func day(_ name: String, _ items: [TrainingPlan.Item]) -> TrainingPlan.Day {
        TrainingPlan.Day(name: name, items: items)
    }

    static func programs(in category: Category) -> [ProProgram] {
        all.filter { $0.category == category }
    }

    static let all: [ProProgram] = [
        // MARK: Bodybuilders
        ProProgram(
            id: "arnold", person: "Arnold Schwarzenegger", category: .bodybuilders, bodyType: .man,
            programName: String(localized: "Golden Era Split"),
            tagline: String(localized: "Classic high-volume bodybuilding"),
            summary: String(localized: "Inspired by the split Arnold Schwarzenegger, 7× Mr. Olympia, made famous: chest and back together, then shoulders and arms, then legs, each twice a week. High volume with classic free-weight lifts."),
            signatureExercise: "Incline Bench Press", daysPerWeek: 6,
            days: [
                day(String(localized: "Chest & Back"), [
                    e("Bench Press", 5, 10), e("Incline Bench Press", 4, 10), e("Dumbbell Fly", 4, 12),
                    e("Pull-up", 4, 10), e("Barbell Row", 4, 10), e("T-Bar Row", 4, 10), e("Dip", 3, 12),
                ]),
                day(String(localized: "Shoulders & Arms"), [
                    e("Overhead Press", 4, 10), e("Arnold Press", 4, 10), e("Lateral Raise", 4, 12),
                    e("Barbell Curl", 4, 10), e("Incline Dumbbell Curl", 3, 10), e("Concentration Curl", 3, 12),
                    e("Close-Grip Bench Press", 4, 10), e("Skull Crusher", 3, 10),
                ]),
                day(String(localized: "Legs"), [
                    e("Squat", 5, 10), e("Leg Press", 4, 12), e("Leg Extension", 4, 12),
                    e("Lying Leg Curl", 4, 12), e("Romanian Deadlift", 3, 10), e("Standing Calf Raise", 5, 15),
                    e("Hanging Leg Raise", 3, 15),
                ]),
            ]),
        ProProgram(
            id: "ronnie", person: "Ronnie Coleman", category: .bodybuilders, bodyType: .man,
            programName: String(localized: "Heavy & Basic"),
            tagline: String(localized: "Heavy basics, six days a week"),
            summary: String(localized: "Inspired by how 8× Mr. Olympia Ronnie Coleman trained: big squats, deadlifts and presses, then plenty of volume on top."),
            signatureExercise: "Squat", daysPerWeek: 6,
            days: [
                day(String(localized: "Back, Biceps & Shoulders"), [
                    e("Deadlift", 4, 6), e("Barbell Row", 4, 10), e("T-Bar Row", 3, 10), e("Seated Cable Row", 3, 12),
                    e("Barbell Curl", 3, 12), e("Preacher Curl", 3, 12), e("Overhead Press", 4, 10), e("Lateral Raise", 3, 12),
                ]),
                day(String(localized: "Legs"), [
                    e("Squat", 4, 8), e("Leg Press", 4, 12), e("Walking Lunge", 3, 12),
                    e("Lying Leg Curl", 3, 12), e("Romanian Deadlift", 3, 10), e("Standing Calf Raise", 4, 15),
                ]),
                day(String(localized: "Chest & Triceps"), [
                    e("Bench Press", 4, 10), e("Incline Dumbbell Press", 4, 10), e("Decline Bench Press", 3, 10),
                    e("Dumbbell Fly", 3, 12), e("Close-Grip Bench Press", 3, 12), e("Skull Crusher", 3, 12),
                    e("Triceps Pushdown", 3, 12),
                ]),
            ]),
        ProProgram(
            id: "dorian", person: "Dorian Yates", category: .bodybuilders, bodyType: .man,
            programName: String(localized: "One-Set HIT"),
            tagline: String(localized: "High-intensity bodybuilding"),
            summary: String(localized: "Inspired by 6× Mr. Olympia Dorian Yates: four short workouts a week. After a warm-up set, do one all-out set per exercise."),
            signatureExercise: "Barbell Row", daysPerWeek: 4,
            days: [
                day(String(localized: "Shoulders & Triceps"), [
                    e("Dumbbell Shoulder Press", 2, 8), e("Lateral Raise", 2, 10), e("Rear Delt Fly", 2, 10),
                    e("Triceps Pushdown", 2, 10), e("Overhead Triceps Extension", 2, 10),
                ]),
                day(String(localized: "Back"), [
                    e("Close-Grip Lat Pulldown", 2, 8), e("Barbell Row", 2, 8), e("Seated Row Machine", 2, 8),
                    e("Rack Pull", 2, 8), e("Back Extension", 2, 10),
                ]),
                day(String(localized: "Chest & Biceps"), [
                    e("Incline Bench Press", 2, 8), e("Bench Press", 2, 8), e("Incline Dumbbell Fly", 2, 10),
                    e("Cable Crossover", 2, 10), e("Incline Dumbbell Curl", 2, 8), e("Preacher Curl", 2, 8),
                ]),
                day(String(localized: "Legs"), [
                    e("Leg Extension", 2, 12), e("Leg Press", 2, 12), e("Hack Squat", 2, 10),
                    e("Lying Leg Curl", 2, 10), e("Romanian Deadlift", 2, 10), e("Standing Calf Raise", 2, 12),
                ]),
            ]),
        ProProgram(
            id: "dlb", person: "Dana Linn Bailey", category: .bodybuilders, bodyType: .woman,
            programName: String(localized: "Heavy & Hard"),
            tagline: String(localized: "Strength-focused physique training"),
            summary: String(localized: "Inspired by Dana Linn Bailey, the first Women's Physique Olympia champion: five intense days built on heavy compound lifts, with two leg days for quads, hamstrings and glutes."),
            signatureExercise: "Hip Thrust", daysPerWeek: 5,
            days: [
                day(String(localized: "Quads & Calves"), [
                    e("Squat", 4, 8), e("Leg Press", 4, 12), e("Walking Lunge", 3, 12),
                    e("Leg Extension", 3, 15), e("Standing Calf Raise", 4, 15),
                ]),
                day(String(localized: "Back"), [
                    e("Pull-up", 4, 8), e("Barbell Row", 4, 8), e("Lat Pulldown", 3, 12),
                    e("Seated Cable Row", 3, 12), e("Straight-Arm Pulldown", 3, 15),
                ]),
                day(String(localized: "Shoulders"), [
                    e("Overhead Press", 4, 8), e("Arnold Press", 3, 10), e("Lateral Raise", 4, 15),
                    e("Rear Delt Fly", 3, 15), e("Shrug", 3, 12),
                ]),
                day(String(localized: "Hamstrings & Glutes"), [
                    e("Romanian Deadlift", 4, 8), e("Hip Thrust", 4, 10), e("Lying Leg Curl", 3, 12),
                    e("Bulgarian Split Squat", 3, 10), e("Cable Kickback", 3, 15),
                ]),
                day(String(localized: "Chest & Arms"), [
                    e("Incline Dumbbell Press", 4, 10), e("Bench Press", 3, 8), e("Cable Crossover", 3, 12),
                    e("Barbell Curl", 3, 12), e("Hammer Curl", 3, 12), e("Rope Pushdown", 3, 12), e("Skull Crusher", 3, 10),
                ]),
            ]),

        // MARK: Powerlifters
        ProProgram(
            id: "coan", person: "Ed Coan", category: .powerlifters, bodyType: .man,
            programName: String(localized: "Classic Powerlifting Split"),
            tagline: String(localized: "One day per big lift"),
            summary: String(localized: "Inspired by Ed Coan, holder of over 70 powerlifting world records: one day each for squat, bench and deadlift, plus an upper-body day. Heavy low-rep sets, then targeted assistance work."),
            signatureExercise: "Deadlift", daysPerWeek: 4,
            days: [
                day(String(localized: "Squat Day"), [
                    e("Squat", 5, 3), e("Leg Press", 3, 10), e("Leg Extension", 3, 12), e("Lying Leg Curl", 3, 12),
                ]),
                day(String(localized: "Bench Day"), [
                    e("Bench Press", 5, 3), e("Close-Grip Bench Press", 3, 6), e("Incline Bench Press", 3, 8),
                    e("Triceps Pushdown", 3, 10), e("Rear Delt Fly", 3, 12),
                ]),
                day(String(localized: "Deadlift Day"), [
                    e("Deadlift", 4, 3), e("Romanian Deadlift", 3, 6), e("Barbell Row", 3, 8),
                    e("Lat Pulldown", 3, 10), e("Cable Crunch", 3, 15),
                ]),
                day(String(localized: "Upper Assistance"), [
                    e("Overhead Press", 3, 8), e("Dumbbell Bench Press", 3, 10), e("Dumbbell Row", 3, 10),
                    e("Lateral Raise", 3, 12), e("Barbell Curl", 3, 10),
                ]),
            ]),
        ProProgram(
            id: "wendler", person: "Jim Wendler", category: .powerlifters, bodyType: .man,
            programName: String(localized: "Monthly Wave Strength"),
            tagline: String(localized: "Slow, steady strength gains"),
            summary: String(localized: "Inspired by coach Jim Wendler's approach: four days, one main lift each. Three heavy sets building to a top set, then 5×10 for size. Add a little weight every month."),
            signatureExercise: "Overhead Press", daysPerWeek: 4,
            days: [
                day(String(localized: "Press Day"), [
                    e("Overhead Press", 3, 5), e("Dumbbell Shoulder Press", 5, 10), e("Chin-up", 5, 10),
                ]),
                day(String(localized: "Deadlift Day"), [
                    e("Deadlift", 3, 5), e("Romanian Deadlift", 5, 10), e("Hanging Leg Raise", 5, 10),
                ]),
                day(String(localized: "Bench Day"), [
                    e("Bench Press", 3, 5), e("Dumbbell Bench Press", 5, 10), e("Dumbbell Row", 5, 10),
                ]),
                day(String(localized: "Squat Day"), [
                    e("Squat", 3, 5), e("Leg Press", 5, 10), e("Lying Leg Curl", 5, 10),
                ]),
            ]),
        ProProgram(
            id: "westside", person: "Louie Simmons", category: .powerlifters, bodyType: .man,
            programName: String(localized: "Conjugate Powerlifting"),
            tagline: String(localized: "Max-effort and speed days"),
            summary: String(localized: "Inspired by the conjugate method of Louie Simmons: two max-effort days to work up to heavy singles, and two speed days with lighter, explosive sets. Lots of back and triceps work."),
            signatureExercise: "Close-Grip Bench Press", daysPerWeek: 4,
            days: [
                day(String(localized: "Max Effort Lower"), [
                    e("Deadlift", 5, 2), e("Back Extension", 4, 10), e("Lying Leg Curl", 4, 10), e("Ab Wheel Rollout", 4, 10),
                ]),
                day(String(localized: "Max Effort Upper"), [
                    e("Close-Grip Bench Press", 5, 2), e("Skull Crusher", 4, 10), e("Dumbbell Row", 4, 10), e("Face Pull", 4, 15),
                ]),
                day(String(localized: "Speed Lower"), [
                    e("Squat", 10, 2), e("Sumo Deadlift", 6, 1), e("Cable Pull-Through", 3, 15), e("Cable Crunch", 4, 15),
                ]),
                day(String(localized: "Speed Upper"), [
                    e("Bench Press", 9, 3), e("Triceps Pushdown", 4, 15), e("Lat Pulldown", 4, 12), e("Band Pull-Apart", 3, 20),
                ]),
            ]),
        ProProgram(
            id: "stefi", person: "Stefi Cohen", category: .powerlifters, bodyType: .woman,
            programName: String(localized: "High-Frequency Strength"),
            tagline: String(localized: "The big three, several times a week"),
            summary: String(localized: "Inspired by Stefi Cohen, holder of 25 powerlifting world records: squat, bench and deadlift several times a week. Heavy days and volume days take turns, with upper back and core work."),
            signatureExercise: "Deadlift", daysPerWeek: 4,
            days: [
                day(String(localized: "Squat & Bench"), [
                    e("Squat", 5, 3), e("Bench Press", 5, 3), e("Bulgarian Split Squat", 3, 8), e("Dumbbell Row", 3, 10),
                ]),
                day(String(localized: "Deadlift & Press"), [
                    e("Deadlift", 4, 3), e("Overhead Press", 4, 6), e("Pull-up", 4, 6), e("Plank", 3, 1),
                ]),
                day(String(localized: "Bench & Upper Back"), [
                    e("Bench Press", 4, 6), e("Incline Dumbbell Press", 3, 10), e("Seated Cable Row", 3, 10),
                    e("Face Pull", 3, 15), e("Triceps Pushdown", 3, 12),
                ]),
                day(String(localized: "Squat & Hinge"), [
                    e("Squat", 4, 6), e("Romanian Deadlift", 3, 8), e("Walking Lunge", 3, 10), e("Hanging Leg Raise", 3, 12),
                ]),
            ]),

        // MARK: Fitness creators
        ProProgram(
            id: "nippard", person: "Jeff Nippard", category: .creators, bodyType: .man,
            programName: String(localized: "Science-Based Upper/Lower"),
            tagline: String(localized: "Evidence-based muscle building"),
            summary: String(localized: "Inspired by science-focused coach and YouTuber Jeff Nippard: a strength and a muscle-building version of upper and lower body. Stop 1–2 reps before failure and add reps or weight each week."),
            signatureExercise: "Romanian Deadlift", daysPerWeek: 4,
            days: [
                day(String(localized: "Upper Strength"), [
                    e("Bench Press", 3, 6), e("Pull-up", 3, 8), e("Chest-Supported Dumbbell Row", 3, 8),
                    e("Dumbbell Shoulder Press", 3, 8), e("Cable Lateral Raise", 3, 12), e("Triceps Pushdown", 3, 10),
                    e("Incline Dumbbell Curl", 3, 10),
                ]),
                day(String(localized: "Lower Strength"), [
                    e("Squat", 3, 6), e("Romanian Deadlift", 3, 8), e("Leg Press", 3, 10),
                    e("Seated Leg Curl", 3, 10), e("Standing Calf Raise", 3, 12), e("Cable Crunch", 3, 12),
                ]),
                day(String(localized: "Upper Muscle"), [
                    e("Incline Dumbbell Press", 3, 10), e("Seated Cable Row", 3, 10), e("Lat Pulldown", 3, 12),
                    e("Low-to-High Cable Fly", 3, 12), e("Lateral Raise", 3, 15), e("Overhead Triceps Extension", 3, 12),
                    e("Hammer Curl", 3, 12),
                ]),
                day(String(localized: "Lower Muscle"), [
                    e("Hack Squat", 3, 10), e("Hip Thrust", 3, 10), e("Bulgarian Split Squat", 3, 10),
                    e("Leg Extension", 3, 15), e("Lying Leg Curl", 3, 12), e("Seated Calf Raise", 3, 15),
                ]),
            ]),
        ProProgram(
            id: "athleanx", person: "Jeff Cavaliere", category: .creators, bodyType: .man,
            programName: String(localized: "Train Like an Athlete"),
            tagline: String(localized: "Strength, athleticism and healthy shoulders"),
            summary: String(localized: "Inspired by physical therapist and YouTuber Jeff Cavaliere: three full-body days that build strength and athleticism. Face pulls and core work keep shoulders and posture healthy."),
            signatureExercise: "Face Pull", daysPerWeek: 3,
            days: [
                day(String(localized: "Athlete A"), [
                    e("Squat", 4, 6), e("Bench Press", 4, 6), e("Pull-up", 3, 8), e("Face Pull", 3, 15), e("Hanging Leg Raise", 3, 12),
                ]),
                day(String(localized: "Athlete B"), [
                    e("Deadlift", 4, 5), e("Overhead Press", 4, 6), e("Dumbbell Row", 3, 10),
                    e("Walking Lunge", 3, 10), e("Pallof Press", 3, 12),
                ]),
                day(String(localized: "Athlete C"), [
                    e("Front Squat", 3, 8), e("Dip", 3, 10), e("Chin-up", 3, 10),
                    e("Band Pull-Apart", 3, 20), e("Ab Wheel Rollout", 3, 10),
                ]),
            ]),
        ProProgram(
            id: "whitney", person: "Whitney Simmons", category: .creators, bodyType: .woman,
            programName: String(localized: "Glutes & Strength"),
            tagline: String(localized: "Glute- and leg-focused gym split"),
            summary: String(localized: "Inspired by fitness YouTuber Whitney Simmons: five gym days with a strong focus on glutes and legs, balanced with back, shoulders and core."),
            signatureExercise: "Hip Thrust", daysPerWeek: 5,
            days: [
                day(String(localized: "Glutes & Hamstrings"), [
                    e("Hip Thrust", 4, 10), e("Romanian Deadlift", 4, 10), e("Lying Leg Curl", 3, 12),
                    e("Cable Kickback", 3, 15), e("Hip Abduction Machine", 3, 20),
                ]),
                day(String(localized: "Back & Biceps"), [
                    e("Lat Pulldown", 4, 10), e("Seated Cable Row", 3, 12), e("Dumbbell Row", 3, 10),
                    e("Face Pull", 3, 15), e("Hammer Curl", 3, 12),
                ]),
                day(String(localized: "Quads & Glutes"), [
                    e("Squat", 4, 8), e("Bulgarian Split Squat", 3, 10), e("Leg Press", 3, 12),
                    e("Leg Extension", 3, 15), e("Step-up", 3, 10),
                ]),
                day(String(localized: "Shoulders, Chest & Triceps"), [
                    e("Dumbbell Shoulder Press", 4, 10), e("Lateral Raise", 4, 15), e("Incline Dumbbell Press", 3, 10),
                    e("Rope Pushdown", 3, 12), e("Rear Delt Fly", 3, 15),
                ]),
                day(String(localized: "Glutes & Core"), [
                    e("Sumo Deadlift", 3, 8), e("Cable Pull-Through", 3, 15), e("Walking Lunge", 3, 12),
                    e("Glute Kickback Machine", 3, 15), e("Plank", 3, 1), e("Dead Bug", 3, 12),
                ]),
            ]),
        ProProgram(
            id: "chloe", person: "Chloe Ting", category: .creators, bodyType: .woman,
            programName: String(localized: "Home Bodyweight Burn"),
            tagline: String(localized: "No equipment needed"),
            summary: String(localized: "Inspired by the home workouts of fitness YouTuber Chloe Ting: short, fast bodyweight circuits. Keep rests short and move quickly from one exercise to the next."),
            signatureExercise: "Glute Bridge", daysPerWeek: 5,
            days: [
                day(String(localized: "Abs & Core"), [
                    e("Crunch", 3, 20), e("Russian Twist", 3, 20), e("Dead Bug", 3, 12), e("Plank", 3, 1), e("Side Plank", 3, 1),
                ]),
                day(String(localized: "Full Body Burn"), [
                    e("Burpee", 3, 12), e("Push-up", 3, 12), e("Reverse Lunge", 3, 12), e("Glute Bridge", 3, 20), e("Crunch", 3, 20),
                ]),
                day(String(localized: "Lower Body"), [
                    e("Glute Bridge", 3, 20), e("Reverse Lunge", 3, 12), e("Step-up", 3, 12),
                    e("Bulgarian Split Squat", 3, 10), e("Side Plank", 3, 1),
                ]),
                day(String(localized: "Upper Body"), [
                    e("Push-up", 3, 12), e("Diamond Push-up", 3, 10), e("Inverted Row", 3, 10), e("Dip", 3, 10), e("Plank", 3, 1),
                ]),
            ]),
    ]
}
