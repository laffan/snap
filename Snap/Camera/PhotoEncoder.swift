//
//  PhotoEncoder.swift
//  Snap
//
//  Writes finished frames as JPEG with the look that made them embedded in
//  EXIF, and reads that look back out.
//
//  Every capture carries its settings, whether or not the filter editor was
//  ever opened — so any file that leaves the app, by camera roll or by share,
//  is self-describing.
//

import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PhotoEncoder {

    static let compressionQuality: CGFloat = 0.95
    static let softwareTag = "Snap 1.0"

    enum EncodeError: LocalizedError {
        case render
        case destination

        var errorDescription: String? {
            switch self {
            case .render:      return "The photo could not be rendered."
            case .destination: return "The photo could not be encoded."
            }
        }
    }

    /// What gets written into the EXIF user comment.
    private struct Envelope: Codable {
        var app: String
        var version: Int
        var profile: PositiveFilmProfile
    }

    private static let appTag = "Snap"
    private static let formatVersion = 1

    // MARK: - Writing

    static func jpeg(from image: CIImage,
                     profile: PositiveFilmProfile,
                     sourceMetadata: [String: Any],
                     context: CIContext) throws -> Data {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cgImage = context.createCGImage(image,
                                                  from: image.extent,
                                                  format: .RGBA8,
                                                  colorSpace: colorSpace) else {
            throw EncodeError.render
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw EncodeError.destination
        }

        let properties = properties(profile: profile,
                                    source: sourceMetadata,
                                    size: image.extent.size)
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else { throw EncodeError.destination }
        return output as Data
    }

    /// Starts from the camera's own metadata — exposure, ISO, lens, timestamp —
    /// and adds our own on top, so a Snap frame still reads like a photograph
    /// in anything that inspects it.
    private static func properties(profile: PositiveFilmProfile,
                                   source: [String: Any],
                                   size: CGSize) -> [String: Any] {
        var properties = source

        // Orientation is already baked into the pixels by this point. Carrying
        // the sensor's original value forward would make Photos rotate the
        // image a second time.
        properties[kCGImagePropertyOrientation as String] = 1
        properties[kCGImageDestinationLossyCompressionQuality as String] = compressionQuality

        var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        exif[kCGImagePropertyExifUserComment as String] = userComment(for: profile)
        // The frame was cropped square after capture, so the recorded
        // dimensions no longer match.
        exif[kCGImagePropertyExifPixelXDimension as String] = Int(size.width)
        exif[kCGImagePropertyExifPixelYDimension as String] = Int(size.height)
        properties[kCGImagePropertyExifDictionary as String] = exif

        var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiff[kCGImagePropertyTIFFSoftware as String] = softwareTag
        tiff[kCGImagePropertyTIFFOrientation as String] = 1
        properties[kCGImagePropertyTIFFDictionary as String] = tiff

        return properties
    }

    private static func userComment(for profile: PositiveFilmProfile) -> String {
        let envelope = Envelope(app: appTag, version: formatVersion, profile: profile)
        guard let data = try? JSONEncoder().encode(envelope),
              let json = String(data: data, encoding: .utf8) else {
            return appTag
        }
        return json
    }

    // MARK: - Reading

    /// Recovers the look from a file Snap wrote. Returns nil for anything else.
    static func profile(fromImageAt url: URL) -> PositiveFilmProfile? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return profile(fromImageSource: source)
    }

    static func profile(fromJPEG data: Data) -> PositiveFilmProfile? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return profile(fromImageSource: source)
    }

    private static func profile(fromImageSource source: CGImageSource) -> PositiveFilmProfile? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let comment = exif[kCGImagePropertyExifUserComment as String] as? String,
              let data = comment.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.app == appTag else {
            return nil
        }
        return envelope.profile
    }
}
