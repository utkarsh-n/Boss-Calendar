import Foundation

/// First-launch contents: the real pipeline of builds in the AI Stuff folder, so the Boss has something to organize.
public enum Seed {
    public static func state(now: Date = .now, calendar: Calendar = .current) -> BossState {
        func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
        func idea(_ title: String, _ body: String, heat: Int, size: IdeaSize, days: Double,
                  track: IdeaTrack = .queued, deadline: Date? = nil) -> Idea {
            Idea(title: title, body: body, createdAt: ago(days), track: track, heat: heat,
                 deadline: deadline, phases: size.phases())
        }
        var state = BossState()
        let nextSunday = calendar.nextDate(after: now, matching: DateComponents(hour: 23, minute: 59, weekday: 1),
                                           matchingPolicy: .nextTime)
        state.ideas = [
            idea("Boss Calendar", "Calendar + notes + reminders that books build blocks for my ideas.",
                 heat: 5, size: .l, days: 0),
            idea("Subtext V2", "Locked-in mode, check-ins, pulsing island dot, theater view.",
                 heat: 4, size: .l, days: 10),
            idea("Toothpaste Toy", "Rheo redesign: Metro metal holo chamber, squeeze crown, stripes.",
                 heat: 4, size: .m, days: 1, deadline: nextSunday),
            idea("Spectra phase 2", "Port the EM spectrum web prototype to SwiftUI + Metal.",
                 heat: 3, size: .l, days: 6),
            idea("Cipher on-device LLM", "MLX + Gemma rhyme suggestions, offline.",
                 heat: 3, size: .xl, days: 14),
            idea("Watch check-in", "\"Did you build?\" from the wrist after each block.",
                 heat: 2, size: .s, days: 0, track: .note)
        ]
        state.ideas[1].credit(minutes: 150)
        if let tonight = calendar.date(bySettingHour: 18, minute: 30, second: 0, of: now) {
            state.nudges.append(Nudge(title: "Charge the iPhone before the build block",
                                      due: tonight > now ? tonight : tonight.addingTimeInterval(86_400)))
        }
        state.nudges.append(Nudge(title: "Send Subtext TestFlight notes", due: now.addingTimeInterval(2 * 86_400),
                                  ideaID: state.ideas[1].id))
        return state
    }
}
