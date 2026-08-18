//
//  RAWCropper.swift
//  Snap
//
//  Works out the square that matches the JPEG, and — where iOS allows it —
//  writes that square into the DNG itself.
//
//  Nothing here touches sensor pixels. A DNG carries DefaultCropOrigin and
//  DefaultCropSize, the rectangle a raw converter shows by default, so
//  squaring the file is a matter of narrowing that rectangle.
//
//  Rewriting a DNG needs ImageIO to be able to author the container, which it
//  may not do. Rather than gate on the advertised writable types, the write is
//  simply attempted and the outcome reported — the gate is what silently kept
//  the full frame before, and a failed attempt costs nothing.
//
//  When it doesn't work, `squareCropFractions` gives the same rectangle in the
//  form Camera Raw wants, and the crop travels in the XMP instead.
//

import Foundation
import ImageIO

enum RAWCropper {

    /// The largest centred square, as fractions of the oriented frame — the
    /// shape `crs:CropTop`/`Left`/`Bottom`/`Right` take.
    struct CropFractions {
        var top: Double
        var left: Double
        var bottom: Double
        var right: Double
    }

    // MARK: - Rewriting the file

    /// Returns a DNG whose default crop is the largest centred square, or nil
    /// if the container can't be rewritten on this device — in which case the
    /// original still stands and the crop goes in the XMP.
    static func squareCropped(_ dngData: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(dngData as CFData, nil),
              let type = CGImageSourceGetType(source),
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
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImageFromSource(destination, source, 0, updated as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0 else { return nil }

        return output as Data
    }

    // MARK: - Geometry

    /// The same square, expressed the way Camera Raw stores a crop: fractions
    /// of the frame *as displayed*, so orientation has to be applied first.
    static func squareCropFractions(_ dngData: Data) -> CropFractions? {
        guard let source = CGImageSourceCreateWithData(dngData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let size = frameSize(in: properties) else {
            return nil
        }

        // Orientations 5–8 are the quarter turns, which swap the axes.
        let orientation = (properties[kCGImagePropertyOrientation as String] as? Int) ?? 1
        let isQuarterTurn = (5...8).contains(orientation)
        let width = isQuarterTurn ? size.height : size.width
        let height = isQuarterTurn ? size.width : size.height

        guard width > 0, height > 0 else { return nil }
        let edge = min(width, height)

        let insetX = (width - edge) / 2 / width
        let insetY = (height - edge) / 2 / height

        return CropFractions(top: insetY, left: insetX, bottom: 1 - insetY, right: 1 - insetX)
    }

    private struct Square {
        var x: Int
        var y: Int
        var edge: Int
    }

    /// The rectangle the file currently calls its default crop.
    private static func frameSize(in properties: [String: Any]) -> (width: Double, height: Double)? {
        let dng = properties[kCGImagePropertyDNGDictionary as String] as? [String: Any]
        let size = numbers(dng?[kCGImagePropertyDNGDefaultCropSize as String])

        if size.count == 2, size[0] > 0, size[1] > 0 {
            return (size[0], size[1])
        }
        if let pixelWidth = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.doubleValue,
           let pixelHeight = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.doubleValue,
           pixelWidth > 0, pixelHeight > 0 {
            return (pixelWidth, pixelHeight)
        }
        return nil
    }

    /// The centred square inside the default-crop rectangle, in raw pixels.
    ///
    /// This is the same rectangle `centerSquareCropped()` takes for the JPEG:
    /// `CIRAWFilter` develops the default-crop area, and a centred square of
    /// that area is what both paths end up with.
    private static func squareCrop(in properties: [String: Any]) -> Square? {
        guard let size = frameSize(in: properties) else { return nil }

        let dng = properties[kCGImagePropertyDNGDictionary as String] as? [String: Any]
        let origin = numbers(dng?[kCGImagePropertyDNGDefaultCropOrigin as String])
        let originX = origin.count == 2 ? origin[0] : 0
        let originY = origin.count == 2 ? origin[1] : 0

        let edge = min(size.width, size.height)
        guard edge > 0 else { return nil }

        // Round the *offset* to even, not the absolute coordinate: evening the
        // coordinate can land before the rectangle's own origin when that
        // origin is odd, putting the crop outside the valid area. An even
        // offset also leaves the same colour of the filter array at the corner,
        // which is the phase that actually matters.
        return Square(x: Int(originX.rounded(.down)) + even((size.width - edge) / 2),
                      y: Int(originY.rounded(.down)) + even((size.height - edge) / 2),
                      edge: even(edge))
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
