//
//  ExposureStepper.swift
//  Snap
//
//  Exposure compensation, stacked beside the shutter.
//
//  This moves the camera's own exposure target bias, not a develop setting —
//  it changes what the sensor records, so it is baked into the negative rather
//  than applied to it afterwards.
//

import SwiftUI

struct ExposureStepper: View {

    @Binding var value: Int
    var range: ClosedRange<Int>

    private var label: String {
        switch value {
        case 0:          return "0"
        case let v where v > 0: return "+\(v)"
        default:         return "\u{2212}\(abs(value))"
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            step("plus", enabled: value < range.upperBound) {
                value = min(range.upperBound, value + 1)
            }

            Text(label)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(value == 0 ? .white.opacity(0.45) : .white)
                .frame(minWidth: 26)

            step("minus", enabled: value > range.lowerBound) {
                value = max(range.lowerBound, value - 1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Exposure compensation")
        .accessibilityValue(label == "0" ? "zero" : label)
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
        ExposureStepper(value: .constant(-2), range: -8...8)
    }
}
