//
//  StreetPadSession.swift
//  Snap
//
//  What StreetPad dials, and the run of frames a call starts.
//
//  A number on the keypad is three fields split by pound signs: how many
//  frames, how many seconds between them, and how many seconds before the
//  first. `3#10#3` is three frames ten seconds apart, the first one three
//  seconds after the call button. The call button starts the run and pressing
//  it again ends it; the number stays on the keypad either way, so the same
//  run again is one press.
//
//  Nothing here looks at the screen, because the point is that nobody is.
//  Everything is said through the earpiece instead — see `StreetPadSounds`:
//  a tick for each second of the lead-in, a soft beep as each frame is taken,
//  and the level guide's pips when Calls or Contacts has switched an axis of
//  it on. The knocks the run has always had are still tried alongside, for
//  the phones that deliver them.
//

import Combine
import CoreMotion
import UIKit

/// A dialled StreetPad number, read.
struct StreetPadPlan: Equatable {

    /// At least one.
    var frames: Int
    /// Seconds from one frame to the next. Zero is as fast as the camera can
    /// take them, which is one at a time: a frame waits for the last to finish.
    var interval: Int
    /// Seconds from the call button to the first frame.
    var leadIn: Int

    /// Reads `frames#interval#leadIn`.
    ///
    /// The last two can be left off, or left empty, and mean zero: `5` is five
    /// frames back to back starting now, `5#2` the same two seconds apart.
    /// Anything else the keypad can type — a star, a plus off a held zero, a
    /// fourth field, a frame count of nothing — isn't a plan, and the call
    /// button says so with a knock rather than guessing.
    init?(dialled: String) {
        let fields = dialled.split(separator: "#", omittingEmptySubsequences: false)
        guard (1...3).contains(fields.count),
              // Five digits is a day of seconds and then some; any more is a
              // typing accident rather than a session.
              fields.allSatisfy({ field in
                  field.count <= 5 && field.allSatisfy { $0.isASCII && $0.isNumber }
              }),
              let frames = Int(fields[0]), frames > 0 else { return nil }

        func seconds(_ index: Int) -> Int {
            guard fields.indices.contains(index) else { return 0 }
            return Int(fields[index]) ?? 0
        }

        self.frames = frames
        self.interval = seconds(1)
        self.leadIn = seconds(2)
    }

    /// When frame `index` falls, in seconds from the call button.
    func time(ofFrame index: Int) -> Double {
        Double(leadIn) + Double(index) * Double(interval)
    }
}

/// One run of frames, and the level guide that runs alongside it.
///
/// Main-actor bound: it reads and drives `CameraModel`, whose published state
/// belongs to the main thread, and the run's own task inherits that rather
/// than wandering off onto a background executor.
@MainActor
final class StreetPadSession: ObservableObject {

    @Published private(set) var isRunning = false

    /// The horizon: turning about the axis straight through the screen, which
    /// is what tilts a skyline. Switched on and off by Calls, marked on it
    /// as Z.
    @Published var levelsHorizon = false {
        didSet { updateLevelGuide() }
    }

    /// Pointing: turning about the axis across the phone, which tips the
    /// camera up at a building or down at the pavement and makes its verticals
    /// lean in. Switched on and off by Contacts, marked on it as X.
    @Published var levelsPitch = false {
        didSet { updateLevelGuide() }
    }

    private var run: Task<Void, Never>? = nil
    private let sounds = StreetPadSounds()
    private lazy var level = LevelGuide(sounds: sounds)

    /// Starts a run. The camera takes each frame exactly as its own shutter
    /// would — same look, same file, same place in the roll.
    func start(_ plan: StreetPadPlan, camera: CameraModel) {
        stop(silently: true)

        isRunning = true
        // A run can be longer than auto-lock, and a locked phone has no camera.
        UIApplication.shared.isIdleTimerDisabled = true
        sounds.activate()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        updateLevelGuide()

        let sounds = self.sounds
        run = Task { [weak self] in
            let clock = ContinuousClock()
            let start = clock.now

            // The lead-in counted out a second at a time, from the press of
            // the call button up to the first frame — so the first tick is
            // also the one that says the run has started.
            for second in 0..<plan.leadIn {
                do {
                    try await clock.sleep(until: start + .seconds(second), tolerance: nil)
                } catch {
                    return
                }
                sounds.play(.tick)
            }

            for index in 0..<plan.frames {
                do {
                    try await clock.sleep(until: start + .seconds(plan.time(ofFrame: index)), tolerance: nil)
                    // One capture at a time, and none into a camera that
                    // isn't running: a frame due while the last is still being
                    // developed waits for it rather than being dropped.
                    while camera.isCapturing || camera.state != .running {
                        try await clock.sleep(for: .milliseconds(50), tolerance: nil)
                    }
                } catch {
                    // Cancelled: the run was ended by hand.
                    return
                }
                camera.capture()
                // Quiet, short, and the only sign there is now that the
                // shutter makes no sound of its own.
                sounds.play(.shutter)
            }

            self?.finish()
        }
    }

    /// Ends the run, if there is one. The call button pressed a second time,
    /// StreetPad closed, or the app leaving — a run is not something to carry
    /// on with in a pocket that has no camera.
    func stop() {
        stop(silently: false)
    }

    private func stop(silently: Bool) {
        guard isRunning else { return }
        run?.cancel()
        run = nil
        finish(knock: !silently)
    }

    /// The end of a run, however it ended, says so with a knock of its own —
    /// the one a phone gives when something wants looking at, which is what
    /// the roll now does.
    private func finish(knock: Bool = true) {
        run = nil
        isRunning = false
        UIApplication.shared.isIdleTimerDisabled = false
        updateLevelGuide()
        sounds.deactivate()
        if knock { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    }

    /// The guide runs only during a run and only with an axis switched on:
    /// the motion hardware costs power, and a phone tapping in a pocket while
    /// nothing is being taken is a phone being annoying.
    private func updateLevelGuide() {
        level.tracksHorizon = levelsHorizon
        level.tracksPitch = levelsPitch
        if isRunning && (levelsHorizon || levelsPitch) {
            level.start()
        } else {
            level.stop()
        }
    }
}

/// Says how far the phone is from upright, by ear and by touch.
///
/// Read off gravity as Core Motion fuses it from the gyroscope and the
/// accelerometer — the gyroscope is what keeps the reading steady while the
/// phone is being carried, where the accelerometer alone would read every step
/// as a tilt.
///
/// Within a degree of level it is silent. Past that it pips in the earpiece,
/// faster the further off it is: a pip every 0.6 seconds a little off, every
/// 0.07 at fifteen degrees and beyond. The pip says which way, too. One pip is
/// the horizon and two are pointing; high is leaning right or pointing up, low
/// is leaning left or pointing down. With both axes on it reports whichever is
/// further off. Silence is the answer to aim for.
///
/// Each pip is also a tap, as hard as the pip is fast, for the phones whose
/// haptics come through while the camera is running.
@MainActor
final class LevelGuide {

    var tracksHorizon = false
    var tracksPitch = false

    /// Within this, in degrees, the phone is level and nothing sounds.
    static let tolerance = 1.0
    /// Past this, in degrees, the pips are as fast as they get.
    static let saturation = 15.0

    private let sounds: StreetPadSounds
    private let motion = CMMotionManager()
    private let haptic = UIImpactFeedbackGenerator(style: .rigid)
    private var lastPulse: CFTimeInterval = 0

    init(sounds: StreetPadSounds) {
        self.sounds = sounds
    }

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 60
        haptic.prepare()
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let gravity = data?.gravity else { return }
            MainActor.assumeIsolated { self?.respond(to: gravity) }
        }
    }

    func stop() {
        guard motion.isDeviceMotionActive else { return }
        motion.stopDeviceMotionUpdates()
    }

    private func respond(to gravity: CMAcceleration) {
        // The axis furthest off, and which side of level it is on.
        var worst: (error: Double, isPointing: Bool) = (0, false)
        if tracksHorizon {
            if let error = LevelGuide.horizonError(gravity) {
                if abs(error) > abs(worst.error) { worst = (error, false) }
            } else {
                // Lying flat there is no horizon to read, and what is wrong
                // is which way the phone faces — so that is what is said.
                worst = (LevelGuide.pitchError(gravity), true)
            }
        }
        if tracksPitch {
            let error = LevelGuide.pitchError(gravity)
            if abs(error) > abs(worst.error) { worst = (error, true) }
        }

        let magnitude = abs(worst.error)
        guard magnitude > LevelGuide.tolerance else { return }

        let t = min((magnitude - LevelGuide.tolerance) / (LevelGuide.saturation - LevelGuide.tolerance), 1)
        // From a pip every 0.6 s just off level to one every 0.07 s far off.
        // Two pips need a little longer to be two.
        let fastest = worst.isPointing ? 0.14 : 0.07
        let interval = 0.6 + (fastest - 0.6) * t
        let now = CACurrentMediaTime()
        guard now - lastPulse >= interval else { return }
        lastPulse = now

        let isHigh = worst.error > 0
        switch (worst.isPointing, isHigh) {
        case (false, true):  sounds.play(.horizonHigh)
        case (false, false): sounds.play(.horizonLow)
        case (true, true):   sounds.play(.pointingHigh)
        case (true, false):  sounds.play(.pointingLow)
        }
        haptic.impactOccurred(intensity: CGFloat(0.35 + 0.65 * t))
        haptic.prepare()
    }

    /// How far, in degrees, the screen's own up has turned away from the
    /// nearest quarter turn of true up: positive leaning right — turned
    /// clockwise, as the person holding it sees the screen — and negative
    /// leaning left.
    ///
    /// The nearest quarter turn rather than portrait alone, because the photo
    /// is turned upright by quarter turns when it is taken — see "Which way
    /// up" in the README — so a phone held level on its side takes a level
    /// photograph too.
    ///
    /// Nil with the phone lying flat, or near it, where which way is down
    /// within the screen is noise rather than a reading.
    static func horizonError(_ gravity: CMAcceleration) -> Double? {
        let inPlane = (gravity.x * gravity.x + gravity.y * gravity.y).squareRoot()
        guard inPlane > 0.25 else { return nil }

        let angle = atan2(gravity.x, -gravity.y) * 180 / .pi
        return angle - 90 * (angle / 90).rounded()
    }

    /// How far, in degrees, the screen has tipped away from vertical:
    /// positive with the camera pointing up, negative pointing down.
    ///
    /// The screen faces the person holding it and the camera faces away, so
    /// the camera pointing up is the screen tipping forward towards the
    /// ground, which is gravity pulling out through the screen — the
    /// direction Core Motion's z runs.
    static func pitchError(_ gravity: CMAcceleration) -> Double {
        asin(min(max(gravity.z, -1), 1)) * 180 / .pi
    }
}
