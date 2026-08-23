//
//  LaunchRoute.swift
//  Snap
//
//  The one URL the app answers to, and what it means.
//
//  Both lock-screen entries carry it — the accessory widget as its
//  `widgetURL`, the control as the URL its button opens — because an app that
//  is merely launched cannot tell whether it was launched from a pocket or
//  resumed from the switcher, and those two want opposite things. Coming back
//  to the app means coming back to what you were doing; arriving from the lock
//  screen means arriving at the camera. See `CameraView.openFresh`.
//
//  The literal is written out again in `SnapWidgets`, which is a separate
//  target and cannot see this file. It is one string, in two places, changed
//  together.
//

import Foundation

enum LaunchRoute {

    /// Distinctive rather than short: a scheme is a global name, and `snap://`
    /// is a word half the App Store has a claim on.
    static let scheme = "snapsquarecamera"

    /// "Open at the camera, ready to shoot."
    static let capture = "capture"

    /// `host()` rather than the older `host`, which is deprecated from iOS 16
    /// in favour of it.
    static func isCapture(_ url: URL) -> Bool {
        url.scheme == LaunchRoute.scheme && url.host() == LaunchRoute.capture
    }
}
