//
//  LaunchControl.swift
//  SnapWidgets
//
//  The iOS 18 control. Once added, it can replace the camera or flashlight
//  button in the lock screen's bottom corners, or sit in Control Centre.
//
//  It used to run a bare `AppIntent` with `openAppWhenRun` and no body, which
//  launched the app and told it nothing. Launching turns out not to be the
//  whole action — see `SnapLaunch`.
//

import AppIntents
import SwiftUI
import WidgetKit

@available(iOS 18.0, *)
struct LaunchControl: ControlWidget {

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "SnapLaunchControl") {
            ControlWidgetButton(action: OpenURLIntent(SnapLaunch.url)) {
                Label("Snap", systemImage: "camera.aperture")
            }
        }
        .displayName("Snap")
        .description("Opens the camera.")
    }
}
