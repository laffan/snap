//
//  SnapWidgetBundle.swift
//  SnapWidgets
//
//  Two ways onto the lock screen, because iOS grew a second one.
//
//  The accessory widget sits under the clock and works from iOS 16. The
//  control is the iOS 18 addition: it can take the place of the camera or
//  flashlight button in the bottom corners, which is the fastest route from a
//  dark screen to a photograph.
//

import SwiftUI
import WidgetKit

@main
struct SnapWidgetBundle: WidgetBundle {
    var body: some Widget {
        LaunchWidget()

        if #available(iOS 18.0, *) {
            LaunchControl()
        }
    }
}
