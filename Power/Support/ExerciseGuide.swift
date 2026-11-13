import Foundation

/// How-to text and muscles worked for the built-in exercises, looked up by name.
struct ExerciseGuide {
    let primary: [String]
    let secondary: [String]
    let steps: [String]

    static func guide(for exercise: Exercise) -> ExerciseGuide? {
        library[exercise.name]
    }

    /// Asset name of the illustration, e.g. "exercise-bench-press-man".
    static func imageName(for exercise: Exercise, bodyType: BodyType) -> String {
        "exercise-\(slug(exercise.name))-\(bodyType.rawValue)"
    }

    /// "Farmer's Carry" → "farmer-s-carry". Must match the generated asset names.
    static func slug(_ name: String) -> String {
        name.lowercased()
            .split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
            .joined(separator: "-")
    }

    /// SF Symbol shown when an exercise has no illustration (e.g. custom exercises).
    static func symbolName(for exercise: Exercise) -> String {
        switch exercise.name {
        case "Running": return "figure.run"
        case "Rowing Machine": return "figure.rower"
        case "Pull-up", "Chin-up", "Hanging Leg Raise": return "figure.climbing"
        default: break
        }
        switch exercise.muscleGroup {
        case .legs, .glutes: return "figure.strengthtraining.functional"
        case .core: return "figure.core.training"
        case .fullBody: return "figure.cross.training"
        case .cardio: return "figure.mixed.cardio"
        default: return "figure.strengthtraining.traditional"
        }
    }

    private static let library: [String: ExerciseGuide] = [
        // Chest
        "Bench Press": ExerciseGuide(
            primary: ["Chest"], secondary: ["Front Delts", "Triceps"],
            steps: ["Lie on the bench with your eyes under the bar and feet flat on the floor.",
                    "Grip the bar slightly wider than shoulder width and unrack it over your shoulders.",
                    "Lower the bar under control to your mid-chest, elbows at about 45°.",
                    "Press the bar back up until your arms are straight."]),
        "Incline Bench Press": ExerciseGuide(
            primary: ["Upper Chest"], secondary: ["Front Delts", "Triceps"],
            steps: ["Set the bench to a 30–45° incline and lie back with feet planted.",
                    "Unrack the bar with a grip slightly wider than your shoulders.",
                    "Lower it to your upper chest, just below the collarbone.",
                    "Press up and slightly back until your arms are locked out."]),
        "Dumbbell Bench Press": ExerciseGuide(
            primary: ["Chest"], secondary: ["Front Delts", "Triceps"],
            steps: ["Sit on a flat bench with a dumbbell on each thigh, then lie back and bring them to chest level.",
                    "Press the dumbbells up until your arms are straight above your chest.",
                    "Lower them slowly until they're level with your chest and you feel a stretch.",
                    "Press back up, bringing the dumbbells slightly together at the top."]),
        "Incline Dumbbell Press": ExerciseGuide(
            primary: ["Upper Chest"], secondary: ["Front Delts", "Triceps"],
            steps: ["Set the bench to a 30–45° incline and sit back with a dumbbell in each hand.",
                    "Start with the dumbbells at shoulder level, palms facing forward.",
                    "Press them up over your upper chest until your arms are straight.",
                    "Lower slowly back to shoulder level."]),
        "Dumbbell Fly": ExerciseGuide(
            primary: ["Chest"], secondary: ["Front Delts"],
            steps: ["Lie on a flat bench holding dumbbells above your chest, palms facing each other.",
                    "Keep a slight bend in your elbows and open your arms out wide in an arc.",
                    "Stop when you feel a stretch across your chest.",
                    "Squeeze your chest to bring the dumbbells back together over you."]),
        "Cable Crossover": ExerciseGuide(
            primary: ["Chest"], secondary: ["Front Delts"],
            steps: ["Set both pulleys high and hold a handle in each hand, stepping forward into a split stance.",
                    "With a slight bend in your elbows, bring your hands down and together in front of your hips.",
                    "Squeeze your chest for a moment where your hands meet.",
                    "Let your arms open back out slowly until you feel a stretch."]),
        "Chest Press Machine": ExerciseGuide(
            primary: ["Chest"], secondary: ["Front Delts", "Triceps"],
            steps: ["Adjust the seat so the handles line up with your mid-chest.",
                    "Sit with your back flat against the pad and grip the handles.",
                    "Press forward until your arms are straight without locking hard.",
                    "Return slowly until you feel a stretch in your chest."]),
        "Push-up": ExerciseGuide(
            primary: ["Chest"], secondary: ["Triceps", "Front Delts", "Core"],
            steps: ["Start in a high plank with hands slightly wider than your shoulders.",
                    "Keep your body in a straight line from head to heels.",
                    "Lower your chest toward the floor, elbows at about 45°.",
                    "Push back up until your arms are straight."]),
        "Dip": ExerciseGuide(
            primary: ["Lower Chest", "Triceps"], secondary: ["Front Delts"],
            steps: ["Support yourself on parallel bars with arms straight.",
                    "Lean your torso slightly forward to focus on the chest.",
                    "Bend your elbows and lower until your shoulders are just below your elbows.",
                    "Press back up to straight arms."]),
        // Back
        "Deadlift": ExerciseGuide(
            primary: ["Hamstrings", "Glutes", "Lower Back"], secondary: ["Lats", "Traps", "Forearms"],
            steps: ["Stand with the bar over your mid-foot, feet hip-width apart.",
                    "Hinge down and grip the bar just outside your legs, back flat and chest up.",
                    "Push the floor away and stand up, keeping the bar close to your legs.",
                    "Lock out with hips and knees straight, then lower the bar the same way."]),
        "Barbell Row": ExerciseGuide(
            primary: ["Lats", "Upper Back"], secondary: ["Biceps", "Rear Delts", "Lower Back"],
            steps: ["Hold the bar with an overhand grip and hinge forward until your torso is near 45°.",
                    "Let the bar hang at arm's length with your back flat.",
                    "Pull the bar to your lower ribs, driving your elbows back.",
                    "Lower it under control to straight arms."]),
        "Pull-up": ExerciseGuide(
            primary: ["Lats"], secondary: ["Biceps", "Upper Back", "Core"],
            steps: ["Hang from the bar with an overhand grip a little wider than your shoulders.",
                    "Pull your shoulder blades down and back to start the movement.",
                    "Pull yourself up until your chin clears the bar.",
                    "Lower yourself slowly to a full hang."]),
        "Chin-up": ExerciseGuide(
            primary: ["Lats", "Biceps"], secondary: ["Upper Back", "Core"],
            steps: ["Hang from the bar with an underhand grip about shoulder-width apart.",
                    "Brace your core and pull your elbows down toward your ribs.",
                    "Pull until your chin is over the bar.",
                    "Lower slowly to a full hang."]),
        "Lat Pulldown": ExerciseGuide(
            primary: ["Lats"], secondary: ["Biceps", "Upper Back"],
            steps: ["Sit with your thighs under the pad and grip the bar wider than your shoulders.",
                    "Lean back slightly and keep your chest up.",
                    "Pull the bar down to your upper chest, driving your elbows down.",
                    "Let the bar rise slowly until your arms are straight."]),
        "Seated Cable Row": ExerciseGuide(
            primary: ["Upper Back", "Lats"], secondary: ["Biceps", "Rear Delts"],
            steps: ["Sit with feet on the platform, knees slightly bent, holding the handle.",
                    "Sit tall with your arms straight in front of you.",
                    "Pull the handle to your stomach, squeezing your shoulder blades together.",
                    "Return slowly until your arms are straight again."]),
        "Dumbbell Row": ExerciseGuide(
            primary: ["Lats", "Upper Back"], secondary: ["Biceps", "Rear Delts"],
            steps: ["Put one knee and hand on a bench, holding a dumbbell in the other hand.",
                    "Keep your back flat and let the dumbbell hang straight down.",
                    "Pull the dumbbell to your hip, keeping your elbow close to your body.",
                    "Lower it slowly, then switch sides after your reps."]),
        "T-Bar Row": ExerciseGuide(
            primary: ["Upper Back", "Lats"], secondary: ["Biceps", "Rear Delts", "Lower Back"],
            steps: ["Straddle the bar or stand on the machine platform and grip the handles.",
                    "Hinge at the hips with a flat back and arms straight.",
                    "Pull the handles toward your chest, squeezing your shoulder blades.",
                    "Lower under control to full arm extension."]),
        "Back Extension": ExerciseGuide(
            primary: ["Lower Back"], secondary: ["Glutes", "Hamstrings"],
            steps: ["Set the pad just below your hips and hook your heels under the foot rollers.",
                    "Cross your arms over your chest and keep your back neutral.",
                    "Bend forward at the hips as far as is comfortable.",
                    "Raise your torso until your body forms a straight line."]),
        // Shoulders
        "Overhead Press": ExerciseGuide(
            primary: ["Shoulders"], secondary: ["Triceps", "Upper Chest", "Core"],
            steps: ["Stand with the bar on your front shoulders, hands just outside shoulder width.",
                    "Brace your core and squeeze your glutes.",
                    "Press the bar straight up, moving your head back slightly to clear it.",
                    "Lock out overhead, then lower the bar back to your shoulders."]),
        "Dumbbell Shoulder Press": ExerciseGuide(
            primary: ["Shoulders"], secondary: ["Triceps"],
            steps: ["Sit or stand holding dumbbells at shoulder height, palms forward.",
                    "Brace your core and keep your back straight.",
                    "Press the dumbbells overhead until your arms are straight.",
                    "Lower them slowly back to shoulder height."]),
        "Lateral Raise": ExerciseGuide(
            primary: ["Side Delts"], secondary: ["Traps"],
            steps: ["Stand holding dumbbells at your sides with a slight bend in your elbows.",
                    "Raise your arms out to the sides until they reach shoulder height.",
                    "Lead with your elbows and keep your shoulders down.",
                    "Lower slowly back to your sides."]),
        "Cable Lateral Raise": ExerciseGuide(
            primary: ["Side Delts"], secondary: ["Traps"],
            steps: ["Set a pulley at its lowest point and stand side-on, holding the handle with your far hand.",
                    "Start with your hand in front of your hips, elbow slightly bent.",
                    "Raise your arm out to the side up to shoulder height.",
                    "Lower slowly, then switch sides."]),
        "Rear Delt Fly": ExerciseGuide(
            primary: ["Rear Delts"], secondary: ["Upper Back"],
            steps: ["Hinge forward at the hips holding dumbbells under your chest.",
                    "Keep a slight bend in your elbows and your back flat.",
                    "Raise your arms out to the sides, squeezing your shoulder blades.",
                    "Lower under control."]),
        "Face Pull": ExerciseGuide(
            primary: ["Rear Delts"], secondary: ["Upper Back", "Rotator Cuff"],
            steps: ["Set a rope attachment at upper-chest height and grip both ends.",
                    "Step back until your arms are straight.",
                    "Pull the rope toward your face, spreading your hands apart and elbows high.",
                    "Pause, then return slowly."]),
        "Shrug": ExerciseGuide(
            primary: ["Traps"], secondary: ["Forearms"],
            steps: ["Stand holding dumbbells at your sides with arms straight.",
                    "Lift your shoulders straight up toward your ears.",
                    "Hold at the top for a moment.",
                    "Lower your shoulders slowly."]),
        // Arms
        "Barbell Curl": ExerciseGuide(
            primary: ["Biceps"], secondary: ["Forearms"],
            steps: ["Stand holding the bar with an underhand, shoulder-width grip.",
                    "Keep your elbows pinned to your sides.",
                    "Curl the bar up toward your shoulders.",
                    "Lower it slowly until your arms are straight."]),
        "Dumbbell Curl": ExerciseGuide(
            primary: ["Biceps"], secondary: ["Forearms"],
            steps: ["Stand holding dumbbells at your sides, palms facing forward.",
                    "Keep your elbows close to your body.",
                    "Curl the dumbbells up toward your shoulders.",
                    "Lower slowly back to straight arms."]),
        "Hammer Curl": ExerciseGuide(
            primary: ["Brachialis", "Biceps"], secondary: ["Forearms"],
            steps: ["Stand holding dumbbells at your sides, palms facing each other.",
                    "Keep your palms facing in for the whole rep.",
                    "Curl the dumbbells up toward your shoulders.",
                    "Lower them slowly."]),
        "Preacher Curl": ExerciseGuide(
            primary: ["Biceps"], secondary: ["Forearms"],
            steps: ["Sit at the preacher bench with the backs of your arms flat on the pad.",
                    "Grip the handles or bar with an underhand grip.",
                    "Curl up until your forearms are nearly vertical.",
                    "Lower slowly until your arms are almost straight."]),
        "Cable Curl": ExerciseGuide(
            primary: ["Biceps"], secondary: ["Forearms"],
            steps: ["Attach a bar to a low pulley and grip it underhand.",
                    "Stand tall with your elbows at your sides.",
                    "Curl the bar up toward your shoulders.",
                    "Lower slowly, keeping tension on the cable."]),
        "Triceps Pushdown": ExerciseGuide(
            primary: ["Triceps"], secondary: [],
            steps: ["Attach a bar or rope to a high pulley and grip it.",
                    "Pin your elbows to your sides.",
                    "Push down until your arms are fully straight.",
                    "Let the handle rise slowly until your forearms are about parallel to the floor."]),
        "Overhead Triceps Extension": ExerciseGuide(
            primary: ["Triceps"], secondary: [],
            steps: ["Hold one dumbbell with both hands overhead, arms straight.",
                    "Keep your elbows pointing forward and close to your head.",
                    "Lower the dumbbell behind your head by bending your elbows.",
                    "Extend your arms back to the top."]),
        "Skull Crusher": ExerciseGuide(
            primary: ["Triceps"], secondary: [],
            steps: ["Lie on a flat bench holding the bar above your chest with a narrow grip.",
                    "Keep your upper arms still and angled slightly back.",
                    "Bend your elbows to lower the bar toward your forehead.",
                    "Extend your arms back to the start."]),
        "Close-Grip Bench Press": ExerciseGuide(
            primary: ["Triceps"], secondary: ["Chest", "Front Delts"],
            steps: ["Lie on a flat bench and grip the bar about shoulder-width apart.",
                    "Unrack it and keep your elbows tucked close to your body.",
                    "Lower the bar to your lower chest.",
                    "Press back up to straight arms."]),
        // Legs
        "Squat": ExerciseGuide(
            primary: ["Quads", "Glutes"], secondary: ["Hamstrings", "Lower Back", "Core"],
            steps: ["Set the bar on your upper back and stand with feet about shoulder-width apart.",
                    "Brace your core and keep your chest up.",
                    "Sit down and back until your thighs are at least parallel to the floor.",
                    "Drive up through your whole foot to stand back up."]),
        "Front Squat": ExerciseGuide(
            primary: ["Quads"], secondary: ["Glutes", "Core", "Upper Back"],
            steps: ["Rest the bar on your front shoulders with elbows pointing forward.",
                    "Stand with feet shoulder-width apart and torso upright.",
                    "Squat down while keeping your elbows high.",
                    "Drive back up to standing."]),
        "Leg Press": ExerciseGuide(
            primary: ["Quads", "Glutes"], secondary: ["Hamstrings"],
            steps: ["Sit in the machine with your feet shoulder-width apart on the platform.",
                    "Release the safety handles and straighten your legs without locking them.",
                    "Lower the platform until your knees are at about 90°.",
                    "Press back up through your heels."]),
        "Romanian Deadlift": ExerciseGuide(
            primary: ["Hamstrings", "Glutes"], secondary: ["Lower Back"],
            steps: ["Stand holding the bar at hip height with a shoulder-width grip.",
                    "With a slight bend in your knees, push your hips back.",
                    "Slide the bar down your thighs until you feel a strong hamstring stretch.",
                    "Drive your hips forward to stand back up."]),
        "Bulgarian Split Squat": ExerciseGuide(
            primary: ["Quads", "Glutes"], secondary: ["Hamstrings", "Core"],
            steps: ["Stand a stride in front of a bench and rest your back foot on it.",
                    "Hold dumbbells at your sides.",
                    "Lower your back knee toward the floor, keeping your front knee over your foot.",
                    "Push through your front foot to stand, then switch legs."]),
        "Walking Lunge": ExerciseGuide(
            primary: ["Quads", "Glutes"], secondary: ["Hamstrings", "Calves"],
            steps: ["Stand holding dumbbells at your sides.",
                    "Take a long step forward and lower your back knee toward the floor.",
                    "Push off your front foot and bring your back leg forward into the next step.",
                    "Keep alternating legs as you walk."]),
        "Leg Extension": ExerciseGuide(
            primary: ["Quads"], secondary: [],
            steps: ["Sit in the machine with the pad on your lower shins.",
                    "Hold the handles and keep your back against the seat.",
                    "Straighten your legs fully and squeeze your quads.",
                    "Lower slowly."]),
        "Lying Leg Curl": ExerciseGuide(
            primary: ["Hamstrings"], secondary: ["Calves"],
            steps: ["Lie face down with the pad just above your heels.",
                    "Hold the handles and keep your hips on the bench.",
                    "Curl your heels toward your glutes.",
                    "Lower slowly back to the start."]),
        "Standing Calf Raise": ExerciseGuide(
            primary: ["Calves"], secondary: [],
            steps: ["Stand on the platform with the balls of your feet on the edge.",
                    "Let your heels drop below the platform for a stretch.",
                    "Rise up onto your toes as high as you can.",
                    "Pause, then lower slowly."]),
        "Goblet Squat": ExerciseGuide(
            primary: ["Quads", "Glutes"], secondary: ["Core", "Upper Back"],
            steps: ["Hold a kettlebell against your chest with both hands.",
                    "Stand with feet slightly wider than shoulder width.",
                    "Squat down between your knees, keeping your chest tall.",
                    "Drive back up to standing."]),
        // Glutes
        "Hip Thrust": ExerciseGuide(
            primary: ["Glutes"], secondary: ["Hamstrings"],
            steps: ["Sit with your upper back against a bench and the bar over your hips.",
                    "Plant your feet flat, about hip-width apart.",
                    "Drive your hips up until your body is straight from shoulders to knees.",
                    "Squeeze your glutes at the top, then lower."]),
        "Glute Bridge": ExerciseGuide(
            primary: ["Glutes"], secondary: ["Hamstrings", "Core"],
            steps: ["Lie on your back with knees bent and feet flat on the floor.",
                    "Brace your core.",
                    "Push through your heels to lift your hips up.",
                    "Squeeze at the top, then lower slowly."]),
        "Cable Kickback": ExerciseGuide(
            primary: ["Glutes"], secondary: ["Hamstrings"],
            steps: ["Attach an ankle strap to a low pulley and put it on one ankle.",
                    "Face the machine and hold it for balance.",
                    "Kick your leg straight back, squeezing your glute.",
                    "Return slowly, then switch legs."]),
        // Core
        "Plank": ExerciseGuide(
            primary: ["Core"], secondary: ["Shoulders", "Glutes"],
            steps: ["Rest on your forearms and toes, elbows under your shoulders.",
                    "Keep your body in a straight line from head to heels.",
                    "Brace your abs and squeeze your glutes.",
                    "Hold the position for the set time."]),
        "Hanging Leg Raise": ExerciseGuide(
            primary: ["Abs"], secondary: ["Hip Flexors", "Forearms"],
            steps: ["Hang from a pull-up bar with straight arms.",
                    "Keep your legs together and avoid swinging.",
                    "Raise your legs until they're at least parallel to the floor.",
                    "Lower slowly."]),
        "Cable Crunch": ExerciseGuide(
            primary: ["Abs"], secondary: [],
            steps: ["Attach a rope to a high pulley and kneel facing the machine.",
                    "Hold the rope beside your head.",
                    "Crunch down, bringing your elbows toward your knees.",
                    "Return slowly to the start."]),
        "Ab Wheel Rollout": ExerciseGuide(
            primary: ["Abs"], secondary: ["Lats", "Shoulders"],
            steps: ["Kneel holding the ab wheel on the floor under your shoulders.",
                    "Brace your core and roll the wheel forward as far as you can control.",
                    "Keep your back from sagging.",
                    "Pull the wheel back to your knees using your abs."]),
        // Full body and cardio
        "Kettlebell Swing": ExerciseGuide(
            primary: ["Glutes", "Hamstrings"], secondary: ["Core", "Shoulders", "Lower Back"],
            steps: ["Stand with feet wider than your hips and the kettlebell in front of you.",
                    "Hike the kettlebell back between your legs.",
                    "Snap your hips forward to swing it up to chest height.",
                    "Let it swing back down and repeat in one smooth motion."]),
        "Power Clean": ExerciseGuide(
            primary: ["Glutes", "Hamstrings", "Quads"], secondary: ["Traps", "Shoulders", "Core"],
            steps: ["Stand with the bar over your mid-foot and grip it just outside your legs.",
                    "Lift the bar off the floor, keeping your back flat.",
                    "As it passes your knees, explode up with your hips and shrug.",
                    "Pull yourself under the bar and catch it on your front shoulders."]),
        "Farmer's Carry": ExerciseGuide(
            primary: ["Forearms", "Traps"], secondary: ["Core", "Glutes"],
            steps: ["Pick up a heavy dumbbell in each hand.",
                    "Stand tall with your shoulders back.",
                    "Walk with short, steady steps for the set distance or time.",
                    "Set the dumbbells down with a flat back."]),
        "Rowing Machine": ExerciseGuide(
            primary: ["Legs", "Back"], secondary: ["Arms", "Core"],
            steps: ["Strap in your feet and grip the handle.",
                    "Push with your legs first, then lean back slightly.",
                    "Finish by pulling the handle to your lower ribs.",
                    "Return in reverse: arms, then body, then legs."]),
        "Running": ExerciseGuide(
            primary: ["Legs"], secondary: ["Core", "Heart & Lungs"],
            steps: ["Start with a few minutes of easy walking or jogging to warm up.",
                    "Stay upright with relaxed shoulders.",
                    "Land with your feet under your hips and take quick, light steps.",
                    "Cool down with easy walking at the end."]),
    ]
}
