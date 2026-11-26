//
//  LongExposure.swift
//  Snap
//
//  A long exposure the sensor can't take in one go, taken in many.
//
//  iOS will not hold a shutter open for longer than the active format's
//  `maxExposureDuration`, which on an iPhone is about a second. So ten seconds
//  is ten one-second frames, back to back, added together photosite by
//  photosite before anything has demosaiced them — the same light a ten-second
//  exposure would have collected, give or take the moments between frames. The
//  merge is written into the first frame's own DNG, and from there it is a
//  negative like any other: the buffer develops it, the roll shows it, the
//  sliders re-develop it and Lightroom opens it.
//
//  The frames are added, not averaged. An average lands at one frame's
//  brightness, which sounds the same and isn't: a headlight that clips to
//  white in the frame it crosses comes out of an average as a tenth of white,
//  and a trail that should be the brightest thing in the photograph is a
//  smudge. Added, it is as bright as it was.
//
//  With an ISO pinned, that is all there is to it: ten seconds at ISO 100 is
//  ten times as much light as one, as on any camera. Otherwise the meter
//  decides how bright the whole run comes out, and each frame is exposed for
//  its share of that — a dark street metered at one second and ISO 500 becomes
//  ten one-second frames at about ISO 55 — so no frame clips before the sum
//  would, and the sum is where the meter wanted it.
//
//  Each frame is added as its own DNG holds it: packaged by AVFoundation,
//  decoded here, its black level taken off. It used to be added from the pixel
//  buffer AVFoundation hands over beside the DNG, which is cheaper, but on a
//  phone the two turned out to hold different numbers — and the DNG's are the
//  ones its black and white levels describe, and the ones the merge is
//  written back among. The buffer is still compared with the DNG on the first
//  frame, for the console, so that what the difference is can be learned.
//

import AVFoundation
import Combine
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import QuartzCore
import os

enum LongExposure {

    /// What the dial reaches, in seconds.
    static let range: ClosedRange<Int> = 2...30
    /// Where it starts, and where a double tap puts it back.
    static let defaultSeconds = 10
    /// A ceiling for a bright scene, where the frames are short and many. The
    /// running total is a float per photosite, which stays exact far past this.
    static let maxFrames = 400

    /// A guess at how long a RAW frame takes to turn round between one and the
    /// next, used only to share the meter's light out over the frames that
    /// will actually fit. The merge is scaled to what the frames really got,
    /// so a wrong guess costs a little noise rather than brightness.
    static let turnaround: TimeInterval = 0.1

    /// How the frames are exposed, and how bright the sum should come out.
    struct Plan {
        let duration: CMTime
        let iso: Float
        /// The light the whole run should come to, as seconds times ISO — the
        /// meter's — or nil when an ISO is pinned and the frames simply add up.
        let target: Double?

        var seconds: TimeInterval { CMTimeGetSeconds(duration) }
        /// One frame's exposure, seconds times ISO.
        var frameExposure: Double { seconds * Double(iso) }
    }

    /// The frame exposure for a run of `total` seconds. Session queue — it
    /// reads what the device is doing now.
    ///
    /// A pinned shutter is each frame's length; otherwise frames are as long as
    /// the format allows, since every frame brings its own read noise. A pinned
    /// ISO is each frame's ISO, and the frames add up as they are. Without one,
    /// the meter's reading is taken as one quantity — seconds times ISO,
    /// corrected by how far the meter says it is off — and each frame gets the
    /// ISO that takes the frames that fit in the run to it together.
    ///
    /// In bright light that share is below the sensor's base ISO. The frames
    /// then go to base ISO and, if even that would make one frame brighter than
    /// an ordinary photograph, shorter; the sum comes out too bright and is
    /// scaled down, which is the average again — what the run can do without a
    /// neutral-density filter.
    static func plan(for device: AVCaptureDevice,
                     total: TimeInterval,
                     pinnedShutter: CMTime?,
                     pinnedISO: Float?) -> Plan {
        let format = device.activeFormat
        let shortest = format.minExposureDuration
        var longest = format.maxExposureDuration
        // Never more than half the run, so even two seconds is two frames.
        let half = CMTime(seconds: total / 2, preferredTimescale: 1_000_000)
        if CMTimeCompare(half, longest) < 0, CMTimeCompare(half, shortest) > 0 {
            longest = half
        }

        func clampedDuration(_ time: CMTime) -> CMTime {
            if CMTimeCompare(time, shortest) < 0 { return shortest }
            if CMTimeCompare(time, longest) > 0 { return longest }
            return time
        }
        func clampedISO(_ iso: Float) -> Float {
            min(max(iso, format.minISO), format.maxISO)
        }

        let current = device.exposureDuration
        let currentISO = device.iso
        var duration = clampedDuration(pinnedShutter ?? longest)

        if let pinnedISO {
            return Plan(duration: duration, iso: clampedISO(pinnedISO), target: nil)
        }

        // Past four stops the meter is guessing, and auto has usually gone as
        // far as it can anyway.
        let offset = Double(min(max(device.exposureTargetOffset, -4), 4))
        let wanted = CMTimeGetSeconds(current) * Double(currentISO) * pow(2, -offset)
        guard wanted.isFinite, wanted > 0 else {
            // No reading worth sharing out: frames as the camera has them, and
            // the sum brought back to one of them.
            let frame = Plan(duration: clampedDuration(current), iso: clampedISO(currentISO), target: nil)
            return Plan(duration: frame.duration, iso: frame.iso, target: frame.frameExposure)
        }

        // Each frame's share of the light, over as many frames as will fit.
        let seconds = CMTimeGetSeconds(duration)
        let frames = max(1, total / (seconds + turnaround))
        var iso = Float(wanted / (frames * seconds))

        if iso < format.minISO {
            iso = format.minISO
            // Never a frame brighter than an ordinary photograph would be.
            if pinnedShutter == nil {
                let single = CMTime(seconds: wanted / Double(format.minISO), preferredTimescale: 1_000_000)
                if CMTimeCompare(single, duration) < 0 { duration = clampedDuration(single) }
            }
        }

        return Plan(duration: duration, iso: clampedISO(iso), target: wanted)
    }
}

/// The countdown while a long exposure is open, and how far round the
/// shutter's ring should be.
///
/// Its own small observable for the reason `ExposureMeter` is one: it changes
/// every second for half a minute, and published on `CameraModel` that would be
/// the whole camera screen redrawn every second rather than the shutter and
/// one readout. The ring itself is drawn from `window` by a timeline, frame by
/// frame, rather than from anything published here.
final class LongExposureClock: ObservableObject {

    /// When the exposure opened, and how long it is meant to last.
    struct Window: Equatable {
        let start: Date
        let length: TimeInterval
    }

    /// Whole seconds left, or nil while nothing is being taken.
    @Published private(set) var remaining: Int?
    /// Nil until the first frame opens.
    @Published private(set) var window: Window?

    private var timer: Timer?

    /// The press: the count is up, the ring hasn't started. Main thread.
    func arm(seconds: Int) {
        timer?.invalidate()
        timer = nil
        window = nil
        remaining = seconds
    }

    /// From the moment the first frame opens. Main thread.
    func start(seconds: Int) {
        timer?.invalidate()
        let opened = Window(start: Date(), length: TimeInterval(seconds))
        let end = opened.start.addingTimeInterval(opened.length)
        window = opened
        remaining = seconds
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let left = max(0, Int(end.timeIntervalSinceNow.rounded(.up)))
            if left != self.remaining { self.remaining = left }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        window = nil
        remaining = nil
    }

    /// How much of the exposure has passed at `date`, from nothing to all of it.
    func progress(at date: Date) -> Double {
        guard let window, window.length > 0 else { return 0 }
        return min(max(date.timeIntervalSince(window.start) / window.length, 0), 1)
    }
}

/// One long exposure, from the first frame to the merged negative.
///
/// Its own capture delegate, so the camera's ordinary path through
/// `CameraModel` never sees these frames. One frame is on the sensor at a time:
/// the next is asked for as soon as the last has been handed over, which leaves
/// a gap between frames of however long a RAW capture takes to turn round — a
/// fraction of a second, depending on the phone, and small beside a one-second
/// frame.
///
/// Reading a frame and adding it to the stack happen on a queue of their own,
/// behind the shooting rather than in front of it, so the time they take is not
/// time the sensor sits closed — unless the stack falls behind. No more than
/// two frames wait to be added: a frame held is one the camera can't reuse,
/// and the camera only has so many.
final class LongExposureRun: NSObject, AVCapturePhotoCaptureDelegate {

    struct Outcome {
        /// The merged negative — or, when the frames couldn't be added, the
        /// first frame on its own.
        let dng: Data
        /// The first frame's metadata, with the exposure time the run spans.
        let metadata: [String: Any]
        let frames: Int
        /// What to tell the photographer, when it isn't what was asked for.
        let note: String?
    }

    enum Failure: LocalizedError {
        case nothingArrived
        case stalled
        case abandoned(String)

        var errorDescription: String? {
            switch self {
            case .nothingArrived:         return "The long exposure didn't get a frame."
            case .stalled:                return "The camera stopped answering partway through the long exposure."
            case .abandoned(let message): return message
            }
        }
    }

    /// Why the frames can't be added, found on the first one.
    private struct Incompatible: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    private let seconds: TimeInterval
    private let request: (LongExposureRun) -> Void
    private let opened: () -> Void
    private let captured: () -> Void
    private let completion: (Result<Outcome, Error>) -> Void

    /// Everything below is touched only here, except the stack. The photo
    /// output calls its delegate on a queue of its own, and every call hops
    /// onto this one.
    private let queue = DispatchQueue(label: "com.snap.long-exposure", qos: .userInitiated)
    /// The stack is added to, and merged, only here — in order, so the merge
    /// is queued behind every frame that was. At utility rather than
    /// user-initiated: this is work behind the shooting, and the viewfinder and
    /// the screen come first.
    private let addQueue = DispatchQueue(label: "com.snap.long-exposure.add", qos: .utility)

    private var frameSeconds: TimeInterval = 1
    /// The light the sum should come to, seconds times ISO, or nil for the sum
    /// as it stands; and one frame's planned exposure, for when a frame's own
    /// metadata doesn't say.
    private var target: Double?
    private var frameExposure: Double?
    private var startedAt: CFTimeInterval?
    private var openedAt: CFTimeInterval?
    private var closedAt: CFTimeInterval?
    private var template: Data?
    private var templateMetadata: [String: Any] = [:]
    private var referenceExposure: Double?
    private var raw: DNGRaw?
    private var stack: BayerStack?
    private var incompatibility: String?
    private var error: Error?
    private var isFinished = false
    private var watchdog: DispatchWorkItem?
    /// Frames handed to the stack, and how many of those it hasn't finished.
    private var absorbed = 0
    private var pendingAdds = 0
    /// The next frame is due, and waiting for the stack to catch up.
    private var isWaitingForRoom = false

    /// - Parameters:
    ///   - seconds: how long the run lasts, from the first frame opening.
    ///   - request: asks the photo output for one frame, with this run as its
    ///     delegate. Called once per frame.
    ///   - opened: the first frame has started, which is when the countdown does.
    ///   - captured: the last frame has been taken, and nothing more is wanted
    ///     of the camera — which is when the shutter can come back, though the
    ///     frames are still being added up. Called once, on the run's queue,
    ///     before `completion`.
    ///   - completion: called once, on a queue of the run's own.
    init(seconds: TimeInterval,
         request: @escaping (LongExposureRun) -> Void,
         opened: @escaping () -> Void,
         captured: @escaping () -> Void,
         completion: @escaping (Result<Outcome, Error>) -> Void) {
        self.seconds = seconds
        self.request = request
        self.opened = opened
        self.captured = captured
        self.completion = completion
    }

    /// Once the device is exposing at the plan's settings. Only the first call
    /// counts, so a fallback can be scheduled behind the real one.
    func start(frameSeconds: TimeInterval, target: Double?, frameExposure: Double?) {
        queue.async { [self] in
            guard !isFinished, startedAt == nil else { return }
            self.frameSeconds = max(frameSeconds, 0.001)
            self.target = target
            self.frameExposure = frameExposure
            startedAt = CACurrentMediaTime()
            next()
        }
    }

    /// Ends it from outside, keeping whatever has already been added.
    func abandon(_ message: String) {
        queue.async { [self] in
            guard !isFinished else { return }
            if error == nil { error = Failure.abandoned(message) }
            finish()
        }
    }

    private func next() {
        armWatchdog()
        request(self)
    }

    /// Every capture is promised an answer, but a run that waited forever for
    /// one would leave the shutter dead, so it doesn't wait forever.
    private func armWatchdog() {
        watchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isFinished else { return }
            if self.error == nil { self.error = Failure.stalled }
            self.finish()
        }
        watchdog = item
        queue.asyncAfter(deadline: .now() + frameSeconds + 10, execute: item)
    }

    // MARK: - The photo output

    func photoOutput(_ output: AVCapturePhotoOutput,
                     willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        let now = CACurrentMediaTime()
        queue.async { [self] in
            guard openedAt == nil else { return }
            openedAt = now
            opened()
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        let now = CACurrentMediaTime()
        queue.async { [self] in closedAt = now }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        queue.async { [self] in absorb(photo, error: error) }
    }

    /// Called exactly once for every frame asked for, error or not, and after
    /// everything else about it — which is what makes it the place to decide
    /// whether to ask for another.
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        queue.async { [self] in advance(error: error) }
    }

    // MARK: - Adding

    private func absorb(_ photo: AVCapturePhoto, error: Error?) {
        guard !isFinished else { return }
        if let error {
            if self.error == nil { self.error = error }
            return
        }

        let exposure = LongExposureRun.exposure(in: photo.metadata)

        var first: DNGRaw?
        if template == nil {
            // The first frame is the template the merge is written into, and
            // the test of whether a frame can be read back at all.
            guard let data = photo.fileDataRepresentation() else {
                if self.error == nil {
                    self.error = Failure.abandoned("The first frame of the long exposure couldn't be read.")
                }
                return
            }
            template = data
            templateMetadata = photo.metadata
            referenceExposure = exposure
            do {
                let raw = try DNGRaw(data)
                try LongExposureRun.check(raw, beside: photo.pixelBuffer)
                self.raw = raw
                stack = BayerStack(raw: raw)
                first = raw
            } catch {
                incompatibility = error.localizedDescription
                return
            }
        }

        guard let stack else { return }

        // Weighted by the light the frame was set to collect, should the
        // camera have moved its exposure between frames.
        var relative = 1.0
        if let reference = referenceExposure, let exposure, reference > 0 {
            relative = exposure / reference
        }
        let weight = relative
        let firstFrame = first

        absorbed += 1
        pendingAdds += 1
        addQueue.async { [self] in
            // Packaging a frame as a DNG and reading it back are the slow
            // halves of it, so both happen here rather than on the run's queue.
            let failure: Error?
            do {
                let raw: DNGRaw
                if let firstFrame {
                    raw = firstFrame
                } else {
                    guard let data = photo.fileDataRepresentation() else {
                        throw Failure.abandoned("A frame of the long exposure couldn't be read.")
                    }
                    raw = try DNGRaw(data)
                }
                try stack.add(raw, exposure: weight)
                failure = nil
            } catch {
                failure = error
            }

            queue.async { [self] in
                pendingAdds -= 1
                if let failure, self.error == nil { self.error = failure }
                guard !isFinished, isWaitingForRoom else { return }
                isWaitingForRoom = false
                // Nothing is on the sensor while the run waits for room, so a
                // failure here is the end of it rather than the next frame's
                // answer.
                if self.error != nil {
                    finish()
                } else {
                    next()
                }
            }
        }
    }

    private func advance(error: Error?) {
        guard !isFinished else { return }
        watchdog?.cancel()
        if let error, self.error == nil { self.error = error }

        let now = CACurrentMediaTime()
        let elapsed = now - (openedAt ?? startedAt ?? now)
        // Another frame only if most of it fits in what is left.
        let wantsMore = self.error == nil
            && stack != nil
            && absorbed < LongExposure.maxFrames
            && elapsed + frameSeconds / 2 < seconds

        if !wantsMore {
            finish()
        } else if pendingAdds >= 2 {
            isWaitingForRoom = true
        } else {
            next()
        }
    }

    /// Stops asking for frames, hands the camera back, and merges once the
    /// last frame has been added.
    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        isWaitingForRoom = false
        watchdog?.cancel()
        captured()

        guard let template else {
            let failure = error ?? Failure.nothingArrived
            addQueue.async { [self] in completion(.failure(failure)) }
            return
        }

        let measured = (closedAt ?? 0) - (openedAt ?? 0)
        let span = (max(frameSeconds, measured) * 10).rounded() / 10
        let metadata = templateMetadata
        let raw = self.raw
        let stack = self.stack
        let incompatibility = self.incompatibility
        let failure = error
        let target = self.target
        let reference = referenceExposure ?? frameExposure

        // Behind every add already queued, since this queue is serial — so
        // what the stack holds by now is everything that will go in.
        addQueue.async { [self] in
            let added = stack?.frames ?? 0
            var note: String?
            if let failure {
                note = added > 0
                    ? "The long exposure stopped after \(added == 1 ? "one frame" : "\(added) frames"): \(failure.localizedDescription)"
                    : "The long exposure's frames couldn't be read, so the first was kept on its own: \(failure.localizedDescription)"
            }
            if let raw, let stack, added > 0 {
                // The sum as it stands, or brought to the meter's light: the
                // stack counts exposure in units of the first frame's.
                var scale = 1.0
                if let target, let reference, reference > 0, stack.exposure > 0 {
                    scale = target / (reference * stack.exposure)
                }
                do {
                    let dng = try raw.replacingImage(with: stack.merged(scale: scale),
                                                     exposureTime: span,
                                                     noise: (signal: scale,
                                                             floor: scale * scale * Double(stack.frames)))
                    completion(.success(Outcome(dng: dng,
                                                metadata: LongExposureRun.stamped(metadata, seconds: span),
                                                frames: stack.frames,
                                                note: note)))
                    return
                } catch {
                    note = "The frames couldn't be merged, so the first was kept on its own. \(error.localizedDescription)"
                }
            } else if let incompatibility {
                let reason = incompatibility.hasSuffix(".") ? incompatibility : incompatibility + "."
                note = "This camera's RAW frames couldn't be added together, so the first was kept on its own: \(reason)"
            }
            completion(.success(Outcome(dng: template, metadata: metadata, frames: 1, note: note)))
        }
    }

    // MARK: - Helpers

    /// Shutter times ISO, which is what a frame's numbers scale with.
    static func exposure(in metadata: [String: Any]) -> Double? {
        guard let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let time = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue,
              let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue,
              time > 0, iso > 0 else { return nil }
        return time * iso
    }

    /// The metadata a merged frame carries: the first frame's, with the time
    /// the run spans as its exposure. That is the number the frame's readout
    /// shows, and the one a photographer would give for it.
    static func stamped(_ metadata: [String: Any], seconds: TimeInterval) -> [String: Any] {
        var stamped = metadata
        var exif = stamped[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        exif[kCGImagePropertyExifExposureTime as String] = seconds
        // The APEX form of the same thing, which would otherwise still say a second.
        exif.removeValue(forKey: kCGImagePropertyExifShutterSpeedValue as String)
        stamped[kCGImagePropertyExifDictionary as String] = exif
        return stamped
    }

    /// Whether the first frame's DNG reads back as something believable: one
    /// tile is decoded, and its numbers must stay within the white level the
    /// DNG itself states. A decoder that had misread the file would not keep
    /// to it.
    ///
    /// The pixel buffer is set beside that tile too, but only to say in the
    /// console how the two differ — nothing is decided by it.
    static func check(_ raw: DNGRaw, beside buffer: CVPixelBuffer?) throws {
        let tile = try raw.segmentSamples(0)
        let white = UInt16(clamping: Int(raw.whiteLevel.rounded()))
        var over = 0
        tile.withUnsafeBufferPointer { samples in
            for sample in samples where sample > white { over += 1 }
        }
        if over * 1000 > tile.count {
            throw Incompatible(reason: "its DNG reads back as numbers past its own white level")
        }
        if let buffer {
            log.notice("\(describe(buffer, beside: raw, tile: tile), privacy: .public)")
        }
    }

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Snap",
                                    category: "LongExposure")

    /// How a frame's pixel buffer compares with its DNG, as one line: the
    /// buffer's format and shape, how many of the first tile's photosites are
    /// the same number in both, and the straight line that best takes the
    /// DNG's numbers to the buffer's, with how far from it the buffer strays.
    ///
    /// A buffer that is the DNG shifted or offset fits the line exactly; one
    /// with lens shading or defect correction the other lacks does not.
    static func describe(_ buffer: CVPixelBuffer, beside raw: DNGRaw, tile: [UInt16]) -> String {
        let type = CVPixelBufferGetPixelFormatType(buffer)
        let code = String([24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((type >> UInt32($0)) & 0xFF))) })
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var line = "Long exposure: pixel buffer '\(code)' \(width)×\(height), \(bytesPerRow) bytes a row; "
            + "DNG \(raw.width)×\(raw.height), black \(raw.blackLevels), white \(raw.whiteLevel)"

        guard width == raw.width, height == raw.height, bytesPerRow >= width * 2,
              !CVPixelBufferIsPlanar(buffer) else {
            return line + "; not compared"
        }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return line + "; buffer unreadable" }

        let rect = raw.segmentRect(0)
        let rows = min(rect.height, height - rect.y)
        let columns = min(rect.width, width - rect.x)
        func pair(_ row: Int, _ column: Int) -> (dng: Double, buffer: Double) {
            let samples = (UnsafeRawPointer(base) + (rect.y + row) * bytesPerRow)
                .assumingMemoryBound(to: UInt16.self)
            return (Double(tile[row * rect.width + column]), Double(samples[rect.x + column]))
        }

        var n = 0.0, sumX = 0.0, sumY = 0.0, sumXX = 0.0, sumXY = 0.0
        var equal = 0
        var lowest = Double.infinity, highest = -Double.infinity
        for row in 0..<rows {
            for column in 0..<columns {
                let (x, y) = pair(row, column)
                n += 1; sumX += x; sumY += y; sumXX += x * x; sumXY += x * y
                if x == y { equal += 1 }
                lowest = min(lowest, y); highest = max(highest, y)
            }
        }
        guard n > 1 else { return line + "; nothing to compare" }
        let spread = n * sumXX - sumX * sumX
        let slope = spread != 0 ? (n * sumXY - sumX * sumY) / spread : 0
        let offset = (sumY - slope * sumX) / n

        var squares = 0.0, worst = 0.0
        for row in 0..<rows {
            for column in 0..<columns {
                let (x, y) = pair(row, column)
                let residual = abs(y - (slope * x + offset))
                squares += residual * residual
                worst = max(worst, residual)
            }
        }

        line += String(format: "; first tile: %.2f%% equal, buffer ≈ %.4f × DNG %+.1f, rms off by %.2f, worst %.1f, buffer %.0f–%.0f",
                       Double(equal) / n * 100, slope, offset, (squares / n).squareRoot(), worst, lowest, highest)
        return line
    }
}
