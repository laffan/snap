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
import UIKit

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
                        orientation: CGImagePropertyOrientation?,
                        scale: Float = 1) throws -> CIImage {
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

        // Demosaicing a 12MP frame to fill a phone-sized square is wasted work;
        // the RAW pipeline can produce the smaller image directly.
        if scale < 1 {
            filter.scaleFactor = scale
        }

        guard let image = filter.outputImage else { throw DevelopError.undecodable }
        return image
    }

    /// The negative developed and cropped to the same square as the JPEG, with
    /// no look applied, at roughly the size asked for.
    ///
    /// `CIRAWFilter` can demosaic straight to a smaller image, so a viewer-sized
    /// preview never pays for a full-sensor development.
    static func developedImage(at url: URL,
                               profile: PositiveFilmProfile,
                               maxPixelSize: CGFloat) -> CIImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let properties = self.properties(of: data)

        var scale: Float = 1
        if let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.doubleValue,
           width > 0 {
            scale = Float(min(1, maxPixelSize / width))
        }

        guard let developed = try? develop(dngData: data,
                                           profile: profile,
                                           orientation: orientation(from: properties),
                                           scale: scale) else {
            return nil
        }
        return developed.centerSquareCropped()
    }

    /// The negative as it stands — what the hold-to-peek gesture shows.
    static func previewImage(at url: URL,
                             profile: PositiveFilmProfile,
                             maxPixelSize: CGFloat,
                             context: CIContext) -> UIImage? {
        guard let square = developedImage(at: url, profile: profile, maxPixelSize: maxPixelSize),
              let cgImage = context.createCGImage(square, from: square.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// The file's own metadata, which the derived JPEG carries forward.
    static func properties(of dngData: Data) -> [String: Any] {
        guard let source = CGImageSourceCreateWithData(dngData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return [:]
        }
        return properties
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
