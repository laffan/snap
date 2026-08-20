//
//  ExposureStepper.swift
//  Snap
//
//  Exposure compensation, stacked beside the shutter.
//
//  The same value the panel's Exposure slider moves — this is just the fast
//  way to reach it, in whole stops.
//

import SwiftUI
import UIKit

struct ExposureStepper: View {

    @Binding var value: Float
    var range: ClosedRange<Float>

    private var label: String {
        guard abs(value) >= 0.05 else { return "0" }
        // Whole stops read as "+1"; anything the slider left in between keeps
        // a decimal so the two controls never disagree about the value.
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(format: "%+.0f", rounded)
            : String(format: "%+.1f", rounded)
    }

    var body: some View {
        VStack(spacing: 4) {
            step("plus", enabled: value < range.upperBound) {
                value = min(range.upperBound, value.rounded(.down) + 1)
            }

            // Holding the number between the two steps clears it. Stepping
            // back to zero from five stops out is nine taps; this is one, and
            // it lands on the same value the panel's slider reads.
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

            step("minus", enabled: value > range.lowerBound) {
                value = max(range.lowerBound, value.rounded(.up) - 1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Exposure compensation")
        .accessibilityValue(label == "0" ? "zero" : label)
        .accessibilityAction(named: "Reset to zero") { value = 0 }
    }

    private func step(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
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
        ExposureStepper(value: .constant(-2), range: -5...5)
    }
}
