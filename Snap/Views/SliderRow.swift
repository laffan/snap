//
//  SliderRow.swift
//  Snap
//

import SwiftUI

/// One labelled slider. Compact enough that a Lightroom-sized panel of them
/// still fits in half a phone screen.
struct SliderRow: View {

    let label: String
    @Binding var value: Float
    var range: ClosedRange<Float> = -100...100
    var decimals: Int = 0
    /// Value the double-tap reset returns to.
    var neutral: Float = 0
    var onEditingChanged: (Bool) -> Void = { _ in }

    private var formatted: String {
        String(format: "%.\(decimals)f", value)
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(label)
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
                Text(formatted)
                    .foregroundStyle(value == neutral ? .white.opacity(0.35) : .white.opacity(0.9))
                    .monospacedDigit()
            }
            .font(.system(size: 12, weight: .regular))

            Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
                .tint(.white.opacity(0.85))
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            value = neutral
            // A double-tap reset never goes through the slider's drag, so the
            // final bake has to be kicked off by hand.
            onEditingChanged(false)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(formatted)
    }
}

/// A titled group of sliders.
struct FilterSection<Content: View>: View {

    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.4))
                .padding(.top, 4)

            content
        }
    }
}
