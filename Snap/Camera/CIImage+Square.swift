//
//  CIImage+Square.swift
//  Snap
//

import CoreImage

extension CIImage {

    /// Crops to the largest centred square and moves the result back to the
    /// origin, so the returned image has an extent of `(0, 0, edge, edge)`.
    ///
    /// The preview and the still both go through this, which is what makes the
    /// framing on screen match the file that lands in the camera roll.
    func centerSquareCropped() -> CIImage {
        let extent = self.extent
        guard !extent.isInfinite, !extent.isEmpty else { return self }

        let edge = min(extent.width, extent.height)
        let square = CGRect(x: extent.midX - edge / 2,
                            y: extent.midY - edge / 2,
                            width: edge,
                            height: edge)

        return cropped(to: square)
            .transformed(by: CGAffineTransform(translationX: -square.minX, y: -square.minY))
    }
}
