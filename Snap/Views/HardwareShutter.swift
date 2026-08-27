//
//  HardwareShutter.swift
//  Snap
//
//  The volume buttons, on the same shutter the finger has.
//
//  `AVCaptureEventInteraction` is a UIKit interaction rather than anything
//  SwiftUI has a word for, so it needs a view to live on. That is all this
//  view is for: it draws nothing, it is never touched, and it exists so the
//  interaction has somewhere to be.
//

import AVKit
import SwiftUI

struct HardwareShutter: UIViewRepresentable {

    /// Whether the buttons are the shutter at this moment. Disarmed, the
    /// interaction doesn't consume the press, so the volume goes back to being
    /// the volume — see `CameraView.isHardwareShutterArmed`.
    var isEnabled: Bool

    /// Run on the main thread, whatever thread the press arrived on.
    var action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeUIView(context: Context) -> UIView {
        let view = PassthroughView(frame: .zero)
        context.coordinator.attach(to: view)
        context.coordinator.setEnabled(isEnabled)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // The closure a SwiftUI view hands out closes over the state it was
        // built with, so the interaction is given a fresh one on every pass
        // rather than holding the one it was made with.
        context.coordinator.action = action
        context.coordinator.setEnabled(isEnabled)
    }

    /// A view that refuses every touch, so a full-screen one lying behind the
    /// app can never stand between a finger and what it was aimed at.
    ///
    /// `isUserInteractionEnabled = false` is the shorter way to say the same
    /// thing, and it is not used: a capture event is delivered to an
    /// interaction rather than hit-tested to a view, but that flag is the one
    /// switch a system that *did* consult something would consult, and there is
    /// no reason to hand it the chance. Declining the touch says only what is
    /// meant.
    private final class PassthroughView: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    }

    final class Coordinator {

        var action: () -> Void

        /// Held as `AnyObject` because what it actually is only exists from iOS
        /// 17.2, and a stored property cannot carry an availability of its own.
        private var interaction: AnyObject?

        init(action: @escaping () -> Void) {
            self.action = action
        }

        func attach(to view: UIView) {
            // iOS 17.0 and 17.1 get nothing, and nothing breaks: the ring under
            // the frame was always the shutter.
            guard #available(iOS 17.2, *) else { return }

            // The one-handler initialiser takes both the primary event and the
            // secondary one, which is what puts *either* volume button on the
            // shutter rather than only the top one.
            let interaction = AVCaptureEventInteraction { [weak self] event in
                // On the press, not the release. See the README.
                guard event.phase == .began else { return }

                // The queue these arrive on isn't promised, and everything a
                // press leads to — the haptic, the shutter flash, the published
                // `isCapturing` — belongs to the main thread.
                DispatchQueue.main.async { self?.action() }
            }

            view.addInteraction(interaction)
            self.interaction = interaction
        }

        func setEnabled(_ isEnabled: Bool) {
            guard #available(iOS 17.2, *) else { return }

            (interaction as? AVCaptureEventInteraction)?.isEnabled = isEnabled
        }
    }
}
