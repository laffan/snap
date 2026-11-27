//
//  ColorWheel.swift
//  Snap
//
//  One of the colour-grading wheels: hue around the rim, saturation out from
//  the middle, and a puck that is both.
//
//  The puck follows the finger by how far it moves, not to where it lands, so
//  a small tint can be set without a thumb over it. Double-tap the wheel to
//  take the tint off.
//

import SwiftUI
import UIKit

struct ColorWheel: View {

    /// Degrees, 0..<360, clockwise from the right.
    @Binding var hue: Float
    /// 0...100, from the middle out to the rim.
    @Binding var saturation: Float
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var grab: (puck: CGPoint, touch: CGPoint)? = nil

    // Explicit because the private state above would otherwise make the
    // memberwise initializer private.
    init(hue: Binding<Float>,
         saturation: Binding<Float>,
         onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self._hue = hue
        self._saturation = saturation
        self.onEditingChanged = onEditingChanged
    }

    private static let rim: [Color] = stride(from: 0, through: 360, by: 30).map {
        Color(hue: Double($0).truncatingRemainder(dividingBy: 360) / 360, saturation: 0.85, brightness: 0.95)
    }

    var body: some View {
        GeometryReader { proxy in
            let diameter = min(proxy.size.width, proxy.size.height)
            let radius = diameter / 2
            let puck = puckOffset(radius: radius)

            ZStack {
                Circle()
                    .fill(AngularGradient(colors: ColorWheel.rim, center: .center))
                Circle()
                    .fill(RadialGradient(colors: [Color(white: 0.5), Color(white: 0.5).opacity(0)],
                                         center: .center, startRadius: 0, endRadius: radius))
                Circle()
                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)

                // Crosshair at the middle, where no tint is.
                Path { path in
                    path.move(to: CGPoint(x: radius - 5, y: radius))
                    path.addLine(to: CGPoint(x: radius + 5, y: radius))
                    path.move(to: CGPoint(x: radius, y: radius - 5))
                    path.addLine(to: CGPoint(x: radius, y: radius + 5))
                }
                .stroke(Color.black.opacity(0.35), lineWidth: 1)

                Circle()
                    .fill(puckColor)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .offset(x: puck.x, y: puck.y)
            }
            .frame(width: diameter, height: diameter)
            .overlay {
                DragSurface(onBegan: { touch, _ in began(touch, radius: radius) },
                            onChanged: { touch, _ in moved(touch, radius: radius) },
                            onEnded: ended,
                            onDoubleTap: { _, _ in reset() })
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Color wheel")
        .accessibilityValue("Hue \(Int(hue.rounded())), saturation \(Int(saturation.rounded()))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: saturation = min(saturation + 5, 100)
            case .decrement: saturation = max(saturation - 5, 0)
            @unknown default: break
            }
            onEditingChanged(false)
        }
    }

    private var puckColor: Color {
        Color(hue: Double(hue) / 360,
              saturation: Double(saturation) / 100 * 0.85,
              brightness: 0.95)
    }

    /// The puck's offset from the centre, y down.
    private func puckOffset(radius: CGFloat) -> CGPoint {
        let angle = CGFloat(hue) * .pi / 180
        let distance = CGFloat(min(max(saturation, 0), 100) / 100) * radius
        return CGPoint(x: cos(angle) * distance, y: sin(angle) * distance)
    }

    private func began(_ touch: CGPoint, radius: CGFloat) {
        grab = (puckOffset(radius: radius), touch)
        onEditingChanged(true)
    }

    private func moved(_ touch: CGPoint, radius: CGFloat) {
        guard let grab, radius > 0 else { return }
        let x = grab.puck.x + (touch.x - grab.touch.x)
        let y = grab.puck.y + (touch.y - grab.touch.y)
        let distance = min(hypot(x, y), radius)

        saturation = Float((distance / radius * 100).rounded())
        if distance > 0.5 {
            var degrees = Float(atan2(y, x) * 180 / .pi)
            if degrees < 0 { degrees += 360 }
            hue = degrees.rounded()
        }
    }

    private func ended() {
        guard grab != nil else { return }
        grab = nil
        onEditingChanged(false)
    }

    private func reset() {
        saturation = 0
        onEditingChanged(false)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
