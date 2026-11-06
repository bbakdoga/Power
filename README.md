# Power

A free iPhone workout tracker. Every feature is free: unlimited routines, charts, history, rest timer and plate calculator. Workouts are stored only on the phone, so there are no servers and no accounts.

## What works in this first version

- **Workout:** start an empty workout or start from a routine. Log weight and reps per set, see what you lifted last time next to each set, and check sets off.
- **Rest timer:** starts automatically when you check off a set, with −15 / +15 / Skip. A notification tells you when rest is over, even if the app is closed.
- **Set types:** tap the set number to mark a set as warm-up, drop set or to failure.
- **History:** finished workouts grouped by month, with duration, volume and sets. Any workout can be saved as a routine.
- **Routines:** unlimited routines with target sets and reps, reorderable.
- **Exercises:** about 55 built-in exercises plus your own. Each exercise shows an estimated 1-rep-max chart, personal records and its full history.
- **Settings:** kg or lb, and a plate calculator.

## Run it on your iPhone

1. Install **Xcode 15.4 or newer** from the Mac App Store.
2. Clone this repository and open `Power.xcodeproj`.
3. In Xcode, click the **Power** project, open **Signing & Capabilities**, and pick your Apple ID under **Team**. A free Apple ID works for testing on your own phone.
4. If Xcode says the bundle identifier is taken, change `com.bbakdoga.Power` to something unique.
5. Plug in your iPhone (turn on **Developer Mode** in Settings › Privacy & Security when asked), select it at the top of Xcode, and press **Run** (⌘R).

You can also run it in the iPhone Simulator without a phone.

## Project layout

```
Power/
  PowerApp.swift          App entry point and data store
  Models/                 SwiftData models (Exercise, Workout, sets, routines, body measurements)
  Support/                Units, rest timer, plate math, seed exercise library
  Views/                  One file per screen
```

The Xcode project uses explicit file references so it opens in Xcode 15. If you add a Swift file outside Xcode, run `python3 scripts/generate_xcodeproj.py` to add it to the project. Files added from inside Xcode need nothing extra.

Weights are always stored in kilograms and converted for display, so switching units never changes your history. All model properties have defaults and relationships are optional, so iCloud sync can be turned on later without a data migration.

## Roadmap

- Rest timer on the Lock Screen and Dynamic Island (Live Activity)
- Warm-up set generator and plate calculator inside the workout screen
- Personal record badges during a workout
- Supersets
- Bodyweight and measurement tracking screens
- CSV export and import
- Apple Health and iCloud sync
- Apple Watch app and Home Screen widgets
