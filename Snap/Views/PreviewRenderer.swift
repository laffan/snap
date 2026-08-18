//
//  PreviewRenderer.swift
//  Snap
//
//  Draws filtered camera frames into an MTKView.
//
//  We render the preview ourselves rather than using AVCaptureVideoPreviewLayer
//  because the preview has to show the same grade as the file that gets saved.
//  A preview layer would show the ungraded sensor feed.
//

import CoreImage
import MetalKit

final class PreviewRenderer: NSObject, MTKViewDelegate {

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let context: CIContext
    private let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Frames arrive on the capture queue and are consumed on the main thread,
    /// so the hand-off needs guarding.
    private let lock = NSLock()
    private var pendingImage: CIImage?

    private weak var view: MTKView?

    override init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            fatalError("Snap requires a Metal-capable device.")
        }
        self.device = device
        self.commandQueue = queue
        self.context = CIContext(mtlCommandQueue: queue, options: [
            .cacheIntermediates: false,
            .name: "SnapPreview",
        ])
        super.init()
    }

    func attach(to view: MTKView) {
        self.view = view
    }

    /// Called once per captured frame, off the main thread.
    func setImage(_ image: CIImage) {
        lock.lock()
        pendingImage = image
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.view?.setNeedsDisplay()
        }
    }

    func clear() {
        lock.lock()
        pendingImage = nil
        lock.unlock()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        lock.lock()
        let image = pendingImage
        lock.unlock()

        guard let image,
              !image.extent.isEmpty,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let target = view.drawableSize
        guard target.width > 0, target.height > 0 else { return }

        // Aspect-fill. Both the frame and the view are square in practice, so
        // this is normally an exact fit — it just keeps the layout honest if
        // either side is ever rounded off by a fraction of a point.
        let scale = max(target.width / image.extent.width,
                        target.height / image.extent.height)
        var output = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        output = output.transformed(by: CGAffineTransform(
            translationX: (target.width - output.extent.width) / 2 - output.extent.origin.x,
            y: (target.height - output.extent.height) / 2 - output.extent.origin.y))

        context.render(output,
                       to: drawable.texture,
                       commandBuffer: commandBuffer,
                       bounds: CGRect(origin: .zero, size: target),
                       colorSpace: outputColorSpace)

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
