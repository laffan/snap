//
//  ShutterButton.swift
//  Snap
//

import SwiftUI

/// A ring with a filled disc inside it. The disc shrinks under the finger and
/// dims while a capture is in flight; nothing else moves.
///
/// The ring is also where the shutter says what it is in the middle of. For a
/// long exposure it is a grey track that fills white, clockwise from the top,
/// as the time on the dial passes, with the seconds left in a disc gone grey —
/// the shutter can't be pressed again until the exposure is in, and the disc
/// says so by looking it. For a double exposure it is two halves, grey until
/// their exposure is taken: the left with the first, the right with the
/// second. It is the one control the eye is on at the moment of taking a
/// photograph, so it is where the state of the photograph being taken goes.
struct ShutterButton: View {

    /// What the ring around the disc says.
    enum Ring: Equatable {
        /// An ordinary shutter: one white ring.
        case plain
        /// A long exposure, this far through: nothing to all of it.
        case progress(Double)
        /// A double exposure, with which of the two are taken.
        case halves(first: Bool, second: Bool)
    }

    var isBusy: Bool
    var ring: Ring
    /// Shown in the disc, which greys behind it: a long exposure's seconds left.
    var count: String?
    var action: () -> Void

    @State private var isPressed = false

    // A `private` stored property makes the synthesized memberwise initializer
    // private too, which would put this out of reach of CameraView. Spelled out
    // so it stays callable.
    init(isBusy: Bool, ring: Ring = .plain, count: String? = nil, action: @escaping () -> Void) {
        self.isBusy = isBusy
        self.ring = ring
        self.count = count
        self.action = action
    }

    private let outerDiameter: CGFloat = 81
    private let ringWidth: CGFloat = 3
    private let inset: CGFloat = 6
    /// A ring, or the part of one, that hasn't happened yet.
    private static let unlit = Color.white.opacity(0.28)
    /// The break between the two halves, top and bottom, as a share of the
    /// way round: about three points on this ring.
    private static let halfGap = 0.012

    var body: some View {
        Button(action: action) {
            ZStack {
                ringView
                    .frame(width: outerDiameter, height: outerDiameter)

                Circle()
                    .fill(count == nil ? Color.white : Color.white.opacity(0.22))
                    .frame(width: outerDiameter - ringWidth * 2 - inset,
                           height: outerDiameter - ringWidth * 2 - inset)
                    .scaleEffect(isPressed ? 0.86 : 1)
                    // A grey disc already says it can't be pressed.
                    .opacity(isBusy && count == nil ? 0.45 : 1)

                if let count {
                    Text(count)
                        .font(.system(size: 24, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.easeOut(duration: 0.2), value: count)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .animation(.easeOut(duration: 0.12), value: isPressed)
        .animation(.easeOut(duration: 0.15), value: isBusy)
        .animation(.easeOut(duration: 0.15), value: halves)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .accessibilityLabel("Shutter")
        .accessibilityValue(accessibilityValue)
    }

    /// The halves alone, so their lighting animates and a long exposure's
    /// progress — redrawn every frame — doesn't.
    private var halves: [Bool] {
        if case .halves(let first, let second) = ring { return [first, second] }
        return []
    }

    @ViewBuilder
    private var ringView: some View {
        switch ring {
        case .plain:
            Circle()
                .strokeBorder(Color.white, lineWidth: ringWidth)

        case .progress(let fraction):
            ZStack {
                Circle()
                    .strokeBorder(Self.unlit, lineWidth: ringWidth)
                // A circle's path starts at three o'clock and runs clockwise,
                // so a quarter turn back starts it at the top.
                Circle()
                    .inset(by: ringWidth / 2)
                    .trim(from: 0, to: min(max(fraction, 0), 1))
                    .stroke(Color.white, style: StrokeStyle(lineWidth: ringWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }

        case .halves(let first, let second):
            ZStack {
                // From the top round to the bottom: the right half, the second.
                Circle()
                    .inset(by: ringWidth / 2)
                    .trim(from: Self.halfGap, to: 0.5 - Self.halfGap)
                    .stroke(second ? Color.white : Self.unlit,
                            style: StrokeStyle(lineWidth: ringWidth, lineCap: .butt))
                // And on round to the top again: the left half, the first.
                Circle()
                    .inset(by: ringWidth / 2)
                    .trim(from: 0.5 + Self.halfGap, to: 1 - Self.halfGap)
                    .stroke(first ? Color.white : Self.unlit,
                            style: StrokeStyle(lineWidth: ringWidth, lineCap: .butt))
            }
            .rotationEffect(.degrees(-90))
        }
    }

    private var accessibilityValue: String {
        switch ring {
        case .plain:
            return ""
        case .progress:
            return count.map { "\($0) seconds left" } ?? "Long exposure"
        case .halves(let first, let second):
            if second { return "Both exposures taken" }
            return first ? "First exposure taken" : "Double exposure"
        }
    }
}

/// Takes the shutter's place while a saved frame is being viewed.
///
/// Half the shutter's size, and roughly the size of PS and the black-and-white
/// disc beside it — the shutter is big because it is aimed at without looking,
/// and putting a photograph down is neither urgent nor blind. What it gives up
/// goes to the caption below it, which needs room more than this does.
struct CloseButton: View {

    var action: () -> Void

    private let diameter: CGFloat = 40
    /// Drawn at 40 and touched at 44, which is the smallest target worth
    /// offering a thumb.
    private let target: CGFloat = 44

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(Color.white.opacity(0.75), lineWidth: 1.5)
                    .frame(width: diameter, height: diameter)

                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(.white)
            }
            .frame(width: target, height: target)
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
            ShutterButton(isBusy: true, ring: .progress(0.35), count: "7") {}
            ShutterButton(isBusy: false, ring: .halves(first: true, second: false)) {}
            CloseButton {}
        }
    }
}
