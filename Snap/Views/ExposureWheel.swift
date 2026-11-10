//
//  ExposureWheel.swift
//  Snap
//
//  Exposure compensation, at the right of the shutter row.
//
//  A dial whose centre is just past the edge of the screen, so all that shows
//  is a slice of its rim. Dragging up or down turns it, and whatever stop is
//  under the pointer is the compensation. It moves in thirds of a stop, the way
//  a camera's dial does, and clicks — a selection tick — as each one passes.
//
//  The stops are written on the wheel itself, so the reach either side of the
//  current setting is in view without pressing anything. Up is more light:
//  dragging up brings the stops below the pointer up to it, so they ascend
//  downward, the way the numbers on any iOS wheel do.
//

import SwiftUI
import UIKit

struct ExposureWheel: View {

    @Binding var value: Float
    var range: ClosedRange<Float>
    /// The detent, in stops.
    var step: Float = 1.0 / 3

    /// Where the wheel stands while a finger is on it. Continuous, so the rim
    /// follows the finger rather than jumping a third at a time; let go and it
    /// settles on the nearest detent, which `value` is already holding.
    @State private var turning: Float? = nil
    /// `value` when the drag began. A drag reports its translation from where
    /// the finger went down, so this is what that translation is added to.
    @State private var turnStart: Float? = nil
    @State private var detent = UISelectionFeedbackGenerator()

    /// The wheel's radius. Big enough that the slice on screen is a gentle
    /// curve rather than a knob, small enough that it still reads as round.
    static let radius: CGFloat = 110
    /// How far the wheel turns for one stop. Twenty degrees on this radius puts
    /// about a stop and a half either side of the pointer in view.
    static let degreesPerStop: Double = 20
    /// The same turn as distance along the rim, which is what a finger
    /// dragging over it covers.
    static var pointsPerStop: CGFloat {
        radius * CGFloat(degreesPerStop * .pi / 180)
    }

    /// The height of the row it sits in, which is the exposure column's.
    static let height: CGFloat = CameraView.controlCellHeight * 4
    /// The slice of the wheel that is on screen.
    static let faceWidth: CGFloat = 56
    /// The exact setting, to the left of the pointer.
    static let readoutWidth: CGFloat = 28

    var body: some View {
        HStack(spacing: 0) {
            Text(ExposureWheel.label(value))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(value == 0 ? .white.opacity(0.45) : .white)
                .lineLimit(1)
                .frame(width: ExposureWheel.readoutWidth, alignment: .trailing)
                .padding(.trailing, 2)

            ExposureWheelFace(position: Double(turning ?? value),
                              range: range,
                              step: step,
                              isSet: value != 0)
                .frame(width: ExposureWheel.faceWidth, height: ExposureWheel.height)
        }
        .frame(height: ExposureWheel.height)
        .contentShape(Rectangle())
        .gesture(turn)
        // Double-tapping a slider puts it back to zero everywhere else in the
        // app; the wheel is the same kind of control.
        .onTapGesture(count: 2) { reset() }
        .accessibilityElement()
        .accessibilityLabel("Exposure compensation")
        .accessibilityValue(ExposureWheel.label(value) == "0" ? "zero" : ExposureWheel.label(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(by: 1)
            case .decrement: nudge(by: -1)
            @unknown default: break
            }
        }
        .accessibilityAction(named: "Reset to zero") { value = 0 }
    }

    // MARK: - Turning

    private var turn: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { drag in
                let start = turnStart ?? value
                if turnStart == nil {
                    turnStart = start
                    detent.prepare()
                }

                // Up is negative in screen space and positive in stops.
                let raw = start - Float(drag.translation.height / ExposureWheel.pointsPerStop)
                let position = min(max(raw, range.lowerBound), range.upperBound)
                turning = position

                // The camera follows the detents, not the finger: a third of a
                // stop is the finest thing it is asked for, and the meter only
                // moves when one is crossed.
                let snapped = snap(position)
                if snapped != value {
                    value = snapped
                    detent.selectionChanged()
                    detent.prepare()
                }
            }
            .onEnded { _ in
                turnStart = nil
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                    turning = nil
                }
            }
    }

    private func snap(_ position: Float) -> Float {
        let snapped = (position / step).rounded() * step
        return min(max(snapped, range.lowerBound), range.upperBound)
    }

    private func nudge(by detents: Float) {
        value = snap(value + detents * step)
    }

    private func reset() {
        guard value != 0 else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            value = 0
        }
    }

    /// Whole stops read as "+1", and a third as "+0.3" — a decimal only where
    /// there is one to show.
    static func label(_ value: Float) -> String {
        guard abs(value) >= 0.05 else { return "0" }
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(format: "%+.0f", rounded)
            : String(format: "%+.1f", rounded)
    }
}

/// The slice of the wheel itself: the rim, a tick per third, a number per
/// stop, and the pointer that stays put while all of it turns past.
///
/// Animatable on its position, so letting go eases the rim onto its detent
/// rather than snapping it there.
private struct ExposureWheelFace: View, Animatable {

    /// The stop under the pointer. Fractional while a finger is turning it.
    var position: Double
    let range: ClosedRange<Float>
    let step: Float
    /// True while the compensation is anything but zero, which is when the
    /// pointer takes the accent: it is a setting that changes the photograph.
    let isSet: Bool

    var animatableData: Double {
        get { position }
        set { position = newValue }
    }

    /// Where the rim crosses the pointer, from the slice's leading edge. The
    /// pointer sits in the gap before it.
    private static let rimInset: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
        // The rim curves away out of sight at the top and the bottom, and the
        // fade is what makes it read as the side of something round rather
        // than a bent ruler.
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0),
                                   .init(color: .black, location: 0.24),
                                   .init(color: .black, location: 0.76),
                                   .init(color: .clear, location: 1)],
                           startPoint: .top,
                           endPoint: .bottom)
        }
        .allowsHitTesting(false)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let radius = ExposureWheel.radius
        let middle = size.height / 2
        let center = CGPoint(x: Self.rimInset + radius, y: middle)
        let perStop = ExposureWheel.degreesPerStop * .pi / 180
        // As far round as the slice shows, plus a little so nothing pops in at
        // the very edge.
        let reach = asin(min(1, Double(middle + 8) / Double(radius)))

        /// A point on the wheel, `angle` from the pointer — positive is down —
        /// and `inset` in from the rim towards the centre.
        func point(_ angle: Double, inset: CGFloat = 0) -> CGPoint {
            let r = radius - inset
            return CGPoint(x: center.x - r * CGFloat(cos(angle)),
                           y: center.y + r * CGFloat(sin(angle)))
        }

        // The face and its rim.
        var rim = Path()
        let samples = 32
        for index in 0...samples {
            let angle = -reach + 2 * reach * Double(index) / Double(samples)
            if index == 0 {
                rim.move(to: point(angle))
            } else {
                rim.addLine(to: point(angle))
            }
        }
        var face = rim
        face.addLine(to: CGPoint(x: size.width, y: point(reach).y))
        face.addLine(to: CGPoint(x: size.width, y: point(-reach).y))
        face.closeSubpath()
        context.fill(face, with: .color(.white.opacity(0.06)))
        context.stroke(rim, with: .color(.white.opacity(0.3)), lineWidth: 1)

        // A tick per detent, longer on the whole stops, and the whole stops
        // numbered. Laid along the radius, so they turn with the wheel.
        let detents = Int(((range.upperBound - range.lowerBound) / step).rounded())
        for index in 0...detents {
            let stop = Double(range.lowerBound) + Double(index) * Double(step)
            let angle = (stop - position) * perStop
            guard abs(angle) <= reach else { continue }

            let isWhole = abs(stop - stop.rounded()) < 0.01
            let isUnderPointer = abs(stop - position) < Double(step) / 2
            let length: CGFloat = isWhole ? 9 : 5

            var tick = Path()
            tick.move(to: point(angle))
            tick.addLine(to: point(angle, inset: length))
            let tickColor: Color = isUnderPointer
                ? (isSet ? .snapAccent : .white)
                : .white.opacity(isWhole ? 0.7 : 0.4)
            context.stroke(tick, with: .color(tickColor), lineWidth: isWhole ? 1.2 : 0.8)

            guard isWhole else { continue }
            let whole = Int(stop.rounded())
            let number = Text(whole > 0 ? "+\(whole)" : "\(whole)")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(isUnderPointer ? 0.95 : 0.55))

            var label = context
            let at = point(angle, inset: length + 10)
            label.translateBy(x: at.x, y: at.y)
            // Along the radius: level at the pointer, tipping as it turns away.
            label.rotate(by: .radians(-angle))
            label.draw(number, at: .zero, anchor: .center)
        }

        // The pointer, which does not move.
        var pointer = Path()
        pointer.move(to: CGPoint(x: Self.rimInset - 1.5, y: middle))
        pointer.addLine(to: CGPoint(x: 1, y: middle - 4))
        pointer.addLine(to: CGPoint(x: 1, y: middle + 4))
        pointer.closeSubpath()
        context.fill(pointer, with: .color(isSet ? .snapAccent : .white.opacity(0.85)))
    }
}

#Preview {
    struct Wrapper: View {
        @State private var value: Float = -1.0 / 3
        var body: some View {
            ZStack(alignment: .trailing) {
                Color.black.ignoresSafeArea()
                ExposureWheel(value: $value, range: -3...3)
            }
        }
    }
    return Wrapper()
}
