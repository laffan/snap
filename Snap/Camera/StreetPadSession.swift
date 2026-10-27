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
//  Every frame says itself with the shutter's own knock, the start and the end
//  of a run each have a knock of their own, and the level guide — when Calls
//  or Contacts has switched an axis of it on — says how far the phone is from
//  upright by how hard and how often it taps.
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
    private let level = LevelGuide()

    /// Starts a run. The camera takes each frame exactly as its own shutter
    /// would — same look, same file, same place in the roll.
    func start(_ plan: StreetPadPlan, camera: CameraModel) {
        stop(silently: true)

        isRunning = true
        // A run can be longer than auto-lock, and a locked phone has no camera.
        UIApplication.shared.isIdleTimerDisabled = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        updateLevelGuide()

        run = Task { [weak self] in
            let clock = ContinuousClock()
            let start = clock.now

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

/// Says how far the phone is from upright, by touch.
///
/// Read off gravity as Core Motion fuses it from the gyroscope and the
/// accelerometer — the gyroscope is what keeps the reading steady while the
/// phone is being carried, where the accelerometer alone would read every step
/// as a tilt.
///
/// Within a degree of level it is silent. Past that it taps, and both how hard
/// and how often grow with the error: a slow, soft tap a little off, a fast,
/// firm one far off, saturating at fifteen degrees. Silence is the answer to
/// aim for, which is the one a hand can find without being told which way to
/// go — tilt, and the taps say warmer or colder.
@MainActor
final class LevelGuide {

    var tracksHorizon = false
    var tracksPitch = false

    /// Within this, in degrees, the phone is level and nothing taps.
    static let tolerance = 1.0
    /// Past this, in degrees, the taps are as hard and as fast as they get.
    static let saturation = 15.0

    private let motion = CMMotionManager()
    private let haptic = UIImpactFeedbackGenerator(style: .rigid)
    private var lastPulse: CFTimeInterval = 0

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
        var error = 0.0
        if tracksHorizon { error = max(error, LevelGuide.horizonError(gravity)) }
        if tracksPitch { error = max(error, LevelGuide.pitchError(gravity)) }
        guard error > LevelGuide.tolerance else { return }

        let t = min((error - LevelGuide.tolerance) / (LevelGuide.saturation - LevelGuide.tolerance), 1)
        // From a tap every 0.6 s just off level to one every 0.07 s far off.
        let interval = 0.6 + (0.07 - 0.6) * t
        let now = CACurrentMediaTime()
        guard now - lastPulse >= interval else { return }

        lastPulse = now
        haptic.impactOccurred(intensity: CGFloat(0.35 + 0.65 * t))
        haptic.prepare()
    }

    /// How far, in degrees, the screen's own up has turned away from the
    /// nearest quarter turn of true up.
    ///
    /// The nearest quarter turn rather than portrait alone, because the photo
    /// is turned upright by quarter turns when it is taken — see "Which way
    /// up" in the README — so a phone held level on its side takes a level
    /// photograph too.
    static func horizonError(_ gravity: CMAcceleration) -> Double {
        // Lying flat, which way is down within the screen is noise rather
        // than a reading, and a phone lying flat is not upright either.
        let inPlane = (gravity.x * gravity.x + gravity.y * gravity.y).squareRoot()
        guard inPlane > 0.25 else { return saturation }

        let angle = atan2(gravity.x, -gravity.y) * 180 / .pi
        return abs(angle - 90 * (angle / 90).rounded())
    }

    /// How far, in degrees, the screen has tipped away from vertical — the
    /// camera pointing up or down rather than straight out.
    static func pitchError(_ gravity: CMAcceleration) -> Double {
        abs(asin(min(max(gravity.z, -1), 1))) * 180 / .pi
    }
}
