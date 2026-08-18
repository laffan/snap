//
//  ShutterButton.swift
//  Snap
//

import SwiftUI

/// A ring with a filled disc inside it. The disc shrinks under the finger and
/// dims while a capture is in flight; nothing else moves.
struct ShutterButton: View {

    var isBusy: Bool
    var action: () -> Void

    @State private var isPressed = false

    private let outerDiameter: CGFloat = 74
    private let ringWidth: CGFloat = 3
    private let inset: CGFloat = 6

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(Color.white, lineWidth: ringWidth)
                    .frame(width: outerDiameter, height: outerDiameter)

                Circle()
                    .fill(Color.white)
                    .frame(width: outerDiameter - ringWidth * 2 - inset,
                           height: outerDiameter - ringWidth * 2 - inset)
                    .scaleEffect(isPressed ? 0.86 : 1)
                    .opacity(isBusy ? 0.45 : 1)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .animation(.easeOut(duration: 0.12), value: isPressed)
        .animation(.easeOut(duration: 0.15), value: isBusy)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .accessibilityLabel("Shutter")
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        ShutterButton(isBusy: false) {}
    }
}
