//
//  LaunchControl.swift
//  SnapWidgets
//
//  The iOS 18 control. Once added, it can replace the camera or flashlight
//  button in the lock screen's bottom corners, or sit in Control Centre.
//

import AppIntents
import SwiftUI
import WidgetKit

@available(iOS 18.0, *)
struct LaunchControl: ControlWidget {

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "SnapLaunchControl") {
            ControlWidgetButton(action: OpenSnapIntent()) {
                Label("Snap", systemImage: "camera.aperture")
            }
        }
        .displayName("Snap")
        .description("Opens the camera.")
    }
}

/// Opening the app *is* the whole action, so there is nothing to perform.
/// `openAppWhenRun` is what carries it from the extension to the app.
@available(iOS 18.0, *)
struct OpenSnapIntent: AppIntent {

    static let title: LocalizedStringResource = "Open Snap"
    static let description = IntentDescription("Opens the Snap camera.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}
