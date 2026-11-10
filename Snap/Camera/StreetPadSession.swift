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
//  a tick for each second of the lead-in, a thud as each frame is taken, and
//  the level guide's quiet Geiger-counter taps when Calls or Contacts has
//  switched it on. The knocks the run has always had are still tried
//  alongside, for the phones that deliver them.
//
//  Either volume button takes a frame too, whenever StreetPad is up — before
//  a run, in its lead-in, or between its frames. See `takeNow`.
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
    ///
    /// One axis at a time: switching this on switches pointing off. One sound
    /// can only say one thing, and with both on there was no telling which
    /// axis it was about.
    @Published var levelsHorizon = false {
        didSet {
            if levelsHorizon, levelsPitch { levelsPitch = false }
            updateLevelGuide()
        }
    }

    /// Pointing: turning about the axis across the phone, which tips the
    /// camera up at a building or down at the pavement and makes its verticals
    /// lean in. Switched on and off by Contacts, marked on it as X. Switching
    /// it on switches the horizon off.
    @Published var levelsPitch = false {
        didSet {
            if levelsPitch, levelsHorizon { levelsHorizon = false }
            updateLevelGuide()
        }
    }

    private var run: Task<Void, Never>? = nil
    /// Volume-button presses still waiting for the camera. The audio session
    /// stays up until the last of them has had its thud.
    private var pendingPresses = 0
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
                // Low, short, and the only sign there is now that the
                // shutter makes no sound of its own.
                sounds.play(.shutter)
            }

            self?.finish()
        }
    }

    /// A frame now, off either volume button, whatever a run is doing.
    ///
    /// Taken as the camera's own shutter would take it, the moment the camera
    /// is free: a press that lands while a frame — the run's or an earlier
    /// press's — is still being developed waits for it rather than being
    /// dropped. The run's schedule doesn't move; its next frame waits in the
    /// same way if this one is still going when it falls due.
    ///
    /// Works with no run going too, which is why it takes the audio session
    /// for itself: the thud is the only answer the press gets.
    func takeNow(camera: CameraModel) {
        pendingPresses += 1
        sounds.activate()

        let sounds = self.sounds
        Task { [weak self] in
            let clock = ContinuousClock()
            // A camera that never comes free — stopped by the app leaving —
            // is given up on rather than waited for forever.
            let deadline = clock.now + .seconds(5)
            var isTaken = false
            while clock.now < deadline {
                if !camera.isCapturing, camera.state == .running {
                    camera.capture()
                    sounds.play(.shutter)
                    isTaken = true
                    break
                }
                try? await clock.sleep(for: .milliseconds(50), tolerance: nil)
            }
            if !isTaken { UINotificationFeedbackGenerator().notificationOccurred(.error) }
            self?.pressFinished()
        }
    }

    private func pressFinished() {
        pendingPresses -= 1
        if pendingPresses == 0, !isRunning { sounds.deactivate() }
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
        if pendingPresses == 0 { sounds.deactivate() }
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
/// It sounds like a Geiger counter: very quiet taps at random, sparse far from
/// upright and quickening as the phone comes round to it — about one and a
/// half a second at twenty degrees off and beyond, about twenty-five a second
/// just short of it. Within half a degree it goes quiet. Silence is the answer
/// to aim for, and the rush just before it is how you know you are nearly
/// there.
///
/// The rate climbs on a logarithmic scale of the error, so the last couple of
/// degrees — where the aiming actually happens — get most of the change.
///
/// It says how far and not which way: one axis at a time, and the taps are
/// all the same tap. Each is also a light haptic tap, for the phones whose
/// haptics come through while the camera is running.
@MainActor
final class LevelGuide {

    var tracksHorizon = false
    var tracksPitch = false

    /// Within this, in degrees, the phone is upright and nothing sounds.
    static let tolerance = 0.5
    /// Past this, in degrees, the taps are as sparse as they get.
    static let far = 20.0
    /// Taps a second, on average, at `far` and beyond.
    static let slowestRate = 1.5
    /// Taps a second, on average, just outside `tolerance`.
    static let fastestRate = 25.0

    private let sounds: StreetPadSounds
    private let motion = CMMotionManager()
    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private var lastUpdate: CFTimeInterval? = nil

    init(sounds: StreetPadSounds) {
        self.sounds = sounds
    }

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 60
        lastUpdate = nil
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

    /// Mean taps a second for an error of `magnitude` degrees.
    static func rate(forError magnitude: Double) -> Double {
        let t = min(max(log(magnitude / tolerance) / log(far / tolerance), 0), 1)
        return fastestRate * pow(slowestRate / fastestRate, t)
    }

    private func respond(to gravity: CMAcceleration) {
        let error: Double
        if tracksPitch {
            error = LevelGuide.pitchError(gravity)
        } else if tracksHorizon {
            // Lying flat there is no horizon to read, and what is wrong is
            // which way the phone faces — so that is what is measured.
            error = LevelGuide.horizonError(gravity) ?? LevelGuide.pitchError(gravity)
        } else {
            return
        }

        let now = CACurrentMediaTime()
        defer { lastUpdate = now }
        let magnitude = abs(error)
        guard magnitude > LevelGuide.tolerance, let previous = lastUpdate else { return }

        // A tap in this slice of time with the chance the rate gives it, which
        // is what makes the taps random rather than a metronome. Capped, so a
        // late update doesn't come back as a burst.
        let elapsed = min(now - previous, 0.1)
        guard Double.random(in: 0..<1) < LevelGuide.rate(forError: magnitude) * elapsed else { return }

        sounds.play(.click)
        haptic.impactOccurred(intensity: 0.4)
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
