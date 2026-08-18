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

    // A `private` stored property makes the synthesized memberwise initializer
    // private too, which would put this out of reach of CameraView. Spelled out
    // so it stays callable.
    init(isBusy: Bool, action: @escaping () -> Void) {
        self.isBusy = isBusy
        self.action = action
    }

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

/// Takes the shutter's place while a saved frame is being viewed. Same
/// footprint, so the row doesn't shift when the two swap.
struct CloseButton: View {

    var action: () -> Void

    private let diameter: CGFloat = 74

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(Color.white.opacity(0.75), lineWidth: 2)
                    .frame(width: diameter, height: diameter)

                Image(systemName: "xmark")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.white)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close photo")
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        HStack(spacing: 24) {
            ShutterButton(isBusy: false) {}
            CloseButton {}
        }
    }
}
