//
//  RAWDeveloper.swift
//  Snap
//
//  Develops a Bayer RAW capture ourselves instead of letting Apple hand us a
//  finished JPEG.
//
//  A DNG holds undemosaiced sensor data, so there is no way to write a grade
//  *into* one — the look would have to survive being re-mosaiced, which throws
//  away most of what it did. What is possible, and what this does, is move the
//  grade to the other end: demosaic the sensor data ourselves with every piece
//  of Apple's cosmetic processing switched off, and apply the look to that
//  rather than to their finished output.
//
//  What gets bypassed, unconditionally:
//    · luminance and colour noise reduction
//    · sharpening and detail enhancement
//    · local tone mapping
//    · contrast and moiré reduction
//    · gamut mapping
//
//  What stays negotiable is the global tone curve, which is a rendering
//  intent rather than processing — see `PositiveFilmProfile.rawBoost`.
//

import CoreImage
import Foundation
import ImageIO

enum RAWDeveloper {

    enum DevelopError: LocalizedError {
        case notRAW
        case undecodable

        var errorDescription: String? {
            switch self {
            case .notRAW:      return "That capture had no RAW data."
            case .undecodable: return "The RAW file could not be developed."
            }
        }
    }

    /// Demosaics `dngData` with Apple's processing disabled and returns the
    /// image in the context's working space, upright.
    static func develop(dngData: Data,
                        profile: PositiveFilmProfile,
                        orientation: CGImagePropertyOrientation?) throws -> CIImage {
        guard let filter = CIRAWFilter(imageData: dngData, identifierHint: nil) else {
            throw DevelopError.undecodable
        }

        // Everything Apple would otherwise do to make a JPEG look good.
        //
        // The two amounts below are the whole noise-reduction surface the
        // CIRAWFilter class exposes. The finer-grained noiseReduction* knobs
        // belong to the older CIFilter(imageData:options:) key-based API and
        // have no equivalent here.
        filter.luminanceNoiseReductionAmount = 0
        filter.colorNoiseReductionAmount = 0
        filter.sharpnessAmount = 0
        filter.detailAmount = 0
        filter.contrastAmount = 0
        filter.moireReductionAmount = 0
        filter.localToneMapAmount = 0
        filter.isGamutMappingEnabled = false

        // The global tone curve. At 0 the response is linear to the scene,
        // which is the fullest bypass available through this API.
        filter.boostAmount = profile.rawBoostAmount
        filter.boostShadowAmount = 0

        if let orientation {
            filter.orientation = orientation
        }

        guard let image = filter.outputImage else { throw DevelopError.undecodable }
        return image
    }

    /// Reads the orientation the sensor recorded, so the developed frame comes
    /// out upright the way the processed path does.
    static func orientation(from metadata: [String: Any]) -> CGImagePropertyOrientation? {
        guard let raw = metadata[kCGImagePropertyOrientation as String] as? UInt32 else {
            return nil
        }
        return CGImagePropertyOrientation(rawValue: raw)
    }
}
