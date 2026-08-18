//
//  RAWCropper.swift
//  Snap
//
//  Crops a DNG to the same square the JPEG gets.
//
//  Nothing here touches sensor pixels. A DNG carries DefaultCropOrigin and
//  DefaultCropSize — the rectangle a raw converter should show by default,
//  which iPhone files already use to trim the sensor's edge — so squaring the
//  file is a matter of narrowing that rectangle. The mosaic stays whole, the
//  crop stays reversible in any converter, and `CIRAWFilter` honours the same
//  tags, so re-developing a stored negative comes out square too.
//
//  The catch is that rewriting a DNG means ImageIO has to be able to *write*
//  the container, and it can only write the types it advertises. That is
//  checked at runtime rather than assumed — see `isSupported`.
//

import Foundation
import ImageIO

enum RAWCropper {

    /// The DNG type identifier, as reported by an image source for these files.
    private static let dngType = "com.adobe.raw-image"

    /// Whether ImageIO on this device can author the RAW container at all.
    ///
    /// If it can't there is no way to hand back a modified DNG through system
    /// APIs, and callers keep the original full-frame file.
    static var isSupported: Bool {
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return writable.contains(dngType)
    }

    /// Returns a DNG whose default crop is the largest centred square, or nil
    /// if the file can't be rewritten — in which case the original still
    /// stands, uncropped.
    static func squareCropped(_ dngData: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(dngData as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let square = squareCrop(in: properties) else {
            return nil
        }

        var dng = properties[kCGImagePropertyDNGDictionary as String] as? [String: Any] ?? [:]
        dng[kCGImagePropertyDNGDefaultCropOrigin as String] = [square.x, square.y]
        dng[kCGImagePropertyDNGDefaultCropSize as String] = [square.edge, square.edge]

        var updated = properties
        updated[kCGImagePropertyDNGDictionary as String] = dng

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImageFromSource(destination, source, 0, updated as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        return output as Data
    }

    // MARK: - Geometry

    private struct Square {
        var x: Int
        var y: Int
        var edge: Int
    }

    /// The centred square inside whatever rectangle the file currently calls
    /// its default crop.
    ///
    /// This is the same rectangle `centerSquareCropped()` takes for the JPEG:
    /// `CIRAWFilter` develops the default-crop area, and a centred square of
    /// that area is what both paths end up with. Orientation doesn't enter into
    /// it — a centred square is the same rectangle whichever way the frame is
    /// rotated for display.
    private static func squareCrop(in properties: [String: Any]) -> Square? {
        let dng = properties[kCGImagePropertyDNGDictionary as String] as? [String: Any]

        let origin = numbers(dng?[kCGImagePropertyDNGDefaultCropOrigin as String])
        let size = numbers(dng?[kCGImagePropertyDNGDefaultCropSize as String])

        let originX = origin.count == 2 ? origin[0] : 0
        let originY = origin.count == 2 ? origin[1] : 0

        let width: Double
        let height: Double
        if size.count == 2, size[0] > 0, size[1] > 0 {
            width = size[0]
            height = size[1]
        } else if let pixelWidth = properties[kCGImagePropertyPixelWidth as String] as? Double,
                  let pixelHeight = properties[kCGImagePropertyPixelHeight as String] as? Double {
            width = pixelWidth
            height = pixelHeight
        } else {
            return nil
        }

        let edge = min(width, height)
        guard edge > 0 else { return nil }

        // Round the *offset* to even, not the absolute coordinate: evening the
        // coordinate can land before the rectangle's own origin when that
        // origin is odd, putting the crop outside the valid area. An even
        // offset also keeps the same colour of the filter array at the corner,
        // which is the phase that actually matters.
        //
        // An even offset plus an even edge is always inside: the offset is at
        // most (width − edge) / 2, and rounding only shrinks both.
        let squareEdge = even(edge)
        return Square(x: Int(originX.rounded(.down)) + even((width - edge) / 2),
                      y: Int(originY.rounded(.down)) + even((height - edge) / 2),
                      edge: squareEdge)
    }

    /// Largest even integer no greater than `value`.
    private static func even(_ value: Double) -> Int {
        Int((value / 2).rounded(.down)) * 2
    }

    /// The tags come back as CFNumbers; bridge them without assuming a type.
    private static func numbers(_ value: Any?) -> [Double] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { ($0 as? NSNumber)?.doubleValue }
    }
}
