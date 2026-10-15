import BossCore
import SwiftUI

/// Boss Calendar's semantic mapping onto the Metro Station palette.
/// Cyan = build time · Amber = now / needs you · Violet = Apple Calendar busy time.
enum BossPalette {
    static let build = InstrumentPalette.instrumentCyan
    static let buildDepth = InstrumentPalette.waveDepth
    static let now = InstrumentPalette.instrumentAmber
    static let busy = InstrumentPalette.spectrum
    static let busyDepth = InstrumentPalette.spectrumDepth
    static let ink = InstrumentPalette.displayInk
    static let secondary = InstrumentPalette.secondaryInk
    static let panel = InstrumentPalette.content
    static let plot = Color(red: 0.022, green: 0.036, blue: 0.047)
    static let housing = Color(red: 0.027, green: 0.041, blue: 0.055)
    static let metalLight = Color(red: 0.055, green: 0.073, blue: 0.090)
    static let metalDark = Color(red: 0.021, green: 0.032, blue: 0.042)
    static let warning = Color(red: 1.0, green: 0.42, blue: 0.36)
}

enum Fmt {
    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    static func weekday(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated)).uppercased()
    }

    /// "19:00", "Tomorrow 19:00", "Thu 19:00", "Oct 30 19:00".
    static func departure(_ date: Date, now: Date = .now) -> String {
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return time(date) }
        if cal.isDateInTomorrow(date) { return "Tomorrow \(time(date))" }
        if date < now.addingTimeInterval(6 * 86_400) && date > now {
            return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time(date))"
        }
        return "\(date.formatted(.dateTime.month(.abbreviated).day())) \(time(date))"
    }

    /// Board-style short label: "19:00" today, else "THU".
    static func boardTime(_ date: Date, now: Date = .now) -> String {
        Calendar.current.isDate(date, inSameDayAs: now) ? time(date) : weekday(date)
    }

    static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func relative(_ date: Date, now: Date = .now) -> String {
        date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}

// MARK: - Shared components

struct SectionLabel: View {
    let text: String
    var color: Color = BossPalette.build
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text)
                .font(.system(.caption, design: .monospaced, weight: .medium))
                .tracking(1.8)
                .foregroundStyle(color)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(.caption2, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(BossPalette.secondary)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

struct HeatPips: View {
    let heat: Int
    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(1...5, id: \.self) { i in
                Capsule()
                    .fill(i <= heat ? BossPalette.now : .white.opacity(0.10))
                    .frame(width: 4, height: 10)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heat \(heat) of 5, \(BossMeaning.heat(heat))")
    }
}

struct ProgressCapsule: View {
    let progress: Double
    var color: Color = BossPalette.build
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.06))
                Capsule().fill(color.opacity(0.85))
                    .frame(width: max(progress > 0 ? 3 : 0, geo.size.width * min(1, max(0, progress))))
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

/// Glass action button with a sized label (Metro: size the label, then apply glass).
struct GlassActionButton: View {
    let title: String
    var symbol: String?
    var accent: Color = BossPalette.build
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 14, weight: .semibold)) }
                Text(title).font(.system(.subheadline, design: .rounded, weight: .semibold))
            }
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : accent)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .glassEffect(prominent ? .regular.tint(accent.opacity(0.85)).interactive()
                                   : .regular.tint(accent.opacity(0.08)).interactive(),
                         in: .capsule)
        }
        .buttonStyle(.plain)
        .instrumentControlOwnsTouches(identifier: "glassAction")
    }
}

/// Minute-based stepper in the Metro capsule grammar, with a domain formatter (spec §9: show the real value).
struct MinuteStepper: View {
    let label: String
    @Binding var minutes: Int
    var range: ClosedRange<Int>
    var step = 15
    var format: (Int) -> String = { BossFormat.hours(minutes: $0) }
    var onAccepted: (Int) -> Void = { _ in }
    @ScaledMetric(relativeTo: .caption2) private var labelSize = 11.0
    @ScaledMetric(relativeTo: .body) private var valueSize = 17.0

    var body: some View {
        Stepper {
            HStack(spacing: 10) {
                Text(label)
                    .font(.system(size: labelSize, weight: .medium, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(BossPalette.secondary)
                Text(format(minutes))
                    .font(.system(size: valueSize, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(InstrumentPalette.actionCyan)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        } onIncrement: {
            adjust(step)
        } onDecrement: {
            adjust(-step)
        }
        .frame(minHeight: InstrumentMetrics.stepperHeight)
        .padding(.horizontal, 14)
        .background(BossPalette.panel.opacity(0.85), in: .capsule)
        .overlay {
            Capsule().strokeBorder(InstrumentPalette.actionCyan.opacity(0.14), lineWidth: 1).allowsHitTesting(false)
        }
        .instrumentControlOwnsTouches(identifier: "minuteStepper")
        .accessibilityValue(BossFormat.spokenDuration(minutes: minutes))
    }

    private func adjust(_ delta: Int) {
        let next = min(range.upperBound, max(range.lowerBound, minutes + delta))
        guard next != minutes else { return }
        minutes = next
        onAccepted(next)
    }
}

struct ScreenHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                    .foregroundStyle(BossPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(2.2)
                    .foregroundStyle(BossPalette.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 8) { trailing }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }
}

extension View {
    /// Metro list styling: transparent list over the instrument environment.
    func bossListStyle() -> some View {
        scrollContentBackground(.hidden)
            .background { InstrumentDesignBackground() }
    }

    func bossRow() -> some View {
        listRowBackground(BossPalette.panel.opacity(0.85))
            .listRowSeparatorTint(.white.opacity(0.07))
    }
}
