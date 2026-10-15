import BossCore
import SwiftUI

/// What the dial shows, prepared by the Station from store state (the dial itself owns no domain logic).
struct DaySnapshot: Equatable {
    struct Arc: Equatable {
        var startMinute: Double
        var endMinute: Double
        var kind: Kind
        enum Kind: Equatable { case window, busy, planned, done, skipped, highlighted }
    }

    var nowMinute: Double
    var arcs: [Arc]
    var value: String
    var unit: String
    var meaning: String?
    var metadata: String
    var spoken: String
}

/// The Station's primary object: a 24-hour metal instrument for today (midnight at top, clockwise).
/// Layers follow Metro Station §7: housing → decorative Canvas (filtered) → native clear lens → rim light → readout.
struct DayDial: View {
    let snapshot: DaySnapshot
    let tilt: SIMD2<Double>
    let motionActive: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicType
    @ScaledMetric(relativeTo: .caption2) private var metadataSize = 11.0

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            ZStack {
                housing(d)
                InstrumentLensSurface(diameter: d, radiusScale: 1, filteredTilt: tilt, motionActive: motionActive) {
                    Canvas { context, size in
                        draw(&context, d: min(size.width, size.height))
                    }
                } readout: {
                    ZStack {
                        InstrumentLargeReadout(diameter: d, value: snapshot.value, unit: snapshot.unit,
                                               meaning: snapshot.meaning, spokenLabel: "Today")
                        if !dynamicType.isAccessibilitySize {
                            HStack(spacing: 5) {
                                Circle().fill(BossPalette.now).frame(width: 3, height: 3)
                                Text(snapshot.metadata)
                                    .font(.system(size: metadataSize, weight: .regular, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundStyle(.white.opacity(0.68))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                            .frame(width: d * 0.62)
                            .position(x: d / 2, y: d * 0.835)
                        }
                    }
                }
            }
            .frame(width: d, height: d)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Today")
        .accessibilityValue(snapshot.spoken)
    }

    // Opaque metal housing (spec §6 metal recipe).
    private func housing(_ d: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(BossPalette.housing)
                .shadow(color: .black.opacity(0.8), radius: 22, y: 16)
                .overlay {
                    Circle().strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.36), .white.opacity(0.025), .black, .white.opacity(0.15)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1.4)
                }
            Circle()
                .inset(by: d * 0.038)
                .fill(LinearGradient(colors: [BossPalette.metalLight, BossPalette.metalDark],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay { Circle().inset(by: d * 0.038).strokeBorder(.white.opacity(0.07), lineWidth: 0.6) }
            if !reduceTransparency {
                let lx = reduceMotion ? 0 : tilt.x, ly = reduceMotion ? 0 : tilt.y
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.07), BossPalette.build.opacity(0.015), .clear],
                                         center: UnitPoint(x: 0.28 + lx * 0.25, y: 0.10 + ly * 0.25),
                                         startRadius: 0, endRadius: d * 0.85))
            }
        }
        .frame(width: d, height: d)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func angle(_ minute: Double) -> Angle {
        .degrees(minute / 1440 * 360 - 90)
    }

    private func point(_ c: CGPoint, _ r: CGFloat, _ minute: Double) -> CGPoint {
        let a = angle(minute).radians
        return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
    }

    private func arc(_ c: CGPoint, _ r: CGFloat, _ a: Double, _ b: Double) -> Path {
        Path { p in p.addArc(center: c, radius: r, startAngle: angle(a), endAngle: angle(max(a + 1, b)), clockwise: false) }
    }

    private func draw(_ ctx: inout GraphicsContext, d: CGFloat) {
        let c = CGPoint(x: d / 2, y: d / 2)
        let buildR = d * 0.345, buildW = d * 0.03
        let busyR = d * 0.405, busyW = d * 0.012

        // Calibration: quarter, hour and 3-hour marks; numerals at 00/06/12/18.
        for q in 0..<96 {
            let minute = Double(q) * 15
            let major = q % 12 == 0, hour = q % 4 == 0
            if q % 24 == 0 { continue }
            let outer = d * 0.445
            let inner = outer - d * (major ? 0.04 : hour ? 0.024 : 0.011)
            var tick = Path()
            tick.move(to: point(c, inner, minute))
            tick.addLine(to: point(c, outer, minute))
            ctx.stroke(tick, with: .color(.white.opacity(major ? 0.55 : hour ? 0.30 : 0.11)),
                       lineWidth: major ? 1.3 : hour ? 0.9 : 0.6)
        }
        for (label, minute) in [("00", 0.0), ("06", 360.0), ("12", 720.0), ("18", 1080.0)] {
            let text = Text(label).font(.system(size: max(8, d * 0.03), weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
            ctx.draw(text, at: point(c, d * 0.432, minute))
        }

        // Elapsed part of the day: a whisper of a track so "now" reads as progress.
        ctx.stroke(arc(c, buildR, 0, snapshot.nowMinute), with: .color(.white.opacity(0.035)),
                   style: StrokeStyle(lineWidth: buildW, lineCap: .butt))

        for a in snapshot.arcs {
            switch a.kind {
            case .window:
                ctx.stroke(arc(c, buildR, a.startMinute, a.endMinute), with: .color(BossPalette.build.opacity(0.10)),
                           style: StrokeStyle(lineWidth: buildW, lineCap: .butt))
            case .busy:
                ctx.stroke(arc(c, busyR, a.startMinute, a.endMinute), with: .color(BossPalette.busy.opacity(0.8)),
                           style: StrokeStyle(lineWidth: busyW, lineCap: .butt))
            case .planned, .highlighted:
                let path = arc(c, buildR, a.startMinute, a.endMinute)
                ctx.stroke(path, with: .color(BossPalette.build.opacity(a.kind == .highlighted ? 0.95 : 0.55)),
                           style: StrokeStyle(lineWidth: buildW * 0.82, lineCap: .butt))
                ctx.stroke(arc(c, buildR + buildW * 0.5, a.startMinute, a.endMinute),
                           with: .color(BossPalette.build.opacity(0.9)), lineWidth: 0.8)
            case .done:
                ctx.stroke(arc(c, buildR, a.startMinute, a.endMinute), with: .color(BossPalette.build),
                           style: StrokeStyle(lineWidth: buildW, lineCap: .butt))
            case .skipped:
                ctx.stroke(arc(c, buildR, a.startMinute, a.endMinute), with: .color(.white.opacity(0.14)),
                           style: StrokeStyle(lineWidth: buildW * 0.5, lineCap: .butt, dash: [2, 2]))
            }
        }

        // Amber index for the current time.
        var needle = Path()
        needle.move(to: point(c, d * 0.29, snapshot.nowMinute))
        needle.addLine(to: point(c, d * 0.425, snapshot.nowMinute))
        ctx.stroke(needle, with: .color(BossPalette.now), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        let tip = point(c, d * 0.452, snapshot.nowMinute)
        let a = angle(snapshot.nowMinute).radians
        var tri = Path()
        tri.move(to: CGPoint(x: tip.x - cos(a) * 6, y: tip.y - sin(a) * 6))
        tri.addLine(to: CGPoint(x: tip.x + cos(a + .pi / 2) * 3.5, y: tip.y + sin(a + .pi / 2) * 3.5))
        tri.addLine(to: CGPoint(x: tip.x + cos(a - .pi / 2) * 3.5, y: tip.y + sin(a - .pi / 2) * 3.5))
        tri.closeSubpath()
        ctx.fill(tri, with: .color(BossPalette.now))
    }
}

/// Compact vertical signal channel (spec §11): static enclosure and labels, data-driven interior.
struct SignalPill<Trace: View>: View {
    let title: String
    let top: String
    let bottom: String
    let width: CGFloat
    let height: CGFloat
    let accent: Color
    let spoken: String
    @ViewBuilder var trace: Trace
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .caption2) private var titleSize = 10.0
    @ScaledMetric(relativeTo: .caption2) private var axisSize = 9.0

    var body: some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.system(size: titleSize, weight: .semibold, design: .monospaced))
                .foregroundStyle(accent)
            Text(top)
                .font(.system(size: axisSize, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
            trace.frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(bottom)
                .font(.system(size: axisSize, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .padding(.horizontal, 5)
        .padding(.vertical, 10)
        .frame(width: width, height: height)
        .background(
            LinearGradient(colors: [Color(red: 0.055, green: 0.069, blue: 0.095), Color(red: 0.014, green: 0.022, blue: 0.037)],
                           startPoint: .leading, endPoint: .trailing),
            in: .capsule)
        .overlay {
            Capsule().strokeBorder(
                LinearGradient(colors: [accent.opacity(contrast == .increased ? 0.70 : 0.36), .white.opacity(0.10),
                                        BossPalette.busy.opacity(0.38)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(spoken)
    }
}
