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

    /// What the camera is actually running at, which is where manual starts
    /// from when it takes over.
    @Published private(set) var iso: Float = 100

    /// Filtered to what the readout can actually show — a tenth of a stop.
    /// Anything finer is a redraw nobody can see.
    func report(offset value: Float) {
        guard abs(value - offset) >= 0.05 else { return }
        offset = value
    }

    /// Same idea at ISO's resolution: the readout is whole numbers.
    func report(iso value: Float) {
        guard abs(value - iso) >= 1 else { return }
        iso = value
    }
}

/// How much of the exposure the photographer is deciding.
enum ExposureMode: String, CaseIterable, Identifiable {
    /// The camera decides everything.
    case auto
    /// Shutter priority: the shutter is chosen, ISO follows to balance it.
    case shutter
    /// Both chosen, nothing tracking.
    case manual

    var id: String { rawValue }

    /// The letter on the button. Auto has one of its own: it is a mode to be
    /// chosen, not the state left over when nothing is lit.
    var label: String {
        switch self {
        case .auto:    return "A"
        case .shutter: return "S"
        // Spelled out as the two things it pins, since "M" said nothing about
        // which knobs stop moving.
        case .manual:  return "S/I"
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
}
