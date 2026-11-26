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
//  What the frames are exposed at is the meter's, unless a pin says otherwise.
//  In auto, the light the meter wants is spread over the longest frame the
//  format allows at the lowest ISO that gets there — a dark street metered at
//  1/8 and ISO 2000 becomes one second at ISO 250 — since a long frame at low
//  gain is less noise for the same light. With either half pinned, the frames are what
//  the photographer chose.
//
//  The frames are added from the pixel buffers AVFoundation hands over, which
//  are the sensor data before anything is packaged. Nothing promises those
//  hold exactly the numbers the DNG does, so the first frame is checked: one of
//  its DNG's tiles is decoded and compared with the same corner of its buffer.
//  If they disagree, the frames aren't added — the first one is kept as an
//  ordinary photograph, and the reason is said.
//

import AVFoundation
import Combine
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import QuartzCore

enum LongExposure {

    /// What the dial reaches, in seconds.
    static let range: ClosedRange<Int> = 2...30
    /// Where it starts, and where a double tap puts it back.
    static let defaultSeconds = 10
    /// A ceiling for a bright scene, where the frames are short and many. The
    /// running total is a float per photosite, which stays exact far past this.
    static let maxFrames = 400

    /// How the frames are exposed.
    struct Plan {
        let duration: CMTime
        let iso: Float

        var seconds: TimeInterval { CMTimeGetSeconds(duration) }
    }

    /// The frame exposure for a run of `total` seconds. Session queue — it
    /// reads what the device is doing now.
    ///
    /// With a pin, the pins stand, and the half that isn't pinned is wherever
    /// the priority mode has been holding it. In auto, the meter's reading is
    /// taken as one quantity — seconds times ISO, corrected by how far the
    /// meter says it is off — and handed to the longest frame that doesn't
    /// need an ISO below the sensor's base.
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

        if pinnedShutter != nil || pinnedISO != nil {
            return Plan(duration: clampedDuration(pinnedShutter ?? current),
                        iso: clampedISO(pinnedISO ?? currentISO))
        }

        // Past four stops the meter is guessing, and auto has usually gone as
        // far as it can anyway.
        let offset = Double(min(max(device.exposureTargetOffset, -4), 4))
        let wanted = CMTimeGetSeconds(current) * Double(currentISO) * pow(2, -offset)
        guard wanted.isFinite, wanted > 0 else {
            return Plan(duration: clampedDuration(current), iso: clampedISO(currentISO))
        }

        let duration = clampedDuration(CMTime(seconds: wanted / Double(format.minISO),
                                              preferredTimescale: 1_000_000))
        return Plan(duration: duration,
                    iso: clampedISO(Float(wanted / CMTimeGetSeconds(duration))))
    }
}

/// The countdown while a long exposure is open.
///
/// Its own small observable for the reason `ExposureMeter` is one: it changes
/// every second for half a minute, and published on `CameraModel` that would be
/// the whole camera screen redrawn every second rather than one readout.
final class LongExposureClock: ObservableObject {

    /// Whole seconds left, or nil while nothing is being taken.
    @Published private(set) var remaining: Int?

    private var timer: Timer?

    /// From the moment the first frame opens. Main thread.
    func start(seconds: Int) {
        timer?.invalidate()
        let end = Date().addingTimeInterval(TimeInterval(seconds))
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
        remaining = nil
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
/// Adding a frame to the stack happens on a queue of its own, behind the
/// shooting rather than in front of it, so the time it takes is never time the
/// sensor sits closed. No more than two frames wait to be added: a pixel buffer
/// held is one the camera can't reuse, and the camera only has so many.
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
    private let completion: (Result<Outcome, Error>) -> Void

    /// Everything below is touched only here, except the stack. The photo
    /// output calls its delegate on a queue of its own, and every call hops
    /// onto this one.
    private let queue = DispatchQueue(label: "com.snap.long-exposure", qos: .userInitiated)
    /// The stack is added to, and merged, only here — in order, so the merge
    /// is queued behind every frame that was.
    private let addQueue = DispatchQueue(label: "com.snap.long-exposure.add", qos: .userInitiated)

    private var frameSeconds: TimeInterval = 1
    private var startedAt: CFTimeInterval?
    private var openedAt: CFTimeInterval?
    private var closedAt: CFTimeInterval?
    private var template: Data?
    private var templateMetadata: [String: Any] = [:]
    private var referenceExposure: Double?
    private var raw: DNGRaw?
    private var stack: BayerStack?
    private var bufferScale: Float = 1
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
    ///   - completion: called once, on a queue of the run's own.
    init(seconds: TimeInterval,
         request: @escaping (LongExposureRun) -> Void,
         opened: @escaping () -> Void,
         completion: @escaping (Result<Outcome, Error>) -> Void) {
        self.seconds = seconds
        self.request = request
        self.opened = opened
        self.completion = completion
    }

    /// Once the device is exposing at the plan's settings. Only the first call
    /// counts, so a fallback can be scheduled behind the real one.
    func start(frameSeconds: TimeInterval) {
        queue.async { [self] in
            guard !isFinished, startedAt == nil else { return }
            self.frameSeconds = max(frameSeconds, 0.001)
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

        if template == nil {
            // The first frame is the template the merge is written into, and
            // the test of whether its buffer can be added at all.
            guard let data = photo.fileDataRepresentation() else {
                if self.error == nil { self.error = Failure.abandoned("The first frame of the long exposure couldn't be read.") }
                return
            }
            template = data
            templateMetadata = photo.metadata
            referenceExposure = LongExposureRun.exposure(in: photo.metadata)
            do {
                guard let buffer = photo.pixelBuffer else {
                    throw Incompatible(reason: "the camera didn't hand over its sensor data")
                }
                let raw = try DNGRaw(data)
                bufferScale = try LongExposureRun.scale(of: buffer, against: raw)
                self.raw = raw
                stack = BayerStack(raw: raw)
            } catch {
                incompatibility = error.localizedDescription
                return
            }
        }

        guard let stack, let buffer = photo.pixelBuffer,
              CVPixelBufferGetWidth(buffer) == stack.width,
              CVPixelBufferGetHeight(buffer) == stack.height else { return }

        // Weighted by the light the frame was set to collect, should the
        // camera have moved its exposure between frames.
        let relative: Double
        if let reference = referenceExposure,
           let exposure = LongExposureRun.exposure(in: photo.metadata) {
            relative = exposure / reference
        } else {
            relative = 1
        }

        absorbed += 1
        pendingAdds += 1
        let scale = bufferScale
        addQueue.async { [self] in
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                stack.add(UnsafeRawPointer(base),
                          bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                          exposure: relative,
                          scale: scale)
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)

            queue.async { [self] in
                pendingAdds -= 1
                if isWaitingForRoom, !isFinished {
                    isWaitingForRoom = false
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

    /// Stops asking for frames, and merges once the last one has been added.
    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        isWaitingForRoom = false
        watchdog?.cancel()

        guard let template else {
            let failure = error ?? Failure.nothingArrived
            addQueue.async { [self] in completion(.failure(failure)) }
            return
        }

        let frames = absorbed
        let measured = (closedAt ?? 0) - (openedAt ?? 0)
        let span = (max(frameSeconds, measured) * 10).rounded() / 10
        let metadata = templateMetadata
        let raw = self.raw
        let stack = self.stack
        let incompatibility = self.incompatibility

        let stopped = error.map { error -> String in
            let count = frames == 1 ? "one frame" : "\(frames) frames"
            return "The long exposure stopped after \(count): \(error.localizedDescription)"
        }

        // Behind every add already queued, since this queue is serial.
        addQueue.async { [self] in
            var note = stopped
            if let raw, let stack, stack.frames > 0 {
                do {
                    let dng = try raw.replacingImage(with: stack.merged(),
                                                     exposureTime: span,
                                                     noiseScale: 1 / max(stack.exposure, 1))
                    completion(.success(Outcome(dng: dng,
                                                metadata: LongExposureRun.stamped(metadata, seconds: span),
                                                frames: stack.frames,
                                                note: note)))
                    return
                } catch {
                    note = "The frames couldn't be merged, so the first was kept on its own. \(error.localizedDescription)"
                }
            } else if let incompatibility {
                note = "This camera's RAW frames couldn't be added together, so the first was kept on its own: \(incompatibility)."
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

    /// Whether a pixel buffer holds the numbers the DNG does, and if so what
    /// takes one to the other: 1 when they are the same, a half or a quarter
    /// when the buffer holds them a bit or two higher.
    ///
    /// Checked on the first tile, decoded out of the DNG and set against the
    /// same corner of the buffer, photosite by photosite.
    static func scale(of buffer: CVPixelBuffer, against raw: DNGRaw) throws -> Float {
        guard !CVPixelBufferIsPlanar(buffer) else {
            throw Incompatible(reason: "its sensor data comes in planes")
        }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width == raw.width, height == raw.height else {
            throw Incompatible(reason: "its sensor data is \(width)×\(height) and its DNG \(raw.width)×\(raw.height)")
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard bytesPerRow >= width * 2 else {
            throw Incompatible(reason: "its sensor data isn't 16 bits a photosite")
        }

        let rect = raw.segmentRect(0)
        let tile = try raw.segmentSamples(0)
        let rows = min(rect.height, height - rect.y)
        let columns = min(rect.width, width - rect.x)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw Incompatible(reason: "its sensor data can't be read")
        }

        for shift in 0...4 {
            var matches = true
            check: for row in 0..<rows {
                let line = (UnsafeRawPointer(base) + (rect.y + row) * bytesPerRow)
                    .assumingMemoryBound(to: UInt16.self)
                for column in 0..<columns
                where line[rect.x + column] != tile[row * rect.width + column] << UInt16(shift) {
                    matches = false
                    break check
                }
            }
            if matches { return 1 / Float(1 << shift) }
        }
        throw Incompatible(reason: "its sensor data and its DNG hold different numbers")
    }
}
