import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Personalizes a rule-based plan with Apple's on-device language model (Apple
/// Intelligence, iOS 26+): it picks exercises from the options the rules allow, taking
/// the person's notes into account, and writes a plan name, a summary and a tip per
/// routine. Runs entirely on the iPhone, so it's free and private. Every choice is
/// checked; anything outside the allowed options falls back to the rule-based pick.
enum PlanCoach {
    /// True when this iPhone can run Apple's on-device model right now.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// The personalized plan, or nil when Apple Intelligence isn't available or fails.
    static func personalize(_ drafts: [PlanBuilder.DraftDay], profile: TrainingProfile) async -> TrainingPlan? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return await modelPlan(drafts, profile: profile)
        }
        #endif
        return nil
    }

    /// Keeps only valid choices: one per slot, from that slot's options, no repeats.
    static func validatedPicks(_ chosen: [[String]], drafts: [PlanBuilder.DraftDay]) -> [[String]] {
        drafts.enumerated().map { dayIndex, draft in
            let proposed = dayIndex < chosen.count ? chosen[dayIndex] : []
            var used = Set<String>()
            return draft.options.enumerated().map { slotIndex, options in
                let candidate = slotIndex < proposed.count ? proposed[slotIndex].trimmingCharacters(in: .whitespaces) : ""
                let match = options.first { $0.caseInsensitiveCompare(candidate) == .orderedSame }
                let pick = [match, draft.picks[slotIndex]].compactMap { $0 }.first { !used.contains($0) }
                    ?? options.first { !used.contains($0) }
                    ?? draft.picks[slotIndex]
                used.insert(pick)
                return pick
            }
        }
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    @Generable
    struct CoachPlan {
        @Guide(description: "A short, motivating name for the whole plan, at most 4 words.")
        var planName: String
        @Guide(description: "Two short sentences telling this person how to use the plan.")
        var summary: String
        @Guide(description: "One entry per routine, in the same order as given.")
        var routines: [CoachRoutine]
    }

    @available(iOS 26.0, *)
    @Generable
    struct CoachRoutine {
        @Guide(description: "Exactly one exercise per slot, in slot order, each copied exactly from that slot's options. Never use the same exercise twice in a routine.")
        var exercises: [String]
        @Guide(description: "One short, practical coaching tip for this routine, at most 20 words.")
        var tip: String
    }

    @available(iOS 26.0, *)
    private static func modelPlan(_ drafts: [PlanBuilder.DraftDay], profile: TrainingProfile) async -> TrainingPlan? {
        guard SystemLanguageModel.default.isAvailable, !drafts.isEmpty else { return nil }

        let language = Bundle.main.preferredLocalizations.first ?? "en"
        let languageName = Locale(identifier: "en").localizedString(forLanguageCode: language) ?? "English"

        let session = LanguageModelSession(instructions: """
            You are a careful strength coach. You personalize a weekly gym plan by choosing \
            one exercise for each slot, only from the options listed for that slot. Respect \
            the person's goal, experience, injuries and notes: if the notes mention an \
            exercise they dislike or can't do, don't choose it; if they mention one they \
            like and it is an option, prefer it. Keep routines varied. Write the plan name, \
            summary and tips in \(languageName). Don't give medical advice.
            """)

        do {
            let response = try await session.respond(
                to: prompt(drafts, profile: profile),
                generating: CoachPlan.self,
                options: GenerationOptions(temperature: 0.4)
            )
            let result = response.content
            let picks = validatedPicks(result.routines.map(\.exercises), drafts: drafts)
            let name = result.planName.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return PlanBuilder.plan(
                from: drafts, picks: picks, profile: profile,
                name: name.isEmpty ? nil : String(name.prefix(40)),
                summary: summary.isEmpty ? nil : summary,
                tips: result.routines.map { $0.tip.trimmingCharacters(in: .whitespacesAndNewlines) },
                personalizedWithAI: true
            )
        } catch {
            return nil
        }
    }

    private static func prompt(_ drafts: [PlanBuilder.DraftDay], profile: TrainingProfile) -> String {
        var lines: [String] = []
        lines.append("Goal: \(profile.goal.rawValue). Experience: \(profile.experience.rawValue).")
        lines.append("Trains \(profile.daysPerWeek) days a week, about \(profile.minutesPerWorkout) minutes each, in: \(profile.gym.rawValue).")
        if !profile.focus.isEmpty {
            lines.append("Wants to focus on: \(profile.focus.map(\.rawValue).sorted().joined(separator: ", ")).")
        }
        if !profile.limitations.isEmpty {
            lines.append("Has sensitive: \(profile.limitations.map(\.rawValue).sorted().joined(separator: ", ")).")
        }
        let notes = profile.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            lines.append("Their notes: \"\(String(notes.prefix(300)))\"")
        }
        lines.append("")
        for (dayIndex, draft) in drafts.enumerated() {
            lines.append("Routine \(dayIndex + 1): \(draft.name)")
            for (slotIndex, slot) in draft.slots.enumerated() {
                let kind = slot.role == .compound ? "main lift" : slot.role == .core ? "core" : "accessory"
                lines.append("  Slot \(slotIndex + 1) (\(slot.muscle.rawValue), \(kind)): \(draft.options[slotIndex].joined(separator: " | "))")
            }
        }
        lines.append("")
        lines.append("Choose the exercises for every routine.")
        return lines.joined(separator: "\n")
    }
    #endif
}
