//
//  CameraPreview.swift
//  Snap
//

import MetalKit
import SwiftUI

/// Hosts the Metal view the renderer draws into.
struct CameraPreview: UIViewRepresentable {

    let renderer: PreviewRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.delegate = renderer
        view.colorPixelFormat = .bgra8Unorm

        // CIContext renders straight into the drawable's texture, which it can
        // only do if the texture is readable.
        view.framebufferOnly = false

        // Nothing moves between frames, so drive drawing from frame arrival
        // instead of a display-linked loop.
        view.isPaused = true
        view.enableSetNeedsDisplay = true

        view.isOpaque = true
        view.backgroundColor = .black
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)

        renderer.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}
