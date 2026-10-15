//
//  ExposureStepper.swift
//  Snap
//
//  Exposure compensation, stacked beside the shutter.
//
//  A stepper over whatever value it is handed. Beside the shutter that is the
//  camera's own compensation, in thirds of a stop the way a camera's dial
//  moves.
//

import SwiftUI
import UIKit

struct ExposureStepper: View {

    @Binding var value: Float
    var range: ClosedRange<Float>
    /// How far one press moves it, in stops.
    var step: Float = 1

    private var label: String {
        guard abs(value) >= 0.05 else { return "0" }
        // Whole stops read as "+1", and a third as "+0.3" — a decimal only
        // where there is one to show.
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(format: "%+.0f", rounded)
            : String(format: "%+.1f", rounded)
    }

    var body: some View {
        VStack(spacing: 4) {
            stepButton("plus", enabled: value < range.upperBound) {
                // Snapped to the step, so a value left between two stops
                // lands on the next one rather than carrying its remainder.
                let next = ((value / step + 0.001).rounded(.down) + 1) * step
                value = min(range.upperBound, next)
            }

            // Holding the number between the two steps clears it. Stepping
            // back to zero from three stops out is nine taps; this is one.
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(value == 0 ? .white.opacity(0.45) : .white)
                .frame(minWidth: 26, minHeight: 24)
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.5) {
                    guard value != 0 else { return }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    value = 0
                }

            stepButton("minus", enabled: value > range.lowerBound) {
                let next = ((value / step - 0.001).rounded(.up) - 1) * step
                value = max(range.lowerBound, next)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Exposure compensation")
        .accessibilityValue(label == "0" ? "zero" : label)
        .accessibilityAction(named: "Reset to zero") { value = 0 }
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(enabled ? 0.8 : 0.25))
                .frame(width: 34, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        ExposureStepper(value: .constant(-2), range: -3...3, step: 1.0 / 3)
    }
}
