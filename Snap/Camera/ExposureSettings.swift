//
//  ExposureSettings.swift
//  Snap
//
//  The exposure controls a phone can actually offer.
//
//  Aperture isn't one of them. An iPhone lens has a fixed iris —
//  `AVCaptureDevice.lensAperture` is read-only because there is nothing to
//  move — so aperture priority would be indistinguishable from auto, and there
//  is no f-number worth putting on screen: one lens has one, and it never
//  changes.
//
//  Shutter and ISO are real: `setExposureModeCustom(duration:iso:)` takes
//  both.
//

import AVFoundation
import Combine
import CoreMedia
import Foundation

/// What the meter is reading, kept apart from everything else.
///
/// `exposureTargetOffset` moves continuously, so anything that republishes on
/// it republishes several times a second. Held on `CameraModel` that invalidated
/// the whole camera screen at that rate — the roll included — which is enough
/// to make a long-press menu flicker and drop the tap that follows it. Here
/// only the two readouts that want these numbers are watching them.
final class ExposureMeter: ObservableObject {

    /// How far the current exposure sits from the meter's target, in stops.
    /// Negative is under.
    @Published private(set) var offset: Float = 0

    /// What the camera is actually running at, which is what the buttons show
    /// while it is the camera deciding, and where manual starts from when it
    /// takes over.
    @Published private(set) var iso: Float = 100
    /// The same, for the shutter, in seconds.
    @Published private(set) var duration: Float = 1.0 / 60

    /// Filtered to what the readout can actually show — a tenth of a stop.
    /// Anything finer is a redraw nobody can see.
    func report(offset value: Float) {
        guard abs(value - offset) >= 0.05 else { return }
        offset = value
    }

    /// Same idea at ISO's resolution: the readout is whole numbers.
    func report(iso value: Float) {
        guard value > 0, abs(value - iso) >= 1 else { return }
        iso = value
    }

    /// And the same for the shutter, in stops rather than in seconds: the
    /// difference between 1/60 and 1/61 is not worth a redraw, and the
    /// difference between 1" and 1/2" is the same size.
    func report(duration value: Float) {
        guard value > 0, duration > 0, abs(log2(value / duration)) >= 0.06 else { return }
        duration = value
    }
}

/// How much of the exposure the photographer is deciding.
///
/// Not a setting any more but a reading of two: the shutter and the ISO are
/// each either pinned or the camera's, and the four combinations have the four
/// names below. Nothing sets this — pinning one of the two is what moves it.
enum ExposureMode: String, CaseIterable, Identifiable {
    /// The camera decides both.
    case auto
    /// The shutter is pinned and ISO follows the meter.
    case shutterPriority
    /// ISO is pinned and the shutter follows the meter. iOS has no such mode;
    /// like shutter priority it is built on top of the custom one.
    case isoPriority
    /// Both pinned, nothing tracking.
    case manual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto:            return "Auto"
        case .shutterPriority: return "Shutter priority"
        case .isoPriority:     return "ISO priority"
        case .manual:          return "Manual"
        }
    }
}

struct ShutterSpeed: Identifiable, Equatable {
    let label: String
    let duration: CMTime

    var id: String { label }

    /// A conventional stop sequence, fastest first. Trimmed to whatever the
    /// active format will accept.
    static let all: [ShutterSpeed] = [
        (1, 8000, "1/8000"), (1, 4000, "1/4000"), (1, 2000, "1/2000"),
        (1, 1000, "1/1000"), (1, 500, "1/500"), (1, 250, "1/250"),
        (1, 125, "1/125"), (1, 60, "1/60"), (1, 30, "1/30"),
        (1, 15, "1/15"), (1, 8, "1/8"), (1, 4, "1/4"),
        (1, 2, "1/2"), (1, 1, "1\""),
    ].map { ShutterSpeed(label: $0.2, duration: CMTimeMake(value: Int64($0.0), timescale: Int32($0.1))) }

    static func supported(by format: AVCaptureDevice.Format) -> [ShutterSpeed] {
        all.filter {
            CMTimeCompare($0.duration, format.minExposureDuration) >= 0 &&
            CMTimeCompare($0.duration, format.maxExposureDuration) <= 0
        }
    }

    var seconds: Float { Float(CMTimeGetSeconds(duration)) }

    /// How a duration reads on a button. The camera's own choice lands between
    /// the stops — 1/47 is a perfectly ordinary thing for auto to pick — so
    /// this rounds the fraction rather than snapping to the list.
    static func label(forSeconds seconds: Float) -> String {
        guard seconds > 0 else { return "—" }
        if seconds >= 1 { return String(format: "%.1f\"", seconds) }
        return "1/\(Int((1 / seconds).rounded()))"
    }

    /// The listed stop closest to a duration, measured in stops rather than in
    /// seconds — which is what makes 1/8000 and 1/4000 as far apart as 1/2 and
    /// 1". Used when pinning takes over from the camera.
    static func nearest(toSeconds seconds: Float, in speeds: [ShutterSpeed]) -> ShutterSpeed? {
        guard seconds > 0 else { return speeds.first }
        return speeds.min {
            abs(log2($0.seconds / seconds)) < abs(log2($1.seconds / seconds))
        }
    }
}

enum ISOSetting {
    /// The stops offered in the picker, trimmed to the active format.
    static let all: [Float] = [25, 50, 100, 200, 400, 800, 1600, 3200, 6400]

    static func supported(by format: AVCaptureDevice.Format) -> [Float] {
        all.filter { $0 >= format.minISO && $0 <= format.maxISO }
    }

    static func label(_ iso: Float?) -> String {
        guard let iso else { return "AUTO" }
        return String(Int(iso.rounded()))
    }

    /// The listed stop closest to what the camera has arrived at, in stops for
    /// the same reason as the shutter's.
    static func nearest(to value: Float, in options: [Float]) -> Float? {
        guard value > 0 else { return options.first }
        return options.min { abs(log2($0 / value)) < abs(log2($1 / value)) }
    }
}
