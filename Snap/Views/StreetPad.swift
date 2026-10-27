//
//  StreetPad.swift
//  Snap
//
//  A camera that looks like somebody dialling.
//
//  Street photography goes wrong the moment the subject sees a camera, and a
//  phone held up with a viewfinder on it is a camera. A phone held up with the
//  Phone app's keypad on it is somebody about to make a call. So StreetPad
//  covers the whole app with a working copy of that keypad — iOS 26's, in its
//  Unified layout — and takes photographs from behind it.
//
//  The keypad is the control. The number dialled is the session: frames, then
//  seconds between frames, then seconds of lead-in, split by pound signs — see
//  `StreetPadPlan`. The green call button starts it and, red while it runs,
//  ends it. Calls and Contacts switch the two axes of the level guide on and
//  off, marked with a small blue dot carrying the axis. Search, at the lower
//  right where it always is, closes StreetPad.
//
//  Opened by three taps on the empty space under the lower right corner of the
//  frame — unmarked, since a button labelled "pretend to be the Phone app"
//  would rather give the game away.
//
//  Dark, like the rest of Snap: the app is dark-only, and the Phone app in
//  dark mode is the Phone app.
//

import AudioToolbox
import SwiftUI
import UIKit

struct StreetPad: View {

    @ObservedObject var session: StreetPadSession
    /// Handed through to the session, which takes the frames. Not watched:
    /// nothing on a keypad changes because the camera did.
    let camera: CameraModel
    var onClose: () -> Void

    /// What is on the keypad. Kept, so closing StreetPad, or the app, doesn't
    /// lose a session somebody has set up the way they like it.
    @AppStorage("streetPad.number") private var number = ""
    /// The last number a call started. Pressing call with nothing dialled
    /// brings it back, the way the Phone app brings back the last number
    /// called; pressing again calls it.
    @AppStorage("streetPad.lastCalled") private var lastCalled = ""

    var body: some View {
        GeometryReader { geometry in
            let metrics = PadMetrics(width: geometry.size.width)

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                numberDisplay(metrics)
                    .padding(.bottom, metrics.displayGap)

                keypad(metrics)

                callRow(metrics)
                    .padding(.top, metrics.verticalGap)

                tabBar
                    .padding(.top, metrics.tabBarGap)
                    // iOS 26's bar floats over the home indicator's strip
                    // rather than sitting above it.
                    .padding(.bottom, max(geometry.safeAreaInsets.bottom - 13, 8))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Down to the bottom edge, so the proxy reports the home indicator's
        // strip as an inset the bar can sit partway into.
        .ignoresSafeArea(edges: .bottom)
        .background(Color.black.ignoresSafeArea())
    }

    // MARK: - The number

    private func numberDisplay(_ metrics: PadMetrics) -> some View {
        VStack(spacing: 4) {
            Text(number)
                .font(.system(size: metrics.numberSize, weight: .regular))
                .foregroundStyle(.white)
                // Shrinks first, then loses its beginning rather than its end,
                // which is how the Phone app shows a long number.
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .truncationMode(.head)
                .frame(height: metrics.numberSize * 1.25)
                .padding(.horizontal, 28)

            Text("Add Number")
                .font(.system(size: 17 * metrics.scale, weight: .regular))
                .foregroundStyle(PadColor.blue)
                .opacity(number.isEmpty ? 0 : 1)
                .accessibilityHidden(number.isEmpty)
        }
    }

    // MARK: - The keys

    private func keypad(_ metrics: PadMetrics) -> some View {
        VStack(spacing: metrics.verticalGap) {
            ForEach(PadKey.rows.indices, id: \.self) { row in
                HStack(spacing: metrics.horizontalGap) {
                    ForEach(PadKey.rows[row]) { key in
                        digitKey(key, metrics: metrics)
                    }
                }
            }
        }
    }

    private func digitKey(_ key: PadKey, metrics: PadMetrics) -> some View {
        PadButton(onPress: { dial(key) },
                  // Holding zero types a plus, as it does in the Phone app.
                  onHold: key.symbol == "0" ? { holdZero() } : nil) { isPressed in
            DigitFace(key: key, metrics: metrics)
                .frame(width: metrics.key, height: metrics.key)
                .modifier(KeyFace(isPressed: isPressed))
        }
        .accessibilityLabel(key.letters.isEmpty ? key.symbol : "\(key.symbol), \(key.letters)")
    }

    private func dial(_ key: PadKey) {
        // The Phone app has no real limit, but past this nothing on screen
        // can show it and no session needs it.
        guard number.count < 40 else { return }
        number.append(key.symbol)
        // The keypad's own tones, which the ring/silent switch silences the
        // same way it silences the Phone app's.
        AudioServicesPlaySystemSound(key.tone)
    }

    private func holdZero() {
        guard number.last == "0" else { return }
        number.removeLast()
        number.append("+")
    }

    // MARK: - Call and delete

    private func callRow(_ metrics: PadMetrics) -> some View {
        HStack(spacing: metrics.horizontalGap) {
            Color.clear
                .frame(width: metrics.key, height: metrics.key)

            Button(action: call) {
                Image(systemName: session.isRunning ? "phone.down.fill" : "phone.fill")
                    .font(.system(size: 30 * metrics.scale, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: metrics.key, height: metrics.key)
                    .background(Circle().fill(session.isRunning ? PadColor.red : PadColor.green))
                    .contentShape(Circle())
            }
            .buttonStyle(DimmingStyle())
            .animation(.easeOut(duration: 0.2), value: session.isRunning)
            .accessibilityLabel(session.isRunning ? "End" : "Call")

            // Only once there is something to delete, as in the Phone app.
            // Held, it deletes on its own, one digit at a time and then
            // quickly.
            PadButton(holdDelay: 0.5,
                      repeatsHold: true,
                      onPress: deleteOne,
                      onHold: deleteOne) { isPressed in
                Image(systemName: "delete.left.fill")
                    .font(.system(size: 24 * metrics.scale, weight: .regular))
                    .foregroundStyle(PadColor.delete.opacity(isPressed ? 0.5 : 1))
                    .frame(width: metrics.key, height: metrics.key)
            }
            .opacity(number.isEmpty ? 0 : 1)
            .allowsHitTesting(!number.isEmpty)
            .accessibilityLabel("Delete")
            .accessibilityHidden(number.isEmpty)
        }
    }

    private func deleteOne() {
        guard !number.isEmpty else { return }
        number.removeLast()
    }

    /// Green starts the run the number describes; red ends it. With nothing
    /// dialled it brings the last number back instead, as the Phone app does,
    /// and a number that doesn't read as a session is refused with a knock.
    private func call() {
        if session.isRunning {
            session.stop()
            return
        }

        if number.isEmpty {
            guard !lastCalled.isEmpty else { return }
            number = lastCalled
            return
        }

        guard let plan = StreetPadPlan(dialled: number) else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        lastCalled = number
        session.start(plan, camera: camera)
    }

    // MARK: - The tab bar

    /// Calls, Contacts and Keypad in one floating capsule, and Search in a
    /// circle of its own at the right — iOS 26's Unified Phone.
    ///
    /// Keypad is always the one lit, because it is the one being used. The
    /// other two are switches for the level guide, and say they are on with
    /// a blue dot carrying the axis they hold level — Z for the horizon, X for
    /// pointing straight out.
    private var tabBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                tab("Calls", symbol: "phone.fill", badge: session.levelsHorizon ? "Z" : nil) {
                    session.levelsHorizon.toggle()
                }
                tab("Contacts", symbol: "person.crop.circle.fill", badge: session.levelsPitch ? "X" : nil) {
                    session.levelsPitch.toggle()
                }
                tab("Keypad", symbol: "circle.grid.3x3.fill", isSelected: true) {}
            }
            .padding(4)
            .frame(maxWidth: .infinity)
            .frame(height: PadMetrics.tabBarHeight)
            .modifier(BarGlass(shape: Capsule(), isInteractive: false))

            Button(action: onClose) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: PadMetrics.tabBarHeight, height: PadMetrics.tabBarHeight)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .modifier(BarGlass(shape: Circle(), isInteractive: true))
            .accessibilityLabel("Search")
            .accessibilityHint("Closes StreetPad")
        }
        .padding(.horizontal, 21)
    }

    private func tab(_ title: String,
                     symbol: String,
                     badge: String? = nil,
                     isSelected: Bool = false,
                     action: @escaping () -> Void) -> some View {
        Button {
            if !isSelected { UISelectionFeedbackGenerator().selectionChanged() }
            action()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .medium))
                    .frame(height: 26)
                    .overlay(alignment: .topTrailing) {
                        if let badge {
                            Text(badge)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 15, height: 15)
                                .background(Circle().fill(PadColor.blue))
                                .offset(x: 9, y: -3)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(isSelected ? PadColor.blue : .white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if isSelected {
                    Capsule().fill(Color.white.opacity(0.1))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: badge)
        .accessibilityLabel(title)
        .accessibilityValue(badge.map { "level guide \($0) on" } ?? "")
    }
}

// MARK: - Keys

/// One key on the keypad: the digit, the letters under it, and its tone.
private struct PadKey: Identifiable {
    let symbol: String
    let letters: String

    var id: String { symbol }

    /// The keypad's own DTMF tones, system sounds 1200 to 1211: the digits in
    /// order, then the star and the pound sign.
    var tone: SystemSoundID {
        switch symbol {
        case "*": return 1210
        case "#": return 1211
        default:  return 1200 + SystemSoundID(Int(symbol) ?? 0)
        }
    }

    static let rows: [[PadKey]] = [
        [PadKey(symbol: "1", letters: ""),
         PadKey(symbol: "2", letters: "ABC"),
         PadKey(symbol: "3", letters: "DEF")],
        [PadKey(symbol: "4", letters: "GHI"),
         PadKey(symbol: "5", letters: "JKL"),
         PadKey(symbol: "6", letters: "MNO")],
        [PadKey(symbol: "7", letters: "PQRS"),
         PadKey(symbol: "8", letters: "TUV"),
         PadKey(symbol: "9", letters: "WXYZ")],
        [PadKey(symbol: "*", letters: ""),
         PadKey(symbol: "0", letters: "+"),
         PadKey(symbol: "#", letters: "")],
    ]
}

/// What a key shows. The digits sit high with their letters under them; 1 has
/// none, but keeps their room so it lines up with 2 and 3. The star and the
/// pound sign have no letters and sit in the middle, the star drawn large
/// because the font sets it small and high.
private struct DigitFace: View {

    let key: PadKey
    let metrics: PadMetrics

    var body: some View {
        Group {
            switch key.symbol {
            case "*":
                Text("*")
                    .font(.system(size: 46 * metrics.scale, weight: .regular))
                    .offset(y: 8 * metrics.scale)
            case "#":
                Text("#")
                    .font(.system(size: 34 * metrics.scale, weight: .regular))
            default:
                VStack(spacing: -1 * metrics.scale) {
                    Text(key.symbol)
                        .font(.system(size: 36 * metrics.scale, weight: .regular))
                    Text(key.letters.isEmpty ? " " : key.letters)
                        .font(.system(size: 10 * metrics.scale, weight: .bold))
                        .tracking(2 * metrics.scale)
                }
                .offset(y: -1 * metrics.scale)
            }
        }
        .foregroundStyle(.white)
    }
}

/// A key that answers on touch-down, the way the keypad does — the digit is on
/// screen and the tone playing before the finger lifts — and, if it is given
/// something to do on a hold, does that after a moment, once or over and over.
private struct PadButton<Label: View>: View {

    var holdDelay: Double = 0.8
    var repeatsHold = false
    var onPress: () -> Void
    var onHold: (() -> Void)? = nil
    @ViewBuilder var label: (Bool) -> Label

    @State private var isDown = false
    @State private var hold: Task<Void, Never>? = nil
    /// Reset by SwiftUI however the touch ends, including the ways that
    /// never reach `onEnded` — which would otherwise leave a key held down.
    @GestureState private var isTouching = false

    var body: some View {
        label(isDown)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isTouching) { _, touching, _ in touching = true }
                    .onChanged { _ in press() }
                    .onEnded { _ in release() }
            )
            .onChange(of: isTouching) { _, touching in
                if !touching { release() }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onPress() }
    }

    private func press() {
        guard !isDown else { return }
        isDown = true
        onPress()

        guard let onHold else { return }
        let delay = holdDelay
        let repeats = repeatsHold
        hold = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            while !Task.isCancelled {
                onHold()
                guard repeats else { return }
                try? await Task.sleep(for: .seconds(0.1))
            }
        }
    }

    private func release() {
        isDown = false
        hold?.cancel()
        hold = nil
    }
}

/// The disc behind a digit.
///
/// Liquid Glass on iOS 26, which is what the keypad has worn since 26.1, and
/// which brings its own response to a touch. Before that, the dark grey disc
/// every keypad since iOS 7 has had, lit grey while it is held and fading back
/// as it is let go. The glass needs the iOS 26 SDK to build, so it is asked for
/// only when the compiler is new enough to have it.
private struct KeyFace: ViewModifier {

    var isPressed: Bool

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            classic(content)
        }
        #else
        classic(content)
        #endif
    }

    private func classic(_ content: Content) -> some View {
        content
            .background(Circle().fill(isPressed ? PadColor.keyPressed : PadColor.key))
            .animation(isPressed ? nil : .easeOut(duration: 0.3), value: isPressed)
    }
}

/// The tab bar's capsule and the search circle: Liquid Glass where there is
/// any, and a dark material where there isn't.
private struct BarGlass<S: Shape>: ViewModifier {

    let shape: S
    var isInteractive: Bool

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(isInteractive ? .regular.interactive() : .regular, in: shape)
        } else {
            classic(content)
        }
        #else
        classic(content)
        #endif
    }

    private func classic(_ content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 0.5))
    }
}

/// The call button's press: it dims under the finger, as the Phone app's does.
private struct DimmingStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(configuration.isPressed ? nil : .easeOut(duration: 0.25),
                       value: configuration.isPressed)
    }
}

// MARK: - Measurements

/// The keypad's proportions, as measured off an iPhone 15 at 393 points
/// across and scaled to whatever this one is. Kept in one place so they can be
/// held up against the real thing and nudged.
private struct PadMetrics {

    static let referenceWidth: CGFloat = 393
    static let tabBarHeight: CGFloat = 62

    let scale: CGFloat

    init(width: CGFloat) {
        scale = min(max(width / PadMetrics.referenceWidth, 0.82), 1.12)
    }

    /// The diameter of a key.
    var key: CGFloat { 78 * scale }
    /// Between two keys side by side.
    var horizontalGap: CGFloat { 27 * scale }
    /// Between two rows of keys, and between the last row and the call button.
    var verticalGap: CGFloat { 15 * scale }
    var numberSize: CGFloat { 40 * scale }
    /// Between the number and the top row of keys.
    var displayGap: CGFloat { 22 * scale }
    /// Between the call button and the tab bar.
    var tabBarGap: CGFloat { 30 * scale }
}

/// The Phone app's colours in dark mode: the system green, red and blue, and
/// the keypad's own two greys.
private enum PadColor {
    static let key = Color(white: 0.2)
    static let keyPressed = Color(white: 0.45)
    static let delete = Color(white: 0.55)
    static let green = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)
    static let red = Color(red: 1, green: 69 / 255, blue: 58 / 255)
    static let blue = Color(red: 10 / 255, green: 132 / 255, blue: 1)
}
