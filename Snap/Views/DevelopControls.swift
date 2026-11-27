//
//  DevelopControls.swift
//  Snap
//
//  The pieces the develop panel is built from: a slider that behaves like
//  Lightroom's, the section heading every group of them sits under, and the
//  touch surfaces underneath both.
//
//  The slider is drawn here rather than borrowed from SwiftUI because the
//  system one can't do three of the things that make a develop slider worth
//  using: a track that shows what it does (blue to amber for Temperature, the
//  band's own colours for the mixer), a fill that starts from the middle for
//  a slider that goes both ways, and a drag that gets finer the further the
//  finger strays below it.
//

import SwiftUI
import UIKit

// MARK: - Slider

/// What a slider's track is painted with.
enum SliderTrack {
    /// A neutral track, filled from the slider's origin to its value.
    case plain
    /// A gradient across the whole track, which says what the slider does.
    /// No fill: the colours are the reading.
    case gradient([Color])

    static let temperature = SliderTrack.gradient([Color(red: 0.35, green: 0.55, blue: 1.0),
                                                   Color(white: 0.75),
                                                   Color(red: 1.0, green: 0.78, blue: 0.3)])
    static let tint = SliderTrack.gradient([Color(red: 0.35, green: 0.85, blue: 0.35),
                                            Color(white: 0.75),
                                            Color(red: 0.95, green: 0.4, blue: 0.85)])
    static let saturation = SliderTrack.gradient([Color(white: 0.55),
                                                  Color(red: 0.95, green: 0.35, blue: 0.3)])
    static let exposure = SliderTrack.gradient([Color(white: 0.15), Color(white: 0.95)])
}

/// One labelled develop slider.
///
/// Drag anywhere on the row to move it — by how far the finger moves rather
/// than where it lands, so picking it up never makes it jump. Drag down off
/// the row while moving it and it gets finer, down to a quarter of the speed,
/// for the last few units. Double-tap to send it back to neutral.
///
/// The row is compact on purpose: a Lightroom-sized panel of these still has
/// to fit in half a phone screen.
struct DevelopSlider: View {

    let label: String
    @Binding var value: Float
    var range: ClosedRange<Float> = -100...100
    var decimals: Int = 0
    /// Where the fill starts from, and what a double-tap returns to.
    var neutral: Float = 0
    /// The built-in look's value, marked on the track when it isn't neutral,
    /// so the way back to the look is visible as well as the way back to zero.
    var lookDefault: Float? = nil
    var track: SliderTrack = .plain
    /// Tints the label — used to give each colour band its own colour.
    var labelColor: Color = .white.opacity(0.75)
    var onEditingChanged: (Bool) -> Void = { _ in }

    /// The value while a drag is under way, unrounded, so a slow drag that
    /// moves less than one displayed unit per frame still gets somewhere.
    @State private var dragValue: Float? = nil
    /// How fine the drag is right now: 1 at full speed, smaller below it.
    @State private var precision: Float = 1
    /// How far across the drag had come at the last step, so each step adds
    /// only its own movement — at whatever precision was in force for it.
    @State private var lastTranslation: CGFloat = 0

    // Explicit because the private state above would otherwise make the
    // memberwise initializer private, putting this out of reach of the panel.
    init(label: String,
         value: Binding<Float>,
         range: ClosedRange<Float> = -100...100,
         decimals: Int = 0,
         neutral: Float = 0,
         lookDefault: Float? = nil,
         track: SliderTrack = .plain,
         labelColor: Color = .white.opacity(0.75),
         onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.label = label
        self._value = value
        self.range = range
        self.decimals = decimals
        self.neutral = neutral
        self.lookDefault = lookDefault
        self.track = track
        self.labelColor = labelColor
        self.onEditingChanged = onEditingChanged
    }

    private var span: Float { range.upperBound - range.lowerBound }

    private var formatted: String {
        let shown = String(format: "%.\(decimals)f", value)
        // A plus on anything that goes both ways, the way Lightroom writes it.
        if range.lowerBound < 0, value > 0 { return "+" + shown }
        return shown
    }

    private func fraction(_ v: Float) -> CGFloat {
        guard span > 0 else { return 0 }
        return CGFloat((min(max(v, range.lowerBound), range.upperBound) - range.lowerBound) / span)
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Text(label)
                    .foregroundStyle(labelColor)
                    .lineLimit(1)
                if dragValue != nil, precision < 0.99 {
                    Text(precisionLabel)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .transition(.opacity)
                }
                Spacer(minLength: 4)
                Text(formatted)
                    .foregroundStyle(.white.opacity(value == neutral ? 0.35 : 0.95))
                    .monospacedDigit()
            }
            .font(.system(size: 12, weight: .regular))

            trackView
                .frame(height: 14)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .overlay {
            ScrubSurface(onBegan: began, onChanged: changed, onEnded: ended, onDoubleTap: reset)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(formatted)
        .accessibilityAdjustableAction { direction in
            let step = span / 100
            switch direction {
            case .increment: value = clamped(value + step)
            case .decrement: value = clamped(value - step)
            @unknown default: break
            }
            onEditingChanged(false)
        }
    }

    private var precisionLabel: String {
        precision <= 0.3 ? "¼×" : precision <= 0.55 ? "½×" : "¾×"
    }

    private var trackView: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let thumb: CGFloat = 13
            let usable = max(width - thumb, 1)
            let x = thumb / 2 + usable * fraction(value)
            let origin = thumb / 2 + usable * fraction(neutral)
            let mid = proxy.size.height / 2

            ZStack(alignment: .topLeading) {
                switch track {
                case .plain:
                    Capsule()
                        .fill(Color.white.opacity(0.16))
                        .frame(width: usable, height: 2)
                        .offset(x: thumb / 2, y: mid - 1)
                    Rectangle()
                        .fill(Color.white.opacity(0.75))
                        .frame(width: abs(x - origin), height: 2)
                        .offset(x: min(x, origin), y: mid - 1)
                case .gradient(let colors):
                    Capsule()
                        .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                        .frame(width: usable, height: 3)
                        .opacity(0.8)
                        .offset(x: thumb / 2, y: mid - 1.5)
                }

                // The centre of a slider that goes both ways.
                if neutral > range.lowerBound && neutral < range.upperBound {
                    Rectangle()
                        .fill(Color.white.opacity(0.35))
                        .frame(width: 1, height: 6)
                        .offset(x: origin - 0.5, y: mid - 3)
                }

                if let lookDefault, lookDefault != neutral {
                    let mark = thumb / 2 + usable * fraction(lookDefault)
                    Circle()
                        .fill(Color.snapAccent.opacity(0.7))
                        .frame(width: 3, height: 3)
                        .offset(x: mark - 1.5, y: mid + 4)
                }

                Circle()
                    .fill(Color.white)
                    .frame(width: dragValue == nil ? 11 : thumb, height: dragValue == nil ? 11 : thumb)
                    .shadow(color: .black.opacity(0.5), radius: 1.5)
                    .offset(x: x - (dragValue == nil ? 5.5 : thumb / 2),
                            y: mid - (dragValue == nil ? 5.5 : thumb / 2))
            }
        }
    }

    private func clamped(_ v: Float) -> Float {
        min(max(v, range.lowerBound), range.upperBound)
    }

    /// Rounded to what the slider shows, so a value that reads 12 is 12 — the
    /// list of what has moved compares against the look exactly.
    private func rounded(_ v: Float) -> Float {
        let scale = pow(10, Float(decimals))
        return (v * scale).rounded() / scale
    }

    private func began() {
        dragValue = value
        precision = 1
        lastTranslation = 0
        onEditingChanged(true)
    }

    private func changed(_ dx: CGFloat, _ dropBelow: CGFloat, _ width: CGFloat) {
        guard width > 0 else { return }
        // Finer the further below the row the finger has wandered, the way
        // the system's own scrubbers are.
        let below = Float(max(0, dropBelow - 24))
        let fine = 1 / (1 + below / 48)
        let next = max(0.25, fine)
        if abs(next - precision) > 0.01 {
            withAnimation(.easeOut(duration: 0.1)) { precision = next }
        }

        let step = dx - lastTranslation
        lastTranslation = dx
        let start = dragValue ?? value
        let moved = clamped(start + Float(step / width) * span * precision)
        dragValue = moved

        let shown = rounded(moved)
        guard shown != value else { return }
        // A tick through neutral, so the middle can be found by feel.
        if (value - neutral) * (shown - neutral) <= 0, value != shown {
            UISelectionFeedbackGenerator().selectionChanged()
        }
        value = shown
    }

    private func ended() {
        dragValue = nil
        precision = 1
        onEditingChanged(false)
    }

    private func reset() {
        value = neutral
        // A double-tap reset never goes through a drag, so the final bake
        // has to be kicked off by hand.
        onEditingChanged(false)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

// MARK: - Section

/// A titled group of controls inside one of the panel's tools, with a reset
/// that takes just that group back to the built-in look.
///
/// The reset only shows while there is something in the group to reset — the
/// same rule the bar's Reset keeps for the whole look.
struct DevelopSection<Content: View>: View {

    let title: String
    var isChanged: Bool = false
    var onReset: (() -> Void)? = nil
    @ViewBuilder var content: Content

    init(title: String,
         isChanged: Bool = false,
         onReset: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.isChanged = isChanged
        self.onReset = onReset
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.5))

                Spacer()

                if let onReset, isChanged {
                    Button(action: onReset) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 28, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Reset \(title)")
                    .transition(.opacity)
                }
            }
            .frame(height: 20)
            .animation(.easeOut(duration: 0.15), value: isChanged)

            content
        }
    }
}

// MARK: - Touch surfaces

/// A transparent strip over a slider that turns a sideways drag into steps
/// and leaves an up-and-down one to the scroll view it sits in.
///
/// UIKit underneath, because this is the one arbitration SwiftUI can't be
/// asked to make: the pan only begins when the finger is moving more across
/// than up or down, and the scroll view's own pan is made to wait for it to
/// decide. So a swipe up the panel scrolls it, whichever slider it started on,
/// and a drag along a slider never scrolls.
struct ScrubSurface: UIViewRepresentable {

    var onBegan: () -> Void
    /// Distance moved across since the drag began, how far below the row the
    /// finger is now, and the row's width.
    var onChanged: (_ dx: CGFloat, _ below: CGFloat, _ width: CGFloat) -> Void
    var onEnded: () -> Void
    var onDoubleTap: () -> Void

    func makeUIView(context: Context) -> ScrubView {
        let view = ScrubView()
        view.handlers = self
        return view
    }

    func updateUIView(_ view: ScrubView, context: Context) {
        view.handlers = self
    }

    final class ScrubView: UIView, UIGestureRecognizerDelegate {

        var handlers: ScrubSurface?

        private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        private lazy var doubleTap: UITapGestureRecognizer = {
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
            tap.numberOfTapsRequired = 2
            return tap
        }()

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isAccessibilityElement = false
            pan.delegate = self
            pan.maximumNumberOfTouches = 1
            addGestureRecognizer(pan)
            addGestureRecognizer(doubleTap)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                handlers?.onBegan()
            case .changed:
                let translation = recognizer.translation(in: self)
                let location = recognizer.location(in: self)
                handlers?.onChanged(translation.x, location.y - bounds.height, bounds.width)
            case .ended, .cancelled, .failed:
                handlers?.onEnded()
            default:
                break
            }
        }

        @objc private func tapped() {
            handlers?.onDoubleTap()
        }

        override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard recognizer === pan else { return super.gestureRecognizerShouldBegin(recognizer) }
            let velocity = pan.velocity(in: self)
            return abs(velocity.x) > abs(velocity.y)
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            // The scroll view waits for this pan to decide which way the
            // finger is going before it takes the touch.
            other.view is UIScrollView && other is UIPanGestureRecognizer
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            false
        }
    }
}

/// A transparent surface that takes a touch the moment it lands and follows
/// it until it lifts — for the curve and the colour wheels, where a finger on
/// the control means the control and never the scroll view around it.
///
/// Locations are in the surface's own points, y down.
struct DragSurface: UIViewRepresentable {

    var onBegan: (CGPoint, CGSize) -> Void
    var onChanged: (CGPoint, CGSize) -> Void
    var onEnded: () -> Void
    var onDoubleTap: ((CGPoint, CGSize) -> Void)? = nil

    func makeUIView(context: Context) -> DragView {
        let view = DragView()
        view.handlers = self
        return view
    }

    func updateUIView(_ view: DragView, context: Context) {
        view.handlers = self
    }

    final class DragView: UIView, UIGestureRecognizerDelegate {

        var handlers: DragSurface?

        private lazy var press: UILongPressGestureRecognizer = {
            let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
            press.minimumPressDuration = 0
            press.allowableMovement = .greatestFiniteMagnitude
            return press
        }()

        private lazy var doubleTap: UITapGestureRecognizer = {
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            tap.numberOfTapsRequired = 2
            return tap
        }()

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isAccessibilityElement = false
            press.delegate = self
            doubleTap.delegate = self
            addGestureRecognizer(press)
            addGestureRecognizer(doubleTap)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        @objc private func pressed(_ recognizer: UILongPressGestureRecognizer) {
            let location = recognizer.location(in: self)
            switch recognizer.state {
            case .began:
                handlers?.onBegan(location, bounds.size)
            case .changed:
                handlers?.onChanged(location, bounds.size)
            case .ended, .cancelled, .failed:
                handlers?.onEnded()
            default:
                break
            }
        }

        @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
            handlers?.onDoubleTap?(recognizer.location(in: self), bounds.size)
        }

        /// The press and the double-tap both see every touch: the press is
        /// what moves a point, and two short presses in a row are also a
        /// double-tap.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            (recognizer === press && other === doubleTap) || (recognizer === doubleTap && other === press)
        }
    }
}
