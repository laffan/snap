//
//  ToneCurveEditor.swift
//  Snap
//
//  The point curve, drawn and dragged by hand, over the frame's own histogram.
//
//  Touch the curve anywhere and a point appears there, under the finger, and
//  follows it; touch near a point and it is that point that follows. Drag a
//  point out of the box, above or below, and it is gone — the way Lightroom's
//  is taken off its curve. Double-tap the box to put the curve straight again.
//
//  The point follows the finger by how far the finger moves rather than to
//  where it is, so a point can be nudged without the finger covering it.
//

import SwiftUI
import UIKit

struct ToneCurveEditor: View {

    @Binding var curve: PointCurve
    /// The colour the curve is drawn in: white for all three channels, the
    /// channel's own for one of them.
    var tint: Color = .white
    /// Drawn faintly behind the curve, so the tones it is moving can be seen.
    var histogram: [Float]? = nil
    var onEditingChanged: (Bool) -> Void = { _ in }

    /// The point being moved, and where it was when the finger came down.
    @State private var dragging: Int? = nil
    @State private var grab: (point: CurvePoint, touch: CGPoint)? = nil

    // Explicit because the private state above would otherwise make the
    // memberwise initializer private.
    init(curve: Binding<PointCurve>,
         tint: Color = .white,
         histogram: [Float]? = nil,
         onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self._curve = curve
        self.tint = tint
        self.histogram = histogram
        self.onEditingChanged = onEditingChanged
    }

    /// How close, in points, a touch has to land to a point to pick it up
    /// rather than make a new one.
    private static let reach: CGFloat = 22

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            Canvas { context, canvasSize in
                draw(in: &context, size: canvasSize)
            }
            .overlay {
                DragSurface(onBegan: began, onChanged: moved, onEnded: ended, onDoubleTap: { _, _ in reset() })
            }
            .frame(width: size.width, height: size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Tone curve")
        .accessibilityValue(curve.isIdentity ? "Straight" : "\(curve.points.count) points")
        .accessibilityHint("Drag to shape the curve. Double-tap to straighten it.")
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let box = CGRect(origin: .zero, size: size)

        // Histogram, faint, behind everything.
        if let histogram, histogram.count > 1 {
            let interior = histogram.dropFirst().dropLast()
            let peak = max(interior.max() ?? 0, 0.0001)
            var shape = Path()
            let step = size.width / CGFloat(histogram.count - 1)
            shape.move(to: CGPoint(x: 0, y: size.height))
            for (index, value) in histogram.enumerated() {
                let height = min(CGFloat(value / peak), 1) * size.height * 0.85
                shape.addLine(to: CGPoint(x: CGFloat(index) * step, y: size.height - height))
            }
            shape.addLine(to: CGPoint(x: size.width, y: size.height))
            shape.closeSubpath()
            context.fill(shape, with: .color(.white.opacity(0.07)))
        }

        // Quarter grid and the box.
        var grid = Path()
        for quarter in 1...3 {
            let x = size.width * CGFloat(quarter) / 4
            let y = size.height * CGFloat(quarter) / 4
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(grid, with: .color(.white.opacity(0.1)), lineWidth: 0.5)
        context.stroke(Path(box), with: .color(.white.opacity(0.18)), lineWidth: 1)

        // Where the curve would be if it did nothing.
        var diagonal = Path()
        diagonal.move(to: CGPoint(x: 0, y: size.height))
        diagonal.addLine(to: CGPoint(x: size.width, y: 0))
        context.stroke(diagonal, with: .color(.white.opacity(0.15)),
                       style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))

        // The curve.
        let samples = curve.sampled(count: 96)
        var line = Path()
        for (index, value) in samples.enumerated() {
            let point = CGPoint(x: size.width * CGFloat(index) / CGFloat(samples.count - 1),
                                y: size.height * (1 - CGFloat(value)))
            if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
        }
        context.stroke(line, with: .color(tint.opacity(0.9)), lineWidth: 1.5)

        // The points.
        for (index, point) in curve.points.enumerated() {
            let center = location(of: point, in: size)
            let radius: CGFloat = index == dragging ? 6 : 4
            let dot = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                             width: radius * 2, height: radius * 2))
            context.fill(dot, with: .color(index == dragging ? tint : .black))
            context.stroke(dot, with: .color(tint), lineWidth: 1.5)
        }
    }

    private func location(of point: CurvePoint, in size: CGSize) -> CGPoint {
        CGPoint(x: CGFloat(point.x) * size.width, y: (1 - CGFloat(point.y)) * size.height)
    }

    // MARK: - Touch

    private func began(_ touch: CGPoint, _ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        var points = curve.points.sorted { $0.x < $1.x }

        // The nearest point within reach, if there is one.
        let nearest = points.indices
            .map { ($0, hypot(location(of: points[$0], in: size).x - touch.x,
                              location(of: points[$0], in: size).y - touch.y)) }
            .min { $0.1 < $1.1 }

        if let nearest, nearest.1 <= ToneCurveEditor.reach {
            dragging = nearest.0
        } else {
            // A new point, on the curve at the finger's x — so the curve
            // doesn't move until the finger does.
            guard points.count < PointCurve.maximumPoints else { return }
            let x = Float(min(max(touch.x / size.width, 0), 1))
            guard let after = points.firstIndex(where: { $0.x > x }), after > 0 else { return }
            guard x - points[after - 1].x > 0.02, points[after].x - x > 0.02 else { return }
            points.insert(CurvePoint(x: x, y: curve.value(at: x)), at: after)
            dragging = after
        }

        curve.points = points
        if let dragging {
            grab = (curve.points[dragging], touch)
            onEditingChanged(true)
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    private func moved(_ touch: CGPoint, _ size: CGSize) {
        guard let index = dragging, let grab, size.width > 0, size.height > 0,
              index < curve.points.count else { return }

        let dx = Float((touch.x - grab.touch.x) / size.width)
        let dy = Float(-(touch.y - grab.touch.y) / size.height)
        var x = grab.point.x + dx
        let y = grab.point.y + dy

        let points = curve.points
        let isEnd = index == 0 || index == points.count - 1

        // Out of the box, above or below: an inner point is taken off.
        if !isEnd, y < -0.12 || y > 1.12 {
            curve.points.remove(at: index)
            dragging = nil
            self.grab = nil
            onEditingChanged(false)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        }

        // Kept between its neighbours, so the points stay in order.
        let lower = index > 0 ? points[index - 1].x + 0.01 : 0
        let upper = index < points.count - 1 ? points[index + 1].x - 0.01 : 1
        x = min(max(x, lower), upper)

        curve.points[index] = CurvePoint(x: x, y: min(max(y, 0), 1))
    }

    private func ended() {
        let wasDragging = dragging != nil || grab != nil
        dragging = nil
        grab = nil
        if wasDragging { onEditingChanged(false) }
    }

    private func reset() {
        guard !curve.isIdentity || curve.points.count != 2 else { return }
        curve.points = PointCurve.identityPoints
        dragging = nil
        grab = nil
        onEditingChanged(false)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
