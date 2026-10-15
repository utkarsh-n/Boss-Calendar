# Boss Calendar — Blueprint

**v1.0 · native SwiftUI iPhone app · iOS 27 · Metro Station design system · 2026-10-13**

> You jot ideas. The Boss finds the hours, books build blocks around your real life, and keeps re-planning when life happens.

Boss Calendar is three apps that share one brain:

| Face | What it is | Metro vocabulary |
| --- | --- | --- |
| **Notes** | Every idea is a note: title + freeform body + phases. Plain notes that never get scheduled are allowed. | **Depot** — where lines wait |
| **Calendar** | A week board of build blocks laid around your Apple Calendar events. | **Board** — the departures board |
| **Reminders** | Time-based nudges, standalone or attached to an idea, delivered as local notifications. | **Nudges** |
| *The brain* | **Autopilot** — the planner that turns ideas into blocks and re-plans on every change. | **The Boss** |

The home screen is **Station**: one metal instrument dial for *today*, the next departure, and the check-ins the Boss needs from you.

---

## 1 The core loop

```
 jot ──▶ size ──▶ plan ──▶ build ──▶ check in ──▶ re-plan
  ▲                                                  │
  └──────────────── new idea / life changes ─────────┘
```

1. **Jot** (≤ 3 seconds). A glass "Jot it down…" bar floats above the tab bar on every screen. One field; the first line is the title, the rest is the note. A three-way switch picks *Idea to build / Just a note / Reminder*. Reminders get a time from natural language ("call Sam fri 5pm") via `NSDataDetector`, editable before saving. Also available as a Siri / Shortcuts / Action-button App Intent: **"Jot an idea in Boss Calendar"**.
2. **Size.** Every buildable idea starts at a default *M · 8 h* with a stock phase template, so it is schedulable instantly. **Shape** uses the shared offline MLX runtime, with Qwen3.5 2B by default and optional 4B in Settings. It proposes 3–6 named phases with 1–40 whole hours each. Strict JSON and domain validation precede a visible proposal review; only **Use these phases** updates the idea and re-runs scheduling. T-shirt templates remain available with or without a model. You can edit phases and hours by hand.
3. **Plan.** Autopilot packs blocks into your **build windows** (a weekly template, e.g. weeknights 19–22, weekend middays), minus **busy time** read from Apple Calendar, inside a **weekly hours budget**, with a **focus limit** (default: 2 ideas per week, so you finish things instead of touching ten).
4. **Build.** Notifications fire 5 min before a block: *"Boss: Gyre · Field lines at 19:00 (90 min)."* The Station dial shows the block running down.
5. **Check in.** When a block ends, the Station asks *"Did you build?"* — **Built it** credits the time to the idea's current phase; **Skipped** returns the hours to the queue. Unanswered past blocks are never assumed done.
6. **Re-plan.** Every jot, edit, check-in, budget change, window change, calendar change and app foreground runs Autopilot again. Blocks you **lock** never move. Blocks inside the next 12 h stay put unless a new calendar event collides with them (so tonight's plan doesn't reshuffle under you).

---

## 2 Domain model

All persistent state is a single `BossState` value (Codable JSON, atomic writes in Application Support). No server, no account.

```
Idea
  id, title, body (note text), createdAt, updatedAt
  track: .queued | .paused | .note | .shipped     // .note = never scheduled
  heat: 1…5                                         // how badly you want it
  deadline: Date?
  phases: [Phase]                                   // ordered
  shapedBy: .template | .qwen2B | .qwen4B | .manual | .appleIntelligence (historical)

Phase
  id, title, plannedMinutes, doneMinutes            // remaining = max(0, planned − done)

Block                                               // a booked build slot
  id, ideaID, phaseID?, phaseTitle, start, end
  state: .planned | .done | .skipped
  locked: Bool                                      // user pinned → Autopilot never moves it

Nudge (reminder)
  id, title, due, ideaID?, done: Bool

BuildWindow                                         // weekly template
  id, weekday (1 = Sun … 7 = Sat), startMinute, endMinute

PlannerSettings
  weeklyBudgetHours (default 12), blockMinutes (90), minBlockMinutes (45),
  breakMinutes (15), maxBlocksPerDay (2), focusLimit (2 ideas / week),
  busyBufferMinutes (10), horizonDays (21), freezeHours (12),
  useAppleCalendar, notifyBlocks, leadMinutes (5)
```

**Ownership.** `BossStore` (`@Observable`, `@MainActor`) owns `BossState` and is the only writer. The planner is a pure function in the `BossCore` framework: `Planner.plan(PlanInput) -> PlanOutput`. Busy intervals come from `CalendarBridge` (EventKit, read-only). Notifications are re-derived from state by `NotificationScheduler` after every plan — never patched incrementally.

---

## 3 Autopilot (the planner)

Deterministic, explainable, unit-tested. No AI in the scheduling loop; the AI only proposes phases.

### Inputs
`now`, calendar/time zone, ideas (queued only), existing blocks, build windows, busy intervals, settings.

### Step 1 — Keep what must not move
- **Fixed blocks:** `done`, `skipped`, `locked`, anything that has started (`start ≤ now`).
- **Frozen blocks:** planned, unlocked, starting within `freezeHours`, still collision-free against busy time, and whose idea still needs that time.
- Everything else that is planned and in the future is **discarded and re-derived**. That is the self-organizing part.

### Step 2 — Free time
For every day in the horizon: that weekday's windows → clip to `now` (rounded up to the next 15 min) → subtract busy intervals padded by `busyBufferMinutes` → subtract kept blocks (padded by `breakMinutes`).

### Step 3 — Slots
Cut each free interval into `blockMinutes` slots separated by `breakMinutes`. A leftover ≥ `minBlockMinutes` becomes a short slot; smaller leftovers are dropped.

### Step 4 — Capacity
- Per ISO week: `weeklyBudgetHours` minus minutes already held by kept blocks that week.
- Per day: `maxBlocksPerDay` minus kept blocks that day.

### Step 5 — Assignment (chronological, greedy, scored)
For each slot, pick the queued idea with remaining time and the highest score:

```
score = 12·heat                                   // desire
      + urgency                                    // deadlines
      + min(10, 0.5·daysWaiting)                   // anti-starvation
      + 8 if this idea had the previous slot       // momentum / deep work
      + 6 if remaining ≤ slot length               // quick win: finish it
urgency = 0 without a deadline;
          else 60 · clamp(remaining / max(1, workMinutesLeftBeforeDeadline), 0, 2)
```

**Focus limit:** once a week has `focusLimit` distinct ideas, only those ideas can take more slots that week, unless all of them are exhausted. **Deadline guard:** a slot after an idea's deadline is never given to that idea.

The block length is `min(slot, remaining)` rounded up to 15 min. The block is labelled with the phase it lands in. A phase boundary inside a block gets the first phase's name plus "+".

### Outputs
- New `[Block]` (planned)
- Per-idea **forecast**: the projected finish date, or "beyond horizon" with an extrapolation from the weekly budget.
- **Warnings:** deadline at risk; idea starved (no slot in horizon); budget unused because windows are too small.

### Invariants (tested)
No two blocks overlap. No block overlaps a busy interval. Every block is inside a build window. Weekly budget and blocks per day are never exceeded. Locked/done/past blocks are byte-identical before and after re-plan. Same input → same output. The focus limit holds. No block lands after its idea's deadline.

---

## 4 Screens (Metro Station adaptation)

Material roles follow the design system exactly. The environment is near-black blue-green with a faint grid. Quiet content panels hold lists and text. One opaque metal instrument appears per screen at most. Native Liquid Glass is used only for controls, the tab bar, the jot bar and the dial's isolated lens.

**Semantic colour (paired with text and position, never alone):**
- **Cyan** = build time (your blocks, active controls).
- **Amber** = now / events that need you (the current-time index, a block that is boarding, nudges due).
- **Violet** = the second channel: your existing Apple Calendar commitments (busy time).

### 4.1 Station (Today)

```
┌──────────────────────────────────────────┐
│ Boss Calendar            BOARD · TODAY ⚙ │  header: 27 pt rounded title + mono subtitle
│                                          │
│ ┃LOAD┃   ╭──── metal dial ────╮  ┃QUEUE┃ │  vertical signal pills
│ ┃ M ▬┃   │ 24 h calibration    │  ┃ ▮▮▮ ┃ │
│ ┃ T ▬┃   │ violet = busy arcs  │  ┃ ▮▮  ┃ │
│ ┃ W  ┃   │ cyan   = blocks     │  ┃ ▮   ┃ │
│ ┃ …  ┃   │ amber  = now hand   │  ┃     ┃ │
│ ┃    ┃   │      1:45           │  ┃     ┃ │  hero: time until next block
│ ┃    ┃   │  UNTIL NEXT BLOCK   │  ┃     ┃ │  unit (mono)
│ ┃    ┃   │   Gyre · Field…     │  ┃     ┃ │  meaning (serif italic, cyan)
│          ╰─────────────────────╯         │
│   [ WEEKLY HOURS   12 h/wk   −  + ]      │  native Stepper → re-plans
│   Steady — 4 blocks booked this week     │  human meaning of the budget
│  IDEAS 6 │ QUEUED 41 h │ CLEARS 3.4 wk   │  telemetry row
│ ┌ CHECK IN ────────────────────────────┐ │  only when needed
│ │ Did you build Loom · Polish at 19:00?│ │
│ │ [Built it]  [Skipped]                │ │
│ └──────────────────────────────────────┘ │
│ ┌ DEPARTURES ──────────────────────────┐ │  next blocks, departures-board style
│ │ 19:00  Gyre       Field lines  BOARDING│
│ │ 21:00  Cipher     Prototype    ON TIME │
│ │ THU    Spectra    Blueprint    ON TIME │
│ └──────────────────────────────────────┘ │
│ ┌ NUDGES DUE ──────────────────────────┐ │
│ └──────────────────────────────────────┘ │
│  ( Jot it down…                       ＋) │  glass bottom accessory
│  [Station] [Board] [Depot] [Nudges]      │  native glass tab bar
└──────────────────────────────────────────┘
```

**Primary object: the Day Dial.** It is a 24-hour metal instrument. Midnight is at the top and hours run clockwise. Calibration is major every 3 h and minor every hour.
- Violet arcs on the outer track show busy calendar time.
- Cyan arcs on the inner track show build blocks: solid when done, outlined when planned, dim when skipped.
- An amber index shows the current time.

The native clear-glass lens sits centred at constant opacity. A faint rim reflection follows the phone's tilt. The face is not distorted near the text. The lens does not bounce, because a calendar has no beat. The readout is anchored (spec §8 coordinates) and is never filtered:

| State | Hero | Unit | Meaning |
| --- | --- | --- | --- |
| In a block | `0:48` left | `LEFT IN BLOCK` | idea · phase |
| Block later today | `1:45` | `UNTIL NEXT BLOCK` | idea · phase |
| Next block another day | `Thu` | `NEXT BLOCK 19:00` | idea · phase |
| Nothing booked | `0` | `BLOCKS BOOKED` | *Jot an idea* |

Phase metadata row: `BLOCK 1 OF 2 TODAY · 3 h BUILD`.

**Pills.** Both are honest data channels with stable outlines; their interiors change only when data changes.
- **LOAD** (left) shows this week's booked build hours per day, Mon at the top to Sun at the bottom. The bar length is hours ÷ the day's window hours.
- **QUEUE** (right) shows the remaining hours of the top queued ideas, stacked upward by score.

**Weekly-hours Stepper.** This is the one knob on the home screen: "how hard is the Boss pushing you." Integer hours from 1 to 60, using native held repeat, outside any timeline. Its meaning bands are 1–5 *Side quest*, 6–12 *Steady*, 13–20 *Crunch* and 21+ *Founder mode*.

### 4.2 Board (week calendar)
- A seven-day strip of **day tiles** (Metro beat-tile grammar, 37 pt). Each shows the date and a capsule meter of booked build hours. The selected tile is cyan.
- The day timeline runs 06:00–24:00 at 56 pt per hour, with an hour grid and an amber now-line.
- Calendar events appear as violet-edged quiet slabs with a "BUSY" label. Build windows show as a faint cyan wash. Blocks are cyan-bordered panels with the idea, phase, time and a lock glyph. Nudges appear as amber ticks.
- **Block sheet** (tap a block): idea, phase and time. A time stepper nudges ±15 min, and the planner validates the move. Other actions are **Lock/Unlock**, **Built it**, **Skip** and **Open idea**.
- A toolbar **Re-plan** button forces a run and shows a one-line diff: "Moved 2 blocks, added 1".

### 4.3 Depot (ideas & notes)
- Ideas are grouped *Building now* (has a block this week), *Queued*, *Notes*, *Paused* and *Shipped*.
- Each row shows the title, a heat meter (5 pips), remaining/planned hours, a progress capsule and the next departure ("Thu 19:00") or a forecast ("~Nov 4").
- **Idea detail** is a note editor: title, body (`TextEditor`) and a Track picker (Build / Note / Paused / Shipped).
  - **HEAT** and **DEADLINE** controls.
  - **Phases**, each with a title and hours stepper, plus add, delete and reorder.
  - A **Shape with Apple Intelligence** button, showing the "Template" fallback label when unavailable.
  - The idea's blocks and its forecast.

### 4.4 Nudges (reminders)
- Sections: *Overdue* (amber), *Today*, *Upcoming*, *Done*.
- Each nudge can link to an idea. Swipe to complete or delete.
- Local notifications have **Done** and **Snooze 15 min** actions.

### 4.5 Settings (sheet from Station ⚙)
- Build windows per weekday: add, delete and edit start/end times.
- Planner: block length (30–180 in 15-min steps), max blocks per day, focus limit, freeze horizon, buffer around events.
- Apple Calendar busy-time toggle and permission state.
- Notifications toggle and lead time.
- Reset demo data.

---

## 5 Architecture

```
Boss Calendar/
  project.yml                XcodeGen; iOS 27; Swift 6; bundle com.utkarsh.bosscalendar
  Tools/build.sh             mirrors to $TMPDIR (xcodebuild hangs on iCloud Drive) → sim | device | test
  Tools/plannercheck/        swiftc harness: Planner invariants on macOS in < 2 s
  BossCore/                  framework — pure Swift, no UI
    Models.swift             Idea, Phase, Block, Nudge, BuildWindow, PlannerSettings, BossState
    Planner.swift            Autopilot
    TimeMath.swift           interval algebra (subtract, clip, slot cutting), ISO week keys
    Sizing.swift             T-shirt templates, heat/budget meanings, formatting
    NaturalDate.swift        NSDataDetector wrapper for nudges
  BossCoreTests/             XCTest over the planner invariants
  App/
    BossCalendarApp.swift    scene, lifecycle → replan on foreground
    Store/BossStore.swift    @Observable owner, persistence, replan orchestration
    Services/CalendarBridge  EventKit read-only busy intervals
    Services/NotificationScheduler  UNUserNotificationCenter, categories, actions
    Services/IdeaShaper      shared offline MLX + validated Codable phase proposal
    Services/TiltService     CoreMotion gravity → filtered screen-space tilt (Metro §13)
    Intents/JotIdeaIntent    App Intent + AppShortcutsProvider
    Design/                  Metro Station starter (palette, panel, stepper, lens, touch bridge, shader)
    Views/Station/…  Views/Board/…  Views/Depot/…  Views/Nudges/…  Views/Jot/…  Views/Settings/…
```

**Concurrency.** The store and views are `@MainActor`. The planner is `nonisolated` and pure, and runs synchronously: it takes under 5 ms for hundreds of ideas over 21 days. EventKit fetches happen off the main actor and return `Sendable` intervals.

**Persistence.** JSON is written with a debounce of about 0.4 s plus a write on background. Saves go through a temp file and an atomic replace. `schemaVersion` is kept for future migration.

**Permissions.**
- Calendars full access is used only to read busy times (`NSCalendarsFullAccessUsageDescription`).
- Notifications are requested on the first planned block.
- Motion is used for the decorative tilt light only.

---

## 6 Scope

**v1.0 (this build)**
- All four tabs, plus the jot bar, settings, Autopilot, Apple Calendar busy-read, block and nudge notifications with actions, Shape (AI plus template fallback), the Jot App Intent, the Day Dial with tilt optics, and demo data on first launch.
- Planner harness and XCTest coverage.

**v1.1 candidates**
- Mirror blocks into a "Boss Calendar" calendar in Apple Calendar (write access).
- A home/lock-screen widget with the next departure, and a Live Activity during a block.
- A Control Center "Jot" control.
- Drag-to-move on the Board.
- Energy-aware windows (morning vs night ideas).
- Learning your real block length from check-ins.
- An Apple Watch "Did you build?" check-in.

**Explicit non-goals**
- Accounts, sync servers and collaboration.
- AI in the scheduling decision itself. The planner must stay explainable and deterministic.

---

## 7 Acceptance checks

| Check | How |
| --- | --- |
| Planner invariants | `Tools/plannercheck/run.sh` and `BossCoreTests` |
| Jot → block in ≤ 2 taps | Simulator: jot "Test idea" → Station departures shows a block |
| Re-plan stability | Re-planning twice with no change → identical blocks |
| Lock respected | Lock a block, change budget → block unchanged |
| Calendar collision | Add a busy event over a frozen block → block moves |
| Check-in credit | Built it → phase done minutes increase, remaining decreases |
| Metro contracts | Readout fixed under tilt; constant lens opacity; Reduce Motion/Transparency fallbacks; held Stepper repeat |
| Accessibility | VoiceOver labels on the dial, pills, tiles and blocks; Dynamic Type XXL reflows |
| Device | Release build installed on iPhone 15 Pro Max |
