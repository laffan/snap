//
//  ExposureSettings.swift
//  Snap
//
//  The exposure controls a phone can actually offer.
//
//  Aperture isn't one of them. An iPhone lens has a fixed iris —
//  `AVCaptureDevice.lensAperture` is read-only because there is nothing to
//  move — so aperture priority would be indistinguishable from auto. The
//  f-number is worth showing, since it sets what the other two have to work
//  around, but it is a readout rather than a control.
//
//  Shutter and ISO are real: `setExposureModeCustom(duration:iso:)` takes
//  both.
//

import AVFoundation
import CoreMedia
import Foundation

/// How much of the exposure the photographer is deciding.
enum ExposureMode: String, CaseIterable, Identifiable {
    /// The camera decides everything.
    case auto
    /// Shutter priority: the shutter is chosen, ISO follows to balance it.
    case shutter
    /// Both chosen, nothing tracking.
    case manual

    var id: String { rawValue }

    /// The letter on the button. Auto has none — it is the state with nothing
    /// lit.
    var label: String {
        switch self {
        case .auto:    return ""
        case .shutter: return "S"
        case .manual:  return "M"
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
