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
    /// Tints the label — used to give each colour band its own colour.
    var labelColor: Color = .white.opacity(0.75)
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
                    .foregroundStyle(labelColor)
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

    /// Collapsed to begin with. There are more than forty knobs in here; all
    /// of them open at once is a wall rather than a panel.
    @State private var isExpanded = false

    // Explicit because the private state above would otherwise make the
    // memberwise initializer private, putting this out of reach of FilterPanel.
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(title.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.2)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))

                    Spacer()
                }
                .foregroundStyle(.white.opacity(isExpanded ? 0.6 : 0.4))
                .padding(.top, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content
            }
        }
    }
}
