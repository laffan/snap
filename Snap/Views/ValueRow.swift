//
//  ValueRow.swift
//  Snap
//
//  A labelled row of choices under the frame — shutter speeds, ISO stops.
//

import SwiftUI

/// Published so the camera screen can hold room for rows that aren't showing
/// yet without guessing at the number.
enum ValueRowMetrics {
    static let height: CGFloat = 30
}

struct ValueRow<Value: Identifiable & Equatable>: View {

    let label: String
    let values: [Value]
    let title: (Value) -> String
    @Binding var selection: Value?

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 26, alignment: .leading)

            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    ForEach(values) { value in
                        let isSelected = value.id == selection?.id

                        Button {
                            selection = value
                        } label: {
                            Text(title(value))
                                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                                .monospacedDigit()
                                .foregroundStyle(isSelected ? Color.snapAccent : .white.opacity(0.6))
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 14)
        .frame(height: ValueRowMetrics.height)
    }
}

/// ISO values are plain floats, which aren't Identifiable on their own.
struct ISOChoice: Identifiable, Equatable {
    let value: Float
    var id: Float { value }
}
